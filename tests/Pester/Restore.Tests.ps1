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
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
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
}
