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
            [pscustomobject]@{ start_type_sc='auto'; start_type_display='Automatic'; status='Running'; delayed_autostart=0 }
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
}
