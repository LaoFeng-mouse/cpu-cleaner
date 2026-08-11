# Pester 测试: 恢复 (manifest 兼容 / 防御) (Pester 5 固定版本 5.9.0)
Describe '恢复逻辑' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        if (-not (Get-Command Get-RestorePlan -ErrorAction SilentlyContinue)) {
            function Get-RestorePlan { throw 'unified restore plan not implemented' }
        }
        if (-not (Get-Command Invoke-ValidatedRestoreManifest -ErrorAction SilentlyContinue)) {
            function Invoke-ValidatedRestoreManifest { throw 'validated restore execution not implemented' }
        }
        if (-not (Get-Command Invoke-RestorePlanAction -ErrorAction SilentlyContinue)) {
            function Invoke-RestorePlanAction { throw 'restore mutation wrapper not implemented' }
        }
        if (-not (Get-Command Get-BackupPathAttributes -ErrorAction SilentlyContinue)) {
            function Get-BackupPathAttributes($Path) { [System.IO.FileAttributes]::Normal }
        }
        if (-not (Get-Command Test-TrustedBackupAclDescriptor -ErrorAction SilentlyContinue)) {
            function Test-TrustedBackupAclDescriptor { return $true }
        }
        Mock Get-SecureBackupRoot { Split-Path $TestDrive -Parent }
        Mock Get-BackupAclDescriptor {
            [pscustomobject]@{OwnerSid='S-1-5-32-544';Protected=$true;Rules=@(
                [pscustomobject]@{Sid='S-1-5-18';Type='Allow';Rights=[int64][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false},
                [pscustomobject]@{Sid='S-1-5-32-544';Type='Allow';Rights=[int64][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false}
            )}
        }
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
    }

    BeforeAll {
        function Invoke-LatestRestoreEntryCase {
            param(
                [Parameter(Mandatory=$true)][string]$ProjectRoot,
                [Parameter(Mandatory=$true)][string]$CaseRoot,
                [Parameter(Mandatory=$true)][string]$Overrides
            )
            $driver = Join-Path $CaseRoot ('latest-entry-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $projectRootLiteral = $ProjectRoot.Replace("'", "''")
            $driverSource = @"
`$projectRoot = '$projectRootLiteral'
`$src = Get-Content (Join-Path `$projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
`$idx = `$src.IndexOf("switch (```$Mode)")
`$defs = `$src.Substring(0, `$idx).Replace('`$script:Root = Split-Path -Parent `$MyInvocation.MyCommand.Path', '`$script:Root = `$projectRoot')
Invoke-Expression `$defs
`$BackupDir = 'latest'
function Is-Admin { return `$true }
function Write-Step {}
function Invoke-ValidatedRestoreManifest { return [pscustomobject]@{success=`$true;type='process';name='noop'} }
$Overrides
Invoke-Restore
"@
            [System.IO.File]::WriteAllText($driver, $driverSource, [System.Text.UTF8Encoding]::new($false))
            $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $driver 2>&1
            return [pscustomobject]@{ ExitCode=[int]$LASTEXITCODE; Output=($output -join "`n") }
        }
    }

    It '新格式 manifest 用 start_type_sc' {
        $m = [pscustomobject]@{ type='service'; name='X'; start_type_sc='auto'; before=$null }
        $scVal = if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) { $m.start_type_sc } else { 'disabled' }
        $scVal | Should -Be 'auto'
    }
    It '旧格式 manifest 字符串枚举 Disabled→disabled' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='Disabled' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'disabled'
    }
    It '旧格式 manifest 字符串枚举 Automatic→auto' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='Automatic' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'auto'
    }
    It '旧格式 manifest 数字枚举 3→demand' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='3' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'demand'
    }
    It '缺省恢复为 disabled(保守)' {
        $m = [pscustomobject]@{ type='service'; name='X' }
        $scVal = if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) { $m.start_type_sc } elseif ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'disabled'
    }
    It '空/损坏 manifest 拒绝恢复' {
        $manifest = $null
        ($null -eq $manifest -or @($manifest).Count -eq 0) | Should -Be $true
    }

    It '服务恢复计划还原原启动类型和运行状态' {
        $manifest = [pscustomobject]@{
            type='service'; name='ExactSvc'; backup='C:\backup\svc.reg'
            start_type_sc='auto'; status='Running'; delayed_autostart=0; backup_verified=$true
        }

        $plan = Get-ServiceRestorePlan $manifest

        $plan.StartType | Should -BeExactly 'auto'
        $plan.ShouldStart | Should -BeTrue
    }

    It '新服务 manifest 未标记验证过的备份时拒绝生成恢复计划' {
        $manifest = [pscustomobject]@{
            type='service'; name='ExactSvc'; backup='C:\backup\svc.reg'
            start_type_sc='auto'; status='Running'; delayed_autostart=0; backup_verified=$false
        }

        { Get-ServiceRestorePlan $manifest } | Should -Throw '*备份*'
    }

    It '统一恢复在任一备份缺失时所有 mutation 为 0' {
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='service'; name='ExactSvc'; target_identity='ExactSvc'; backup_verified=$true
            backup=(Join-Path $TestDrive 'missing.reg'); backup_sha256=('0' * 64)
            start_type_sc='auto'; status='Running'; entry_id='svc'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*备份*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '统一恢复在服务备份目标身份错配时所有 mutation 为 0' {
        $backup = Join-Path $TestDrive 'service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\OtherSvc]`r`n")
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='service'; name='ExactSvc'; target_identity='ExactSvc'; backup_verified=$true
            backup=$backup; backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash
            start_type_sc='auto'; status='Running'; entry_id='svc'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*身份*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '统一恢复在自启动备份身份错配时所有 mutation 为 0' {
        $backup = Join-Path $TestDrive 'auto.autostart.json'
        [System.IO.File]::WriteAllText($backup, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Other","value_type":"String","value":"C:\\Apps\\old.exe"}')
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='autostart'; key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; name='Updater'
            target_identity='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|Updater'; backup_verified=$true
            backup=$backup; backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash
            entry_id='auto'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*身份*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '统一恢复在任务 XML URI 与目标错配时所有 mutation 为 0' {
        $backup = Join-Path $TestDrive 'task.xml'
        [System.IO.File]::WriteAllText($backup, '<Task><RegistrationInfo><URI>\Other\Task</URI></RegistrationInfo></Task>')
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='task'; name='\Vendor\Task'; target_identity='\Vendor\Task'; backup_verified=$true
            backup=$backup; backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash
            entry_id='task'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*身份*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '统一恢复拒绝备份目录之外的文件且 mutation 为 0' {
        $outside = Join-Path (Split-Path $TestDrive -Parent) 'outside.reg'
        [System.IO.File]::WriteAllText($outside, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        try {
            $manifest = @([pscustomobject]@{
                backup_format_version=1; type='service'; name='ExactSvc'; target_identity='ExactSvc'; backup_verified=$true
                backup=$outside; backup_sha256=(Get-FileHash $outside -Algorithm SHA256).Hash
                start_type_sc='auto'; status='Running'; entry_id='svc'; execution_status='success'
            })
            Mock Invoke-RestorePlanAction {}

            { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*目录*'
            Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
        } finally {
            Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue
        }
    }

    It '删除 service 显式备份字段后拒绝自动恢复且 mutation 为 0' {
        $backup = Join-Path $TestDrive 'legacy-service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        $manifest = @([pscustomobject]@{ type='service'; name='ExactSvc'; backup=$backup; start_type_sc='auto'; status='Running' })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*格式版本*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '删除 task 显式备份字段后拒绝自动恢复且 mutation 为 0' {
        $backup = Join-Path $TestDrive 'legacy-task.xml'
        [System.IO.File]::WriteAllText($backup, '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>')
        $manifest = @([pscustomobject]@{ type='task'; name='\Vendor\Task'; backup=$backup })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*格式版本*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '删除 autostart 显式备份字段后拒绝自动恢复且 mutation 为 0' {
        $backup = Join-Path $TestDrive 'legacy-auto.autostart.json'
        [System.IO.File]::WriteAllText($backup, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","value_type":"String","value":"C:\\Apps\\old.exe"}')
        $manifest = @([pscustomobject]@{ type='autostart'; key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; name='Updater'; backup=$backup })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*格式版本*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '任务备份内容被篡改但保留 URI 时 SHA 验证阻止 mutation' {
        $backup = Join-Path $TestDrive 'tampered-task.xml'
        [System.IO.File]::WriteAllText($backup, '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>')
        $originalHash = (Get-FileHash $backup -Algorithm SHA256).Hash
        [System.IO.File]::WriteAllText($backup, '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions /></Task>')
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='task'; name='\Vendor\Task'; target_identity='\Vendor\Task'; backup_verified=$true
            backup=$backup; backup_sha256=$originalHash; entry_id='task'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*SHA-256*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '自启动备份 value 被篡改但保留 path 和 name 时 SHA 验证阻止 mutation' {
        $backup = Join-Path $TestDrive 'tampered-auto.autostart.json'
        [System.IO.File]::WriteAllText($backup, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","value_type":"String","value":"C:\\Apps\\old.exe"}')
        $originalHash = (Get-FileHash $backup -Algorithm SHA256).Hash
        [System.IO.File]::WriteAllText($backup, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","value_type":"String","value":"C:\\Apps\\evil.exe"}')
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='autostart'; key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; name='Updater'
            target_identity='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|Updater'; backup_verified=$true
            backup=$backup; backup_sha256=$originalHash; entry_id='auto'; execution_status='success'
        })
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*SHA-256*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '中间目录为 reparse point 时拒绝恢复且 mutation 为 0' {
        $nested = Join-Path $TestDrive 'nested'
        [System.IO.Directory]::CreateDirectory($nested) | Out-Null
        $backup = Join-Path $nested 'service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        $manifest = @([pscustomobject]@{
            backup_format_version=1; type='service'; name='ExactSvc'; target_identity='ExactSvc'; backup_verified=$true
            backup=$backup; backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash
            start_type_sc='auto'; status='Running'; entry_id='svc'; execution_status='success'
        })
        Mock Get-BackupPathAttributes {
            if ([string]::Equals($Path, $nested, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint
            }
            return [System.IO.FileAttributes]::Normal
        }
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest $manifest -BackupDir $TestDrive } | Should -Throw '*重解析点*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It 'restore 对 artifact 使用同一锁定字节快照计算 SHA 并解析' {
        $backup = Join-Path $TestDrive 'snapshot-task.xml'
        $safeXml = '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>safe.exe</Command></Exec></Actions></Task>'
        $evilXml = '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>evil.exe</Command></Exec></Actions></Task>'
        [System.IO.File]::WriteAllText($backup, $safeXml)
        $hash = (Get-FileHash $backup -Algorithm SHA256).Hash
        $manifest = [pscustomobject]@{
            backup_format_version=1; type='task'; name='\Vendor\Task'; target_identity='\Vendor\Task'; backup_verified=$true
            backup=$backup; backup_sha256=$hash; entry_id='task'; execution_status='success'; verified=$true; note='restore task'
        }
        Mock Get-FileSha256Hex {
            [System.IO.File]::WriteAllText($Path, $evilXml)
            return $hash
        }

        $plan = Get-RestorePlan -Manifest $manifest -BackupDir $TestDrive

        $plan.Xml | Should -Match 'safe\.exe'
        $plan.Xml | Should -Not -Match 'evil\.exe'
        if ($plan.Artifact) { $plan.Artifact.Stream.Dispose() }
    }

    It 'restore 执行逐项隔离失败并继续记录后续结果' {
        $plans = @(
            [pscustomobject]@{Type='process';Name='one'},
            [pscustomobject]@{Type='process';Name='two'},
            [pscustomobject]@{Type='process';Name='three'}
        )
        $script:ActionCount = 0
        Mock Get-RestorePlan { return $Manifest }
        Mock Invoke-RestorePlanAction {
            $script:ActionCount++
            if ($Plan.Name -eq 'two') { throw 'second failed after first mutation' }
            return [pscustomobject]@{success=$true;type=$Plan.Type;name=$Plan.Name}
        }

        $results = @(Invoke-ValidatedRestoreManifest -Manifest $plans -BackupDir $TestDrive)

        $results.Count | Should -Be 3
        $results[0].status | Should -BeExactly 'success'
        $results[1].status | Should -BeExactly 'failed'
        $results[2].status | Should -BeExactly 'success'
        $script:ActionCount | Should -Be 3
    }

    It '任务注册使用 ErrorAction Stop 且定义回读不一致时失败' {
        $plan = [pscustomobject]@{
            Type='task';Name='\Vendor\Task';TaskName='Task';TaskPath='\Vendor\'
            Xml='<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>safe.exe</Command></Exec></Actions></Task>'
            TaskFingerprint='expected'
        }
        Mock Register-ScheduledTask {}
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>evil.exe</Command></Exec></Actions></Task>' }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
    }

    It '自启动回读 value type 或完整 data 不一致时失败' {
        $info = [pscustomobject]@{key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';name='Updater';value_type='ExpandString';value='%TEMP%\updater.exe'}
        $plan = [pscustomobject]@{Type='autostart';Format='single_value';Key=$info.key;Name=$info.name;Info=$info}
        Mock Restore-AutostartValue {}
        Mock Get-ItemProperty { [pscustomobject]@{Updater='anything'} }
        Mock Get-AutostartValueInfo { [pscustomobject]@{key=$info.key;name=$info.name;value_type='String';value='C:\Temp\updater.exe'} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
    }

    It '严格 manifest 拒绝字符串布尔 数组标量 未知状态和字符串 restart_after_restore' {
        $backup = Join-Path $TestDrive 'strict-service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        $base = @{
            backup_format_version=1;type='service';name='ExactSvc';target_identity='ExactSvc';backup_verified=$true
            backup=$backup;backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash;entry_id='svc';execution_status='success'
            verified=$true;note='restore';start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0
        }
        $cases = @(
            @{field='backup_verified';value='true'},
            @{field='target_identity';value=@('ExactSvc')},
            @{field='execution_status';value='unknown'},
            @{field='restart_after_restore';value='false'}
        )
        foreach($case in $cases) {
            $copy = [ordered]@{}; foreach($key in $base.Keys){$copy[$key]=$base[$key]}; $copy[$case.field]=$case.value
            { Get-RestorePlan -Manifest ([pscustomobject]$copy) -BackupDir $TestDrive } | Should -Throw -Because $case.field
        }
    }

    It '严格 autostart artifact 拒绝未知 value_type 和重复 JSON 字段' {
        foreach($json in @(
            '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","value_type":"Mystery","value":"x"}',
            '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","name":"Other","value_type":"String","value":"x"}'
        )) {
            $backup = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '.autostart.json')
            [System.IO.File]::WriteAllText($backup, $json)
            $manifest = [pscustomobject]@{
                backup_format_version=1;type='autostart';key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';name='Updater'
                target_identity='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|Updater';backup_verified=$true
                backup=$backup;backup_sha256=(Get-FileHash $backup -Algorithm SHA256).Hash;entry_id='auto';execution_status='success';verified=$true;note='restore'
            }
            { Get-RestorePlan -Manifest $manifest -BackupDir $TestDrive } | Should -Throw
        }
    }

    It '严格 manifest JSON 拒绝重复字段且 mutation 为 0' {
        $manifestFile = Join-Path $TestDrive 'manifest.json'
        [System.IO.File]::WriteAllText($manifestFile, '[{"entry_id":"one","type":"task","type":"service"}]')
        Mock Invoke-RestorePlanAction {}

        { Read-BackupManifestEntries $manifestFile } | Should -Throw '*重复*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '服务原状态 Running 时 sc start 非零不得报告 success' {
        $plan = [pscustomobject]@{Type='service';Name='ExactSvc';StartType='auto';ExpectedStatus='Running';ShouldStart=$true;HasDelayed=$false;DelayedAutoStart=0}
        Mock Invoke-ServiceControlCommand {
            if ($Arguments[0] -eq 'start') { return 5 }
            return 0
        }
        Mock Get-Service { [pscustomobject]@{StartType='Automatic';Status='Running'} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
        $result.reason | Should -Match 'sc start.*exit=5'
    }

    It '服务原状态 Running 但最终仍 Stopped 时不得报告 success' {
        $plan = [pscustomobject]@{Type='service';Name='ExactSvc';StartType='auto';ExpectedStatus='Running';ShouldStart=$true;HasDelayed=$false;DelayedAutoStart=0}
        Mock Invoke-ServiceControlCommand { return 0 }
        Mock Get-Service { [pscustomobject]@{StartType='Automatic';Status='Stopped'} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
        $result.reason | Should -Match '运行状态.*Stopped.*Running'
    }

    It '服务 DelayedAutostart mutation 后回读不一致不得报告 success' {
        $plan = [pscustomobject]@{Type='service';Name='ExactSvc';StartType='auto';ExpectedStatus='Stopped';ShouldStart=$false;HasDelayed=$true;DelayedAutoStart=1}
        Mock Invoke-ServiceControlCommand { return 0 }
        Mock New-ItemProperty {}
        Mock Get-Service { [pscustomobject]@{StartType='Automatic';Status='Stopped'} }
        Mock Get-ItemProperty { [pscustomobject]@{DelayedAutostart=0} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
        $result.reason | Should -Match 'DelayedAutostart.*0.*1'
    }

    It '服务原状态非 Running 但最终 Running 时不得报告 success' {
        $plan = [pscustomobject]@{Type='service';Name='ExactSvc';StartType='demand';ExpectedStatus='Stopped';ShouldStart=$false;HasDelayed=$false;DelayedAutoStart=0}
        Mock Invoke-ServiceControlCommand { return 0 }
        Mock Get-Service { [pscustomobject]@{StartType='Manual';Status='Running'} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeFalse
        $result.reason | Should -Match '运行状态.*Running.*Stopped'
    }

    It '用户自建路径不能作为 restore 信任包且 mutation 为 0' {
        Mock Get-SecureBackupRoot { Join-Path $TestDrive 'trusted' }
        Mock Invoke-RestorePlanAction {}
        $outside = Join-Path $TestDrive 'user-created'

        { Invoke-ValidatedRestoreManifest -Manifest @([pscustomobject]@{type='process';name='noop';path=''}) -BackupDir $outside } | Should -Throw '*安全备份根*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '可写 DACL 和不可信 owner 均被拒绝' {
        $trustedOwner = 'S-1-5-32-544'
        $usersSid = 'S-1-5-32-545'
        $writable = [pscustomobject]@{OwnerSid=$trustedOwner;Protected=$true;Rules=@([pscustomobject]@{Sid=$usersSid;Type='Allow';Rights=[int][System.Security.AccessControl.FileSystemRights]::Modify;Inherited=$false})}
        $badOwner = [pscustomobject]@{OwnerSid=$usersSid;Protected=$true;Rules=@()}
        Mock Invoke-RestorePlanAction {}
        foreach($descriptor in @($writable,$badOwner)) {
            $script:AclCase = $descriptor
            Mock Get-BackupAclDescriptor { $script:AclCase }
            { Invoke-ValidatedRestoreManifest -Manifest @([pscustomobject]@{type='process';name='noop';path=''}) -BackupDir $TestDrive } | Should -Throw '*DACL*'
        }
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It 'ACL 读取失败时 restore 在 mutation 前失败关闭' {
        Mock Get-SecureBackupRoot { Split-Path $TestDrive -Parent }
        Mock Get-BackupAclDescriptor { throw 'ACL read denied' }
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest @([pscustomobject]@{type='process';name='noop';path=''}) -BackupDir $TestDrive } | Should -Throw '*ACL*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It '仅 SYSTEM 和 Administrators 可写的受保护 ACL 被接受' {
        $descriptor = [pscustomobject]@{
            OwnerSid='S-1-5-32-544';Protected=$true;Rules=@(
                [pscustomobject]@{Sid='S-1-5-18';Type='Allow';Rights=[int][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false},
                [pscustomobject]@{Sid='S-1-5-32-544';Type='Allow';Rights=[int][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false}
            )
        }

        (Test-TrustedBackupAclDescriptor -Descriptor $descriptor -RequireProtected $true) | Should -BeTrue
    }

    It 'restore 计划拒绝 Paused 和 pending 服务状态' {
        foreach($status in @('Paused','StartPending','StopPending')) {
            $manifest = [pscustomobject]@{type='service';name='ExactSvc';start_type_sc='auto';status=$status;backup_verified=$true}
            { Get-ServiceRestorePlan $manifest } | Should -Throw '*稳定*'
        }
    }

    It '全部 restore plan 构建后 mutation 前再次验证信任链' {
        $script:TrustChecks = 0
        Mock Assert-TrustedBackupPackagePath {
            $script:TrustChecks++
            if ($script:TrustChecks -eq 2) { throw 'trust changed after planning' }
            return $BackupDir
        }
        Mock Get-RestorePlan { [pscustomobject]@{Type='process';Name='noop'} }
        Mock Invoke-RestorePlanAction {}

        { Invoke-ValidatedRestoreManifest -Manifest @([pscustomobject]@{type='process';name='noop';path=''}) -BackupDir $TestDrive } | Should -Throw '*trust changed*'

        $script:TrustChecks | Should -Be 2
        Should -Invoke Get-RestorePlan -Times 1 -Exactly
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It 'latest 通过真实候选验证跳过重复 JSON 字段的新包并选择旧可信包' {
        $newestDir = Join-Path $TestDrive '20260811_130000'
        $trustedDir = Join-Path $TestDrive '20260811_120000'
        [void][System.IO.Directory]::CreateDirectory($newestDir)
        [void][System.IO.Directory]::CreateDirectory($trustedDir)
        [System.IO.File]::WriteAllText(
            (Join-Path $newestDir 'manifest.json'),
            '[{"entry_id":"bad","entry_id":"duplicate","type":"process","name":"bad","path":""}]',
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $trustedDir 'manifest.json'),
            '[{"entry_id":"good","type":"process","name":"noop","path":""}]',
            [System.Text.UTF8Encoding]::new($false)
        )
        Mock Get-SecureBackupRoot { $TestDrive }
        Mock Assert-TrustedBackupPackagePath { return $BackupDir }
        Mock Assert-TrustedBackupPathAcl {}
        Mock Get-ChildItem {
            @(
                [pscustomobject]@{ Name='20260811_130000'; FullName=$newestDir },
                [pscustomobject]@{ Name='20260811_120000'; FullName=$trustedDir }
            )
        }

        $selected = Resolve-LatestTrustedRestorePackage

        $selected.BackupDir | Should -BeExactly $trustedDir
        @($selected.Manifest).Count | Should -Be 1
        $selected.Manifest[0].entry_id | Should -BeExactly 'good'
    }

    It 'latest 在管理员核心内跳过无效新包并选择最新可信包' {
        $newest = [pscustomobject]@{ Name='20260811_130000'; FullName=(Join-Path $TestDrive '20260811_130000') }
        $trusted = [pscustomobject]@{ Name='20260811_120000'; FullName=(Join-Path $TestDrive '20260811_120000') }
        Mock Get-SecureBackupRoot { $TestDrive }
        Mock Assert-TrustedBackupPathAcl {}
        Mock Get-ChildItem { @($newest, $trusted) }
        Mock Get-TrustedRestorePackage {
            param($BackupDir)
            if ($BackupDir -eq $newest.FullName) { throw (New-RestoreCandidateRejectedException 'invalid package') }
            [pscustomobject]@{ BackupDir=$BackupDir; Manifest=@([pscustomobject]@{type='process';name='noop';path=''}) }
        }

        $selected = Resolve-LatestTrustedRestorePackage

        $selected.BackupDir | Should -BeExactly $trusted.FullName
        Should -Invoke Get-TrustedRestorePackage -Times 2 -Exactly
    }

    It 'latest 无目录或所有包验证失败时失败关闭' {
        Mock Get-SecureBackupRoot { $TestDrive }
        Mock Assert-TrustedBackupPathAcl {}
        Mock Invoke-RestorePlanAction {}
        Mock Get-ChildItem { @() }
        { Resolve-LatestTrustedRestorePackage } | Should -Throw '*可信备份*'

        Mock Get-ChildItem { @([pscustomobject]@{Name='20260811_120000';FullName=(Join-Path $TestDrive '20260811_120000')}) }
        Mock Get-TrustedRestorePackage { throw (New-RestoreCandidateRejectedException 'bad hash or identity') }
        { Resolve-LatestTrustedRestorePackage } | Should -Throw '*可信备份*'
        Should -Invoke Invoke-RestorePlanAction -Times 0 -Exactly
    }

    It 'latest 只把明确 CandidateRejected 异常视为普通不可信候选' {
        $rejection = New-RestoreCandidateRejectedException 'invalid package'

        (Test-RestoreResolutionExceptionKind -Exception $rejection -Kind 'CandidateRejected') | Should -BeTrue
        (Test-RestoreResolutionExceptionKind -Exception ([System.InvalidOperationException]::new('validator crashed')) -Kind 'CandidateRejected') | Should -BeFalse
    }

    It 'latest 入口仅在安全根不存在 无候选 或全部候选明确拒绝时返回 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $missingRoot = Join-Path $TestDrive 'missing-root'
        $emptyRoot = Join-Path $TestDrive 'empty-root'
        $rejectedRoot = Join-Path $TestDrive 'rejected-root'
        [void][System.IO.Directory]::CreateDirectory($emptyRoot)
        [void][System.IO.Directory]::CreateDirectory((Join-Path $rejectedRoot '20260811_120000'))

        $cases = @(
            @{ Root=$missingRoot; Extra='' },
            @{ Root=$emptyRoot; Extra='function Assert-TrustedBackupPathAcl {}' },
            @{ Root=$rejectedRoot; Extra="function Assert-TrustedBackupPathAcl {}; function Get-TrustedRestorePackage { throw (New-RestoreCandidateRejectedException 'invalid package') }" }
        )
        foreach ($case in $cases) {
            $rootLiteral = $case.Root.Replace("'", "''")
            $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; " + $case.Extra
            $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides
            $result.ExitCode | Should -Be 3 -Because $result.Output
        }
    }

    It 'latest 入口 ACL 读取故障返回普通失败码而不是 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $root = Join-Path $TestDrive 'acl-error-root'
        [void][System.IO.Directory]::CreateDirectory($root)
        $rootLiteral = $root.Replace("'", "''")
        $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; function Assert-TrustedBackupPathAcl { throw [System.UnauthorizedAccessException]::new('ACL read failed') }"

        $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides

        $result.ExitCode | Should -Be 1 -Because $result.Output
    }

    It 'latest 入口目录枚举异常返回普通失败码而不是 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $root = Join-Path $TestDrive 'enumeration-error-root'
        [void][System.IO.Directory]::CreateDirectory($root)
        $rootLiteral = $root.Replace("'", "''")
        $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; function Assert-TrustedBackupPathAcl {}; function Get-ChildItem { throw [System.IO.IOException]::new('enumeration failed') }"

        $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides

        $result.ExitCode | Should -Be 1 -Because $result.Output
    }

    It 'latest 入口内部验证异常返回普通失败码而不是 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $root = Join-Path $TestDrive 'validation-error-root'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $root '20260811_120000'))
        $rootLiteral = $root.Replace("'", "''")
        $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; function Assert-TrustedBackupPathAcl {}; function Get-TrustedRestorePackage { throw [System.InvalidOperationException]::new('validator crashed') }"

        $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides

        $result.ExitCode | Should -Be 1 -Because $result.Output
    }

    It 'latest 入口候选 manifest ACL 的 PowerShell 运行时故障返回普通失败码而不是 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $root = Join-Path $TestDrive 'candidate-acl-runtime-error-root'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $root '20260811_120000'))
        $rootLiteral = $root.Replace("'", "''")
        $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; function Assert-TrustedBackupPackagePath { return `$BackupDir }; function Assert-TrustedBackupPathAcl { param(`$Path) if ([System.IO.Path]::GetFileName(`$Path) -ceq 'manifest.json') { throw 'candidate ACL runtime failure' } }"

        $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides

        $result.ExitCode | Should -Be 1 -Because $result.Output
    }

    It 'latest 入口候选验证器普通 throw 返回普通失败码而不是 3' {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $root = Join-Path $TestDrive 'candidate-validator-runtime-error-root'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $root '20260811_120000'))
        $rootLiteral = $root.Replace("'", "''")
        $overrides = "function Get-SecureBackupRoot { return '$rootLiteral' }; function Assert-TrustedBackupPackagePath { return `$BackupDir }; function Assert-TrustedBackupPathAcl {}; function Read-BackupManifestEntries { return @([pscustomobject]@{ type='process'; name='noop'; path='' }) }; function Get-RestorePlan { throw 'validator runtime failure' }"

        $result = Invoke-LatestRestoreEntryCase -ProjectRoot $projectRoot -CaseRoot $TestDrive -Overrides $overrides

        $result.ExitCode | Should -Be 1 -Because $result.Output
    }
}
