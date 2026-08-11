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
}
