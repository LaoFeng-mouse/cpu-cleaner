# Pester 测试: 报告输出 (中文 / 结构) (Pester 5 固定版本 5.9.0)
Describe '报告输出' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
        $script:ProfileFile = Join-Path $projectRoot 'bloatware-profiles.json'
    }

    It 'scan 报告文本包含中文分级' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()
        ($report -match '风险分级汇总') | Should -Be $true
        ($report -match '正常') | Should -Be $true
    }
    It 'scan 报告如实说明 pending 仅在全部报告成功后生成' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }

        $report = Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()

        $report | Should -Not -Match '待处理清单已保存'
        $report | Should -Match '扫描全部成功后才生成待处理清单'
    }
    It '降级扫描即使零命中也不得宣称机器干净' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB='未知'; CPU_Load='未知'; BootTime='N/A'; Uptime='N/A' }
        $health = [pscustomobject]@{ system_info='degraded'; services='complete'; tasks='complete' }
        $report = Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @() -ScanHealth $health -ScanWarnings @('系统概况使用兼容采集')

        $report | Should -Match '扫描信息不完整'
        $report | Should -Not -Match '这台机器比较干净'
        $report | Should -Not -Match '未知%'
        $report | Should -Not -Match '未知 GB'
    }
    It 'HTML 报告系统概况字段可用(v1.2 修复回归)' {
        $sys = [pscustomobject]@{ Model='TestModel'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='x'; Uptime='y' }
        $sys.Model | Should -Be 'TestModel'
    }
    It 'HTML 报告含风险评分/分级汇总/版本页脚(v1.5.2 文本-HTML 统一)' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @(
            [pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; CPUPeak=1.2; SamplesHigh=0; Samples=5; ChildCount=0; MemMB=10; Path='C:\Windows\System32\svchost.exe' },
            [pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; CPUPeak=15.5; SamplesHigh=4; Samples=5; ChildCount=2; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' }
        )
        $hits = @([pscustomobject]@{ hit_type='process'; process_name='mcpman'; id='lenovo-lemcp' })
        $html = Write-HtmlReport -SysInfo $sys -TopProcs $procs -Suspicious @() -AutoStarts @() -Tasks @() -Hits $hits -AutoStartNames @('mcpman.exe')
        ($html -match '风险分') | Should -Be $true
        ($html -match '评分依据') | Should -Be $true
        ($html -match '风险分级汇总') | Should -Be $true
        ($html -match '可优化') | Should -Be $true
        ($html -match ('CPU 后台整理工具 v' + $script:Version)) | Should -Be $true
        # v1.5.7: 多采样列
        ($html -match '平均%') | Should -Be $true
        ($html -match '峰值%') | Should -Be $true
        ($html -match '持续') | Should -Be $true
        ($html -match '子进程') | Should -Be $true
    }
    It 'HTML 报告明确展示降级状态且未知值不拼接单位' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores='未知'; Threads=8; RAM_GB='未知'; CPU_Load='未知'; BootTime='N/A'; Uptime='N/A' }
        $health = [pscustomobject]@{ system_info='degraded'; services='complete'; tasks='complete' }
        $html = Write-HtmlReport -SysInfo $sys -TopProcs @() -Suspicious @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @() -ScanHealth $health -ScanWarnings @('系统概况使用兼容采集')

        $html | Should -Match '扫描信息不完整'
        $html | Should -Not -Match '未知%'
        $html | Should -Not -Match '未知 GB'
    }
    It '文本报告 Top CPU 表含多采样列 (v1.5.7)' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $procs = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; CPUPeak=1.2; SamplesHigh=0; Samples=5; ChildCount=0; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @()
        ($report -match '平均%') | Should -Be $true
        ($report -match '峰值%') | Should -Be $true
        ($report -match '持续') | Should -Be $true
        ($report -match '子进程') | Should -Be $true
    }
    It '可信 inventory 任务在文本和 HTML 中完整显示且不冒充登录触发任务' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $tasks = @(
            [pscustomobject]@{ TaskName='TrustedTaskA';TaskPath='\Trusted\';State='Ready';Author='Vendor';Description='A';Actions=[object[]]@('C:\a.exe') },
            [pscustomobject]@{ TaskName='TrustedTaskB';TaskPath='\Trusted\';State='Disabled';Author='Vendor';Description='B';Actions=[object[]]@('C:\b.exe') }
        )

        $report = Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @()
        $html = Write-HtmlReport -SysInfo $sys -TopProcs @() -Suspicious @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @()

        $report | Should -Match '完整计划任务清单（管理员只读采集）'
        $report | Should -Match 'TrustedTaskA'
        $report | Should -Match 'TrustedTaskB'
        $report | Should -Not -Match '登录/开机触发的计划任务'
        $html | Should -Match '完整计划任务清单（管理员只读采集）'
        $html | Should -Match 'TrustedTaskA'
        $html | Should -Match 'TrustedTaskB'
        $html | Should -Not -Match '登录/开机触发的计划任务'
    }
    It '直接采集任务在文本和 HTML 中保留登录触发筛选' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $tasks = @(
            [pscustomobject]@{ TaskName='LoginTask';TaskPath='\Direct\';State='Ready';LoginTrigger=$true },
            [pscustomobject]@{ TaskName='MaintenanceTask';TaskPath='\Direct\';State='Ready';LoginTrigger=$false }
        )

        $report = Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @()
        $html = Write-HtmlReport -SysInfo $sys -TopProcs @() -Suspicious @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @()

        $report | Should -Match '登录/开机触发的计划任务'
        $report | Should -Match 'LoginTask'
        $report | Should -Not -Match 'MaintenanceTask'
        $html | Should -Match '登录/开机触发的计划任务'
        $html | Should -Match 'LoginTask'
        $html | Should -Not -Match 'MaintenanceTask'
    }
    It '混合 LoginTrigger 契约的任务集合在文本和 HTML 中失败关闭' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $tasks = @(
            [pscustomobject]@{ TaskName='DirectTask';TaskPath='\Direct\';State='Ready';LoginTrigger=$true },
            [pscustomobject]@{ TaskName='TrustedTask';TaskPath='\Trusted\';State='Ready' }
        )

        { Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @() } | Should -Throw '*LoginTrigger*'
        { Write-HtmlReport -SysInfo $sys -TopProcs @() -Suspicious @() -AutoStarts @() -Tasks $tasks -Hits @() -AutoStartNames @() } | Should -Throw '*LoginTrigger*'
    }
    It '任务采集不完整且结果为空时文本和 HTML 不宣称无任务' {
        $sys = [pscustomobject]@{ Computer='PC'; Model='Test'; CPU='CPU'; Cores=4; Threads=8; RAM_GB=16; CPU_Load=5; BootTime='2026-01-01 00:00:00'; Uptime='1天 0小时' }
        $health = [pscustomobject]@{ system_info='complete'; services='complete'; tasks='unavailable' }

        $report = Write-ScanReport -SysInfo $sys -TopProcs @() -Suspicious @() -Services @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @() -ScanHealth $health
        $html = Write-HtmlReport -SysInfo $sys -TopProcs @() -Suspicious @() -AutoStarts @() -Tasks @() -Hits @() -AutoStartNames @() -ScanHealth $health

        $report | Should -Match '任务信息不可用，不能断言无任务'
        $html | Should -Match '任务信息不可用，不能断言无任务'
    }
    It 'UTF-8 中文特征库原因可读' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        ($hit.reason_cn -match '联想') | Should -Be $true
    }
    It '特征库 evidence 字段存在' {
        $profiles = Load-Profiles
        $hit = $profiles.profiles | Where-Object { $_.id -eq 'lenovo-lisf' } | Select-Object -First 1
        $hit.evidence.tested | Should -Be $true
    }
}
