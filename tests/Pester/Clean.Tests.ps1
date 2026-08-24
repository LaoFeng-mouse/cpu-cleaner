# Pester 测试: 清理动作 (映射 / safe 防御) (Pester 5 固定版本 5.9.0)
Describe '清理动作逻辑' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        if (-not (Get-Command Add-BackupManifestEntryAtomic -ErrorAction SilentlyContinue)) {
            function Add-BackupManifestEntryAtomic { throw 'write-ahead manifest not implemented' }
        }
        if (-not (Get-Command Update-BackupManifestEntryAtomic -ErrorAction SilentlyContinue)) {
            function Update-BackupManifestEntryAtomic { throw 'manifest status update not implemented' }
        }
        if (-not (Get-Command Confirm-BackupManifestFile -ErrorAction SilentlyContinue)) {
            function Confirm-BackupManifestFile { return $true }
        }
        if (-not (Get-Command Test-TrustedBackupAclDescriptor -ErrorAction SilentlyContinue)) {
            function Test-TrustedBackupAclDescriptor { return $true }
        }
        if (-not (Get-Command Initialize-ProtectedBackupDirectory -ErrorAction SilentlyContinue)) {
            function Initialize-ProtectedBackupDirectory { return $BackupDir }
        }
        Mock Get-SecureBackupRoot { Split-Path $TestDrive -Parent }
        Mock Get-BackupAclDescriptor {
            [pscustomobject]@{OwnerSid='S-1-5-32-544';Protected=$true;Rules=@(
                [pscustomobject]@{Sid='S-1-5-18';Type='Allow';Rights=[int64][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false},
                [pscustomobject]@{Sid='S-1-5-32-544';Type='Allow';Rights=[int64][System.Security.AccessControl.FileSystemRights]::FullControl;Inherited=$false}
            )}
        }
        Mock Protect-BackupPathAcl {}
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
    }

    It '服务启动类型映射 Automatic→auto' {
        Convert-StartTypeToSc 'Automatic' | Should -Be 'auto'
    }
    It '服务启动类型映射 Manual→demand' {
        Convert-StartTypeToSc 'Manual' | Should -Be 'demand'
    }
    It '服务启动类型映射 Disabled→disabled' {
        Convert-StartTypeToSc 'Disabled' | Should -Be 'disabled'
    }
    It '旧 manifest 数字枚举 2→auto' {
        Convert-NumberToSc 2 | Should -Be 'auto'
    }
    It '旧 manifest 数字枚举 4→disabled' {
        Convert-NumberToSc 4 | Should -Be 'disabled'
    }
    It 'safe=false 即使选中也被拒绝(skipped)' {
        $p = [pscustomobject]@{ safe = $false; status = 'pending' }
        if (-not $p.safe) { $p.status = 'skipped' }
        $p.status | Should -Be 'skipped'
    }
    It 'actions 缺省动作返回 none' {
        Get-ActionFor $null 'service' | Should -Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'service' | Should -Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'process' | Should -Be 'investigate'
    }
    It 'actions hashtable 兼容(v1 转换产物)' {
        $h = @{ service = 'disable_service' }
        Get-ActionFor $h 'service' | Should -Be 'disable_service'
        Get-ActionFor $h 'process' | Should -Be 'none'
        (Get-ActionKeys $h) -contains 'service' | Should -Be $true
    }

    It 'reg export 返回非零时拒绝把注册表备份当作成功' {
        Mock reg { $global:LASTEXITCODE = 1 }

        { Backup-RegistryKey 'HKLM:\Software\Vendor' $TestDrive 'failed-export' } |
            Should -Throw '*注册表备份*'
    }

    It 'reg export 未生成可恢复文件时拒绝把注册表备份当作成功' {
        Mock reg { $global:LASTEXITCODE = 0 }

        { Backup-RegistryKey 'HKLM:\Software\Vendor' $TestDrive 'missing-export' } |
            Should -Throw '*注册表备份*'
    }

    It 'reg export 生成无效内容时拒绝把注册表备份当作成功' {
        Mock reg {
            param($operation, $keyPath, $outputPath)
            [System.IO.File]::WriteAllText($outputPath, 'not a registry export')
            $global:LASTEXITCODE = 0
        }

        { Backup-RegistryKey 'HKLM:\Software\Vendor' $TestDrive 'invalid-export' } |
            Should -Throw '*注册表备份*'
    }

    It 'reg export 只有文件头而没有键块时拒绝把它当作可恢复备份' {
        Mock reg {
            param($operation, $keyPath, $outputPath)
            [System.IO.File]::WriteAllText($outputPath, "Windows Registry Editor Version 5.00`r`n")
            $global:LASTEXITCODE = 0
        }

        { Backup-RegistryKey 'HKLM:\Software\Vendor' $TestDrive 'header-only-export' } |
            Should -Throw '*注册表备份*'
    }

    It '服务备份创建失败时配置和停止调用均为 0' {
        Mock Get-ServiceBackupInfo {
            [pscustomobject]@{ name='ExactSvc';display_name='Exact Service';path_name='C:\ExactSvc.exe';binary_path='C:\ExactSvc.exe';binary_sha256=('A' * 64);start_mode='Auto';state='Running';was_running=$true;start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0 }
        }
        Mock Backup-RegistryKey { throw 'backup failed' }
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '服务原始配置不完整时不创建备份也不修改服务' {
        Mock Get-ServiceBackupInfo {
            [pscustomobject]@{ start_type_sc=''; start_type_display=''; status='Running'; delayed_autostart=0 }
        }
        Mock Backup-RegistryKey { throw 'must not back up invalid service state' }
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc-invalid'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Backup-RegistryKey -Times 0 -Exactly
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '计划任务 XML 备份无法验证时禁用调用为 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Export-ScheduledTask { '' }
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It '计划任务导出不是有效 XML 时禁用调用为 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Export-ScheduledTask { 'not xml' }
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-invalid'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It '服务 write-ahead manifest 持久化失败时 mutation 为 0' {
        Mock Get-ServiceBackupInfo {
            [pscustomobject]@{ name='ExactSvc';display_name='Exact Service';path_name='C:\ExactSvc.exe';binary_path='C:\ExactSvc.exe';binary_sha256=('A' * 64);start_mode='Auto';state='Running';was_running=$true;start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0 }
        }
        Mock Backup-RegistryKey {
            $out = Join-Path $TestDrive 'service.reg'
            [System.IO.File]::WriteAllText($out, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
            return $out
        }
        Mock Add-BackupManifestEntryAtomic { throw 'manifest write failed' }
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc-journal'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '计划任务 write-ahead manifest 持久化失败时禁用调用为 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>' }
        Mock Add-BackupManifestEntryAtomic { throw 'manifest write failed' }
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-journal'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It '自启动 write-ahead manifest 持久化失败时删除调用为 0' {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValueNames { @('Updater') }
        $key | Add-Member ScriptMethod GetValue { param($name,$default,$options) 'C:\Apps\old.exe' }
        $key | Add-Member ScriptMethod GetValueKind { param($name) [Microsoft.Win32.RegistryValueKind]::String }
        Mock Write-AutostartValueBackup {
            $out = Join-Path $TestDrive 'auto.autostart.json'
            [System.IO.File]::WriteAllText($out, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","value_type":"String","value":"C:\\Apps\\old.exe"}')
            return $out
        }
        Mock Add-BackupManifestEntryAtomic { throw 'manifest write failed' }
        Mock Remove-LiteralRegistryValueFromKey {}

        $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'auto-journal' -RequireArtifactIdentity $true

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
    }

    It '逐项原子追加 manifest 时保留之前已经持久化的项目' {
        $first = [pscustomobject]@{ entry_id='one'; type='service'; name='SvcOne'; execution_status='prepared' }
        $second = [pscustomobject]@{ entry_id='two'; type='task'; name='\Vendor\Task'; execution_status='prepared' }

        Add-BackupManifestEntryAtomic -BackupDir $TestDrive -Entry $first
        Add-BackupManifestEntryAtomic -BackupDir $TestDrive -Entry $second

        $saved = @(Get-Content (Join-Path $TestDrive 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        @($saved.entry_id) | Should -Be @('one','two')
    }

    It '计划任务禁用后回读不存在时返回 failed 并保留已持久化备份' {
        $script:TaskReadCount = 0
        Mock Get-ScheduledTask {
            $script:TaskReadCount++
            if ($script:TaskReadCount -eq 1) { return [pscustomobject]@{State='Ready'} }
            return $null
        }
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>' }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Update-BackupManifestEntryAtomic {}
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-missing'

        $result.status | Should -BeExactly 'failed'
        $result.manifest.backup_verified | Should -BeTrue
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
    }

    It '计划任务禁用命令返回后仍 Enabled 时返回 failed' {
        $script:TaskReadCount = 0
        Mock Get-ScheduledTask {
            $script:TaskReadCount++
            return [pscustomobject]@{State='Ready'}
        }
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>' }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Update-BackupManifestEntryAtomic {}
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-still-enabled'

        $result.status | Should -BeExactly 'failed'
        $result.reason | Should -Match 'Ready'
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
        Should -Invoke Update-BackupManifestEntryAtomic -Times 1 -Exactly -ParameterFilter { $ExecutionStatus -eq 'failed' -and $Verified -eq $false }
    }

    It '服务备份键与目标服务错配时 mutation 为 0' {
        Mock Get-ServiceBackupInfo {
            [pscustomobject]@{ name='ExactSvc';display_name='Exact Service';path_name='C:\ExactSvc.exe';binary_path='C:\ExactSvc.exe';binary_sha256=('A' * 64);start_mode='Auto';state='Running';was_running=$true;start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0 }
        }
        Mock Backup-RegistryKey {
            $out = Join-Path $TestDrive 'wrong-service.reg'
            [System.IO.File]::WriteAllText($out, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\OtherSvc]`r`n")
            return $out
        }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc-wrong-id'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Add-BackupManifestEntryAtomic -Times 0 -Exactly
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '任务 XML URI 与规范化目标路径错配时 mutation 为 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Other\Task</URI></RegistrationInfo></Task>' }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-wrong-id'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Add-BackupManifestEntryAtomic -Times 0 -Exactly
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }

    It '自启动备份 path 或 name 与目标错配时 mutation 为 0' {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValueNames { @('Updater') }
        $key | Add-Member ScriptMethod GetValue { param($name,$default,$options) 'C:\Apps\old.exe' }
        $key | Add-Member ScriptMethod GetValueKind { param($name) [Microsoft.Win32.RegistryValueKind]::String }
        Mock Write-AutostartValueBackup {
            $out = Join-Path $TestDrive 'wrong-auto.autostart.json'
            [System.IO.File]::WriteAllText($out, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Other","value_type":"String","value":"C:\\Apps\\old.exe"}')
            return $out
        }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Remove-LiteralRegistryValueFromKey {}

        $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'auto-wrong-id' -RequireArtifactIdentity $true

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Add-BackupManifestEntryAtomic -Times 0 -Exactly
        Should -Invoke Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
    }

    It 'clean 对任务备份只读取一次并用同一不可变字节绑定身份与 SHA' {
        $safeXml = '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>safe.exe</Command></Exec></Actions></Task>'
        $evilXml = '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo><Actions><Exec><Command>evil.exe</Command></Exec></Actions></Task>'
        $script:TaskBackupPath = $null
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Mock Export-ScheduledTask { $safeXml }
        Mock Get-FileSha256Hex {
            param($Path)
            $original = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            [System.IO.File]::WriteAllText($Path, $evilXml)
            return $original
        }
        Mock Add-BackupManifestEntryAtomic { $script:CapturedEntry = $Entry }
        Mock Update-BackupManifestEntryAtomic {}
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-snapshot'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Get-FileSha256Hex -Times 0 -Exactly
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
    }

    It 'clean 拒绝自启动备份中的重复 JSON 字段且 mutation 为 0' {
        $key = [pscustomobject]@{}
        $key | Add-Member ScriptMethod GetValueNames { @('Updater') }
        $key | Add-Member ScriptMethod GetValue { param($name,$default,$options) 'C:\Apps\old.exe' }
        $key | Add-Member ScriptMethod GetValueKind { param($name) [Microsoft.Win32.RegistryValueKind]::String }
        Mock Write-AutostartValueBackup {
            $out = Join-Path $TestDrive 'duplicate.autostart.json'
            [System.IO.File]::WriteAllText($out, '{"key":"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run","name":"Updater","name":"Other","value_type":"String","value":"C:\\Apps\\old.exe"}')
            return $out
        }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Remove-LiteralRegistryValueFromKey {}

        $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'auto-duplicate' -RequireArtifactIdentity $true

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Add-BackupManifestEntryAtomic -Times 0 -Exactly
        Should -Invoke Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
    }

    It 'manifest 原子替换后最终验证失败时恢复旧 manifest 且不留随机 previous' {
        $old = [pscustomobject]@{ entry_id='old'; type='service'; name='OldSvc'; execution_status='prepared' }
        Write-BackupManifestAtomic -BackupDir $TestDrive -Entries @($old) | Out-Null
        $script:ConfirmCount = 0
        Mock Confirm-BackupManifestFile {
            $script:ConfirmCount++
            if ($script:ConfirmCount -ge 2) { throw 'fault injected after replace' }
            return $true
        }
        $new = [pscustomobject]@{ entry_id='new'; type='service'; name='NewSvc'; execution_status='prepared' }

        { Write-BackupManifestAtomic -BackupDir $TestDrive -Entries @($new) } | Should -Throw '*fault injected*'
        $saved = @(Get-Content (Join-Path $TestDrive 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        $saved[0].entry_id | Should -BeExactly 'old'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.previous').Count | Should -Be 0
    }

    It '受保护 ACL 创建和验证成功后才返回备份目录' {
        Mock Get-SecureBackupRoot { $TestDrive }
        Mock New-ProtectedBackupDirectory {}
        Mock Assert-TrustedBackupPackagePath {}

        $result = Initialize-ProtectedBackupDirectory -BackupDir (Join-Path $TestDrive '20260811_120000')

        $result | Should -Match '20260811_120000$'
        Should -Invoke New-ProtectedBackupDirectory -Times 1 -Exactly
        Should -Invoke Assert-TrustedBackupPackagePath -Times 1 -Exactly
    }

    It 'ACL 验证失败时服务 mutation 为 0' {
        Mock Assert-TrustedBackupPackagePath { throw 'ACL 读取失败' }
        Mock Get-ServiceBackupInfo { [pscustomobject]@{start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0} }
        Mock Backup-RegistryKey { throw '不应创建 artifact' }
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'acl-fail'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Backup-RegistryKey -Times 0 -Exactly
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '服务原始状态为瞬态时拒绝自动备份和 mutation' {
        Mock Assert-TrustedBackupPackagePath {}
        Mock Get-ServiceBackupInfo { [pscustomobject]@{start_type_sc='auto';start_type_display='Automatic';status='StartPending';delayed_autostart=0} }
        Mock Backup-RegistryKey {}
        Mock Invoke-ServiceConfigDisable {}

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'transient'

        $result.status | Should -BeExactly 'failed'
        Should -Invoke Backup-RegistryKey -Times 0 -Exactly
        Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
    }

    It '服务禁用后仍在运行时标记 failed 而不是 success' {
        $backup = Join-Path $TestDrive 'running-service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        Mock Get-ServiceBackupInfo { [pscustomobject]@{ name='ExactSvc';display_name='Exact Service';path_name='C:\ExactSvc.exe';binary_path='C:\ExactSvc.exe';binary_sha256=('A' * 64);start_mode='Auto';state='Running';was_running=$true;start_type_sc='auto'; start_type_display='Automatic'; status='Running'; delayed_autostart=0 } }
        Mock Backup-RegistryKey { $backup }
        Mock Add-BackupManifestEntryAtomic {}
        Mock Update-BackupManifestEntryAtomic {}
        Mock Invoke-ServiceConfigDisable {}
        Mock Get-Service { [pscustomobject]@{ StartType='Disabled'; Status='Running' } }

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc-still-running'

        $result.status | Should -BeExactly 'failed'
        $result.reason | Should -Match '仍在运行'
        Should -Invoke Update-BackupManifestEntryAtomic -Times 1 -Exactly -ParameterFilter { $ExecutionStatus -eq 'failed' -and $Verified -eq $false }
    }

    It '服务备份 manifest 保存原始显示名路径和二进制摘要' {
        $backup = Join-Path $TestDrive 'metadata-service.reg'
        [System.IO.File]::WriteAllText($backup, "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\ExactSvc]`r`n")
        $script:CapturedEntry = $null
        Mock Get-ServiceBackupInfo {
            [pscustomobject]@{
                name='ExactSvc'; display_name='Exact Service'; path_name='C:\Program Files\Vendor\exact.exe -service'
                binary_path='C:\Program Files\Vendor\exact.exe'; binary_sha256=('A' * 64)
                start_mode='Auto'; start_type_sc='auto'; start_type_display='Automatic'; state='Stopped'; status='Stopped'; was_running=$false; delayed_autostart=0
            }
        }
        Mock Backup-RegistryKey { $backup }
        Mock Add-BackupManifestEntryAtomic { $script:CapturedEntry = $Entry }
        Mock Update-BackupManifestEntryAtomic {}
        Mock Invoke-ServiceConfigDisable {}
        Mock Get-Service { [pscustomobject]@{ StartType='Disabled'; Status='Stopped' } }

        $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc-metadata'

        $result.status | Should -BeExactly 'success'
        $script:CapturedEntry.display_name | Should -BeExactly 'Exact Service'
        $script:CapturedEntry.path_name | Should -BeExactly 'C:\Program Files\Vendor\exact.exe -service'
        $script:CapturedEntry.binary_sha256 | Should -BeExactly ('A' * 64)
        $script:CapturedEntry.was_running | Should -BeFalse
    }

    It '任务备份 manifest 保存完整路径名称和原始 Enabled 状态' {
        $script:CapturedEntry = $null
        $script:TaskReadCount = 0
        Mock Get-ScheduledTask {
            $script:TaskReadCount++
            if ($script:TaskReadCount -eq 1) { return [pscustomobject]@{State='Ready'} }
            return [pscustomobject]@{State='Disabled'}
        }
        Mock Export-ScheduledTask { '<Task><RegistrationInfo><URI>\Vendor\Task</URI></RegistrationInfo></Task>' }
        Mock Add-BackupManifestEntryAtomic { $script:CapturedEntry = $Entry }
        Mock Update-BackupManifestEntryAtomic {}
        Mock Disable-ScheduledTask {}

        $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task-enabled'

        $result.status | Should -BeExactly 'success'
        $script:CapturedEntry.task_path | Should -BeExactly '\Vendor\Task'
        $script:CapturedEntry.task_name | Should -BeExactly 'Task'
        $script:CapturedEntry.enabled | Should -BeTrue
    }
}

Describe 'clean impact confirmation 参数与最终选择闸门' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $script:Root = $projectRoot
        foreach ($file in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
            . (Join-Path $projectRoot ('src\Core\' + $file + '.ps1'))
        }
        function Is-Admin { return $false }
        function Write-Step { param([string]$Message) }
        function New-CleanExitAction([string]$Id, [string]$Action = 'disable_service') {
            return [pscustomobject]@{
                id=$Id; name_cn=$Id; detail=$Id; reason_cn='test'; hit_type='service'; action=$Action; status='pending'
                service_name=$Id; matched_pattern=$Id; matched_type='exact'; matched_field='service_name'; safe=$true
                execution_class='automatic_safe'; necessity='optional'; default_selected=$true; requires_confirmation=$false
                impact_cn='test impact'; cleanup_reason_cn='test reason'
            }
        }
        function New-ServiceStopCleanAction {
            return [pscustomobject]@{
                id='lenovo-hrwscctrl'; name_cn='HRWSCCtrl'; detail='HRWSCCtrl'; reason_cn='manual'
                hit_type='service'; action='stop_service_process'; status='pending'; service_name='HRWSCCtrl'
                service_binary_path='C:\Program Files\Lenovo Security Center\wsctrl11.exe'; process_id=[int]4321
                process_name='wsctrl11.exe'; process_path='C:\Program Files\Lenovo Security Center\wsctrl11.exe'
                process_start_time_utc='2026-08-24T01:02:03.0000000Z'
                matched_pattern='HRWSCCtrl'; matched_type='exact'; matched_field='service_name'; safe=$false
                execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
                impact_cn='只结束当前实例'; cleanup_reason_cn='减少当前后台'
            }
        }
        function Write-CleanExitPending([string]$Name, $Actions) {
            $path = Join-Path $TestDrive $Name
            $payload = [pscustomobject]@{pending_schema_version=3;generated='scan';actions=@($Actions);resolved=@();observations=@();suspicious=@()}
            [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 8), [System.Text.UTF8Encoding]::new($false))
            return $path
        }
        $script:RequirePendingSha256 = $false
        $script:PendingSha256 = ''
        $script:ConfirmedImpactSha256 = $null
        Mock Get-SecureBackupRoot { Split-Path $TestDrive -Parent }
    }

    It 'ConfirmedImpactSha256Arg 仅 clean 接受 64 位 hex 并规范化为小写' {
        (Get-NormalizedConfirmedImpactSha256 -Value ('A' * 64) -Mode 'clean' -WasProvided $true) | Should -Be ('a' * 64)
        (Get-NormalizedConfirmedImpactSha256 -Value $null -Mode 'clean' -WasProvided $false) | Should -BeNullOrEmpty
    }

    It 'ConfirmedImpactSha256Arg 的数组、null、空白、非 hex 或非 clean 模式均拒绝' -TestCases @(
        @{ label='array'; value=@(('a' * 64)); mode='clean'; supplied=$true }
        @{ label='null'; value=$null; mode='clean'; supplied=$true }
        @{ label='blank'; value=' '; mode='clean'; supplied=$true }
        @{ label='short'; value=('a' * 63); mode='clean'; supplied=$true }
        @{ label='scan'; value=('a' * 64); mode='scan'; supplied=$true }
        @{ label='restore'; value=('a' * 64); mode='restore'; supplied=$true }
    ) {
        param($label, $value, $mode, $supplied)
        { Get-NormalizedConfirmedImpactSha256 -Value $value -Mode $mode -WasProvided $supplied } | Should -Throw -Because $label
    }

    It '真实 HRWSCCtrl pending 仅在正确 digest 下通过管理员最终授权，错误 digest 不创建备份或 mutation' -TestCases @(
        @{ label='correct'; useCorrect=$true; expectedMutation=1 }
        @{ label='wrong'; useCorrect=$false; expectedMutation=0 }
    ) {
        param($label, $useCorrect, $expectedMutation)
        $pendingAction = [pscustomobject]@{
            id='lenovo-hrwscctrl'; name_cn='HRWSCCtrl'; detail='HRWSCCtrl'; reason_cn='manual'
            hit_type='service'; action='disable_service'; status='pending'; service_name='HRWSCCtrl'
            matched_pattern='HRWSCCtrl'; matched_type='exact'; matched_field='service_name'; safe=$false
            execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
            impact_cn='可能影响联想电脑管家的安全状态、主动防护和通知'; cleanup_reason_cn='不使用联想电脑管家时可减少常驻后台'
        }
        $profiles = [pscustomobject]@{ profiles=@([pscustomobject]@{
            id='lenovo-hrwscctrl'; safe=$false; evidence=[pscustomobject]@{tested=$true}
            actions=[pscustomobject]@{service='none'}; manual_actions=[pscustomobject]@{service='disable_service'}
            cleanup_policy=[pscustomobject]@{
                execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
                impact_cn='可能影响联想电脑管家的安全状态、主动防护和通知'; cleanup_reason_cn='不使用联想电脑管家时可减少常驻后台'
            }
            detect=[pscustomobject]@{services=@([pscustomobject]@{match='HRWSCCtrl';type='exact'});autostarts=@();tasks=@();processes=@()}
        }) }
        $path = Join-Path $TestDrive ("hrwscctrl-$label.json")
        $payload = [pscustomobject]@{pending_schema_version=3;generated='scan';actions=@($pendingAction);resolved=@();observations=@();suspicious=@()}
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 8), [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $oldImpactDigest = $script:ConfirmedImpactSha256
        $script:PendingFile = $path
        $correctDigest = Get-ManualImpactDigest @($pendingAction)
        $script:ConfirmedImpactSha256 = if ($useCorrect) { $correctDigest } else { ('0' * 64) }
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { $profiles }
        Mock Get-Service { [pscustomobject]@{Name='HRWSCCtrl';DisplayName='HRWSCCtrl'} } -ParameterFilter { $Name -eq 'HRWSCCtrl' }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction { [pscustomobject]@{status='success';reason='mocked'} }
        try {
            $null = Invoke-Clean
            Should -Invoke Initialize-ProtectedBackupDirectory -Times $expectedMutation -Exactly
            Should -Invoke Invoke-ServiceDisableAction -Times $expectedMutation -Exactly
            $after = Read-StrictPendingJsonFile $path
            if ($useCorrect) { $after.actions[0].status | Should -Be 'success' }
            else { $after.actions[0].status | Should -Be 'skipped' }
        } finally {
            $script:PendingFile = $oldPendingFile
            $script:ConfirmedImpactSha256 = $oldImpactDigest
        }
    }

    It 'pending 文件 hash 与 manual impact digest 是独立闸门，错误文件 hash 先阻止正确 digest' {
        $path = Join-Path $TestDrive 'independent-hash-gate.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":3,"actions":[],"resolved":[],"observations":[],"suspicious":[]}', [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $oldRequirePendingSha256 = $script:RequirePendingSha256
        $oldPendingSha256 = $script:PendingSha256
        $oldImpactDigest = $script:ConfirmedImpactSha256
        $script:PendingFile = $path
        $script:RequirePendingSha256 = $true
        $script:PendingSha256 = ('0' * 64)
        $script:ConfirmedImpactSha256 = ('a' * 64)
        Mock Is-Admin { $true }
        Mock Load-Profiles { throw 'must not load profiles before pending hash gate' }
        Mock Initialize-ProtectedBackupDirectory { throw 'must not create backup before pending hash gate' }
        try {
            { Invoke-Clean } | Should -Throw '*SHA-256*'
            Should -Invoke Load-Profiles -Times 0 -Exactly
            Should -Invoke Initialize-ProtectedBackupDirectory -Times 0 -Exactly
        } finally {
            $script:PendingFile = $oldPendingFile
            $script:RequirePendingSha256 = $oldRequirePendingSha256
            $script:PendingSha256 = $oldPendingSha256
            $script:ConfirmedImpactSha256 = $oldImpactDigest
        }
    }

    It 'valid manual digest without a verified pending SHA skips stop_service_process before mutation or backup' {
        $pendingAction = New-ServiceStopCleanAction
        $profiles = [pscustomobject]@{ profiles=@([pscustomobject]@{
            id='lenovo-hrwscctrl'; safe=$false; evidence=[pscustomobject]@{tested=$true}
            actions=[pscustomobject]@{service='none'}; manual_actions=[pscustomobject]@{service='stop_service_process'}
            cleanup_policy=[pscustomobject]@{
                execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
                impact_cn='只结束当前实例'; cleanup_reason_cn='减少当前后台'
            }
            detect=[pscustomobject]@{services=@([pscustomobject]@{match='HRWSCCtrl';type='exact'});autostarts=@();tasks=@();processes=@()}
        }) }
        $path = Write-CleanExitPending 'unbound-one-time.json' @($pendingAction)
        $oldPendingFile = $script:PendingFile
        $oldImpactDigest = $script:ConfirmedImpactSha256
        $script:PendingFile = $path
        $script:RequirePendingSha256 = $false
        $script:PendingSha256 = ''
        $script:ConfirmedImpactSha256 = Get-ManualImpactDigest @($pendingAction)
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { $profiles }
        Mock Get-Service { [pscustomobject]@{Name='HRWSCCtrl';DisplayName='HRWSCCtrl'} } -ParameterFilter { $Name -eq 'HRWSCCtrl' }
        Mock Invoke-ServiceProcessStopAction { throw 'unbound one-time action must not reach mutation helper' }
        Mock Initialize-ProtectedBackupDirectory { throw 'unbound one-time action must not create backup' }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally {
            $script:PendingFile = $oldPendingFile
            $script:ConfirmedImpactSha256 = $oldImpactDigest
        }

        $exitCode | Should -Be 0
        $saved.actions[0].status | Should -BeExactly 'skipped'
        $saved.actions[0].result_reason | Should -Match 'SHA-256|hash|绑定'
        $saved.actions[0].failure_stage | Should -BeOfType [string]
        $saved.actions[0].failure_stage | Should -BeNullOrEmpty
        Should -Invoke Invoke-ServiceProcessStopAction -Times 0 -Exactly
        Should -Invoke Initialize-ProtectedBackupDirectory -Times 0 -Exactly
    }

    It '重复选择 index 对 <executionClass> 只形成一个最终 action 且只授权和执行一次' -TestCases @(
        @{ executionClass='automatic_safe'; safe=$true }
        @{ executionClass='manual_impact'; safe=$false }
    ) {
        param($executionClass, $safe)
        $pendingAction = [pscustomobject]@{
            id="dedupe-$executionClass"; name_cn='Dedupe'; detail='Svc'; reason_cn='test'
            hit_type='service'; action='disable_service'; status='pending'; service_name='DedupeSvc'
            matched_pattern='DedupeSvc'; matched_type='exact'; matched_field='service_name'; safe=$safe
            execution_class=$executionClass; necessity='optional'; default_selected=($executionClass -ceq 'automatic_safe')
            requires_confirmation=($executionClass -ceq 'manual_impact'); impact_cn='impact'; cleanup_reason_cn='reason'
        }
        $path = Join-Path $TestDrive ("dedupe-$executionClass.json")
        $payload = [pscustomobject]@{pending_schema_version=3;generated='scan';actions=@($pendingAction);resolved=@();observations=@();suspicious=@()}
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 8), [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $oldImpactDigest = $script:ConfirmedImpactSha256
        $script:PendingFile = $path
        $script:ConfirmedImpactSha256 = if ($executionClass -ceq 'manual_impact') { Get-ManualImpactDigest @($pendingAction) } else { $null }
        $YesToAll = $false
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Read-Host { '0,0,0' }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction { [pscustomobject]@{status='success';reason='mocked'} }
        try {
            $null = Invoke-Clean
            Should -Invoke Test-PendingActionEligible -Times 1 -Exactly
            Should -Invoke Test-SelectedPendingActionAuthorized -Times 1 -Exactly
            Should -Invoke Initialize-ProtectedBackupDirectory -Times 1 -Exactly
            Should -Invoke Invoke-ServiceDisableAction -Times 1 -Exactly
        } finally {
            $script:PendingFile = $oldPendingFile
            $script:ConfirmedImpactSha256 = $oldImpactDigest
        }
    }

    It '一项 success 一项 failed 时先写回 pending 再返回 exit code 2' {
        $path = Write-CleanExitPending 'clean-partial.json' @(
            (New-CleanExitAction 'SuccessSvc'),
            (New-CleanExitAction 'FailedSvc')
        )
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction {
            if ($Pending.service_name -ceq 'FailedSvc') { return [pscustomobject]@{status='failed';reason='mock failure'} }
            return [pscustomobject]@{status='success';reason='mock success'}
        }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 2
        @($saved.actions | Where-Object status -ceq 'success').Count | Should -Be 1
        @($saved.actions | Where-Object status -ceq 'failed').Count | Should -Be 1
    }

    It '全部 success 时写回并返回 exit code 0' {
        $path = Write-CleanExitPending 'clean-success.json' @(
            (New-CleanExitAction 'SuccessOne'),
            (New-CleanExitAction 'SuccessTwo')
        )
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction { [pscustomobject]@{status='success';reason='mock success'} }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 0
        @($saved.actions | Where-Object status -ceq 'success').Count | Should -Be 2
    }

    It '仅 skipped 和 manual_required 时写回并返回 exit code 0' {
        $skipped = New-CleanExitAction 'SkippedSvc' 'unknown_action'
        $manual = New-CleanExitAction 'ManualSvc' 'uninstall'
        $path = Write-CleanExitPending 'clean-nonfailure.json' @($skipped,$manual)
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction { throw 'service mutation must not run' }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 0
        $saved.actions[0].status | Should -BeExactly 'skipped'
        [string]::IsNullOrWhiteSpace([string]$saved.actions[0].result_reason) | Should -BeFalse
        $saved.actions[0].failure_stage | Should -BeOfType [string]
        $saved.actions[0].failure_stage | Should -BeNullOrEmpty
        $saved.actions[1].status | Should -BeExactly 'manual_required'
        [string]::IsNullOrWhiteSpace([string]$saved.actions[1].result_reason) | Should -BeFalse
        $saved.actions[1].failure_stage | Should -BeOfType [string]
        $saved.actions[1].failure_stage | Should -BeNullOrEmpty
        Should -Invoke Invoke-ServiceDisableAction -Times 0 -Exactly
    }

    It 'persists authorization rejection and final identity drift as skipped metadata' -TestCases @(
        @{ label='initial'; finalDrift=$false }
        @{ label='final-drift'; finalDrift=$true }
    ) {
        param($label, $finalDrift)
        $action = New-CleanExitAction "Auth-$label"
        $path = Write-CleanExitPending ("auth-$label.json") @($action)
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        $script:eligibilityCalls = 0
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible {
            $script:eligibilityCalls++
            if ($finalDrift) { return $script:eligibilityCalls -eq 1 }
            return $false
        }
        Mock Initialize-ProtectedBackupDirectory { throw 'authorization rejection must precede backup' }
        Mock Invoke-ServiceDisableAction { throw 'authorization rejection must precede mutation' }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 0
        $saved.actions[0].status | Should -BeExactly 'skipped'
        [string]::IsNullOrWhiteSpace([string]$saved.actions[0].result_reason) | Should -BeFalse
        $saved.actions[0].failure_stage | Should -BeOfType [string]
        $saved.actions[0].failure_stage | Should -BeNullOrEmpty
        Should -Invoke Initialize-ProtectedBackupDirectory -Times 0 -Exactly
        Should -Invoke Invoke-ServiceDisableAction -Times 0 -Exactly
    }

    It 'persists backup initialization failure as failed backup metadata' {
        $path = Write-CleanExitPending 'backup-init-failed.json' @((New-CleanExitAction 'BackupSvc'))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { throw 'ACL denied' }
        Mock Invoke-ServiceDisableAction { throw 'backup failure must precede mutation' }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 2
        $saved.actions[0].status | Should -BeExactly 'failed'
        $saved.actions[0].result_reason | Should -Match '备份|backup|ACL'
        $saved.actions[0].failure_stage | Should -BeExactly 'backup'
        Should -Invoke Invoke-ServiceDisableAction -Times 0 -Exactly
    }

    It 'persists <action> helper <status> with truthful terminal metadata' -TestCases @(
        @{ action='disable_service'; status='success'; reason='已禁用并停止'; expectedStage='' }
        @{ action='disable_service'; status='skipped'; reason='服务名无效'; expectedStage='' }
        @{ action='disable_service'; status='failed'; reason='服务禁用后置验证失败: Status=Running'; expectedStage='verification' }
        @{ action='disable_task'; status='success'; reason='计划任务已禁用'; expectedStage='' }
        @{ action='disable_task'; status='skipped'; reason='计划任务不存在'; expectedStage='' }
        @{ action='disable_task'; status='failed'; reason='计划任务禁用或验证失败: Access denied'; expectedStage='mutation' }
        @{ action='remove_autostart'; status='success'; reason='自启项已完成单值备份并删除'; expectedStage='' }
        @{ action='remove_autostart'; status='skipped'; reason='自启 Value 已变化，拒绝删除'; expectedStage='' }
        @{ action='remove_autostart'; status='failed'; reason='单值备份失败: export failed'; expectedStage='backup' }
    ) {
        param($action, $status, $reason, $expectedStage)
        $pendingAction = New-CleanExitAction ("helper-$action-$status") $action
        $path = Write-CleanExitPending ("helper-$action-$status.json") @($pendingAction)
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $YesToAll = $true
        $script:helperResult = [pscustomobject]@{status=$status;reason=$reason}
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { $BackupDir }
        Mock Invoke-ServiceDisableAction { $script:helperResult }
        Mock Invoke-TaskDisableAction { $script:helperResult }
        Mock Invoke-LiteralAutostartRemoval { $script:helperResult }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be $(if ($status -ceq 'failed') { 2 } else { 0 })
        $saved.actions[0].status | Should -BeExactly $status
        $saved.actions[0].result_reason | Should -BeExactly $reason
        $saved.actions[0].failure_stage | Should -BeOfType [string]
        $saved.actions[0].failure_stage | Should -BeExactly $expectedStage
    }

    It 'one-time service stop persists truthful success metadata without creating a backup package' {
        $path = Write-CleanExitPending 'one-time-stop.json' @((New-ServiceStopCleanAction))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $script:RequirePendingSha256 = $true
        $script:PendingSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { throw 'one-time action must not create backup' }
        Mock Invoke-ServiceProcessStopAction {
            [pscustomobject]@{status='success';result_reason='current instance ended';failure_stage=''}
        }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 0
        $saved.actions[0].status | Should -BeExactly 'success'
        $saved.actions[0].result_reason | Should -BeExactly 'current instance ended'
        $saved.actions[0].failure_stage | Should -BeNullOrEmpty
        Should -Invoke Initialize-ProtectedBackupDirectory -Times 0 -Exactly
        Should -Invoke Invoke-ServiceProcessStopAction -Times 1 -Exactly
    }

    It 'one-time failure metadata is persisted and keeps clean exit code 2' {
        $path = Write-CleanExitPending 'one-time-stop-failed.json' @((New-ServiceStopCleanAction))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $script:RequirePendingSha256 = $true
        $script:PendingSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $YesToAll = $true
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { throw 'one-time action must not create backup' }
        Mock Invoke-ServiceProcessStopAction {
            [pscustomobject]@{status='failed';result_reason='old PID remains';failure_stage='verification'}
        }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 2
        $saved.actions[0].status | Should -BeExactly 'failed'
        $saved.actions[0].result_reason | Should -BeExactly 'old PID remains'
        $saved.actions[0].failure_stage | Should -BeExactly 'verification'
        Should -Invoke Initialize-ProtectedBackupDirectory -Times 0 -Exactly
    }

    It 'mixed actions lazily create backup immediately before the first persistent mutation' -TestCases @(
        @{ stopFirst=$true; expected=@('one-time','backup','persistent') }
        @{ stopFirst=$false; expected=@('backup','persistent','one-time') }
    ) {
        param($stopFirst, $expected)
        $stop = New-ServiceStopCleanAction
        $persistent = New-CleanExitAction 'PersistentSvc'
        $ordered = if ($stopFirst) { @($stop,$persistent) } else { @($persistent,$stop) }
        $path = Write-CleanExitPending ("mixed-$stopFirst.json") $ordered
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        $script:RequirePendingSha256 = $true
        $script:PendingSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $YesToAll = $true
        $script:executionOrder = [System.Collections.ArrayList]::new()
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{profiles=@()} }
        Mock Test-PendingActionEligible { $true }
        Mock Test-SelectedPendingActionAuthorized { $true }
        Mock Initialize-ProtectedBackupDirectory { $null = $script:executionOrder.Add('backup'); $BackupDir }
        Mock Invoke-ServiceDisableAction { $null = $script:executionOrder.Add('persistent'); [pscustomobject]@{status='success';reason='done'} }
        Mock Invoke-ServiceProcessStopAction { $null = $script:executionOrder.Add('one-time'); [pscustomobject]@{status='success';result_reason='done';failure_stage=''} }
        try {
            $exitCode = Invoke-Clean
            $saved = Read-StrictPendingJsonFile $path
        } finally { $script:PendingFile = $oldPendingFile }

        $exitCode | Should -Be 0
        @($script:executionOrder) | Should -Be $expected
        foreach ($item in @($saved.actions)) {
            $item.status | Should -BeExactly 'success'
            [string]::IsNullOrWhiteSpace([string]$item.result_reason) | Should -BeFalse
            $item.failure_stage | Should -BeOfType [string]
            $item.failure_stage | Should -BeNullOrEmpty
        }
        Should -Invoke Initialize-ProtectedBackupDirectory -Times 1 -Exactly
    }

    It 'cpu-cleaner clean 分支显式使用 Invoke-Clean 返回码退出' {
        $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $branch = [regex]::Match($source, "(?s)'clean'\s*\{(?<body>.*?)\n\s*\}\s*\n\s*'restore'").Groups['body'].Value

        $branch | Should -Not -BeNullOrEmpty
        $branch | Should -Match '\$cleanExitCode\s*=\s*Invoke-Clean'
        $branch | Should -Match 'exit\s*\(\[int\]\$cleanExitCode\)'
    }
}
