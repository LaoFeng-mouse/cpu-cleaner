# Pester 测试: 扫描器与评分 (Pester 5 固定版本 5.9.0)
Describe '扫描器与评分' {
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

    It '风险分级: 70+ 高度建议处理' {
        Get-RiskLevel 70 | Should -Be '高度建议处理'
        Get-RiskLevel 95 | Should -Be '高度建议处理'
    }
    It '风险分级: 50-69 可优化' {
        Get-RiskLevel 50 | Should -Be '可优化'
        Get-RiskLevel 69 | Should -Be '可优化'
    }
    It '风险分级: 30-49 建议观察' {
        Get-RiskLevel 30 | Should -Be '建议观察'
    }
    It '风险分级: 0-29 正常' {
        Get-RiskLevel 0 | Should -Be '正常'
        Get-RiskLevel 29 | Should -Be '正常'
    }
    It 'risk→分数映射' {
        Convert-RiskToScore 'high' | Should -Be 80
        Convert-RiskToScore 'medium' | Should -Be 55
        Convert-RiskToScore 'low' | Should -Be 30
    }
    It '系统进程评分为 0(正常)' {
        $top = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=1; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        $r.Score | Should -Be 0
        $r.Level | Should -Be '正常'
    }
    It '可疑进程评分 >= 50(可优化)' {
        $top = @([pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' })
        $hits = @([pscustomobject]@{ hit_type='process'; process_name='mcpman' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits $hits -AutoStartNames @('mcpman.exe') -TopProcs $top
        ($r.Score -ge 50) | Should -Be $true
    }
    It '自启进程名提取(标准化为无扩展名小写)' {
        $autos = @(
            [pscustomobject]@{ Name='SmartConnect'; Value='C:\Program Files\Lenovo\Ready For Assistant\SmartConnect.exe' },
            [pscustomobject]@{ Name='OneDrive'; Value='"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background' }
        )
        $names = Get-AutoStartProcessNames $autos
        ($names -contains 'smartconnect') | Should -Be $true
        ($names -contains 'onedrive') | Should -Be $true
        # v1.5.1 标准化契约: 不保留扩展名/大小写
        ($names -contains 'SmartConnect.exe') | Should -Be $false
    }
    It '空进程列表不报错(空机器场景)' {
        $susp = Get-SuspiciousProcesses @()
        @($susp).Count | Should -Be 0
    }
    It 'CIM 服务采集被拒时降级到 Get-Service 并保留匹配身份' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-Service {
            [pscustomobject]@{
                Name        = 'LenovoExactService'
                DisplayName = 'Lenovo Exact Service'
                Status      = 'Running'
                StartType   = 'Manual'
            }
        }

        $services = @(Get-ServicesInfo)

        $services.Count | Should -Be 1
        $services[0].Name | Should -Be 'LenovoExactService'
        $services[0].DisplayName | Should -Be 'Lenovo Exact Service'
        $services[0].State | Should -Be 'Running'
        $services[0].StartMode | Should -Be 'Manual'
        $services[0].TriggerHint | Should -BeFalse
        @($script:ScanWarnings).Count | Should -BeGreaterThan 0
        ($script:ScanWarnings -join "`n") | Should -Match 'CIM'
    }
    It 'CIM 与 Get-Service 都失败时拒绝生成假干净服务列表' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-Service { throw [System.InvalidOperationException]::new('service fallback denied') }

        { Get-ServicesInfo } | Should -Throw '*无法读取系统服务*'
    }
    It 'CIM 系统概况被拒时返回明确的兼容数据而不是空字段' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-ItemProperty {
            param($Path)
            if ($Path -like '*CentralProcessor*') {
                return [pscustomobject]@{ ProcessorNameString = 'Fallback CPU' }
            }
            return [pscustomobject]@{ SystemManufacturer = 'Fallback Vendor'; SystemProductName = 'Fallback Model' }
        }

        $info = Get-SystemInfo

        [string]::IsNullOrWhiteSpace([string]$info.Computer) | Should -BeFalse
        $info.Model | Should -Be 'Fallback Vendor Fallback Model'
        $info.CPU | Should -Be 'Fallback CPU'
        [int]$info.Threads | Should -BeGreaterThan 0
        @($script:ScanWarnings).Count | Should -BeGreaterThan 0
    }
    It 'Get-ScheduledTask 被拒时从 schtasks 兼容数据恢复任务身份' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-SchtasksQueryCsv {
            @(
                [pscustomobject]@{ FullTaskName='\Vendor\BootTask'; Status='Ready'; ScheduledState='Enabled'; ScheduleType='At system start up' },
                [pscustomobject]@{ FullTaskName='\Vendor\DailyTask'; Status='Ready'; ScheduledState='Enabled'; ScheduleType='Daily' }
            )
        }

        $tasks = @(Get-TasksInfo)

        $tasks.Count | Should -Be 2
        $tasks[0].TaskPath | Should -Be '\Vendor\'
        $tasks[0].TaskName | Should -Be 'BootTask'
        $tasks[0].LoginTrigger | Should -BeTrue
        $tasks[1].LoginTrigger | Should -BeFalse
        @($script:ScanWarnings).Count | Should -BeGreaterThan 0
    }
    It '计划任务主采集与兼容采集都失败时拒绝假报无任务' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-SchtasksQueryCsv { throw [System.InvalidOperationException]::new('schtasks denied') }

        { Get-TasksInfo } | Should -Throw '*无法读取计划任务*'
    }
    It '持续占用加分 (v1.5.7): 5 次采样中 3 次 ≥5%' {
        $top = @([pscustomobject]@{ PID=9; Name='updater'; 'CPU%'=4.2; CPUPeak=38.2; SamplesHigh=3; Samples=5; ChildCount=17; MemMB=428; Path='C:\Program Files\X\updater.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用3/5') | Should -Be $true
    }
    It '持续占用不足不加分: 5 次采样中 2 次 (阈值一半)' {
        $top = @([pscustomobject]@{ PID=9; Name='updater'; 'CPU%'=2.1; CPUPeak=9.0; SamplesHigh=2; Samples=5; ChildCount=0; MemMB=50; Path='C:\Program Files\X\updater.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用') | Should -Be $false
    }
    It '旧字段兼容: proc 无 SamplesHigh/Samples 不加持续分' {
        $top = @([pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=0.5; MemMB=10; Path='C:\Windows\System32\svchost.exe' })
        $r = Get-ProcessRiskScore -proc $top[0] -ProfileHits @() -AutoStartNames @() -TopProcs $top
        ($r.Reasons -match '持续占用') | Should -Be $false
    }
    It 'emits scan phases in the same order as the read-only pipeline' {
        $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $expected = @(
            @{ Marker='读取系统信息'; Operation='\$sys\s*=\s*Get-SystemInfo' },
            @{ Marker='检查高占用进程'; Operation='\$procs\s*=\s*Get-TopProcesses\s+12' },
            @{ Marker='检查系统服务'; Operation='\$svcs\s*=\s*Get-ServicesInfo' },
            @{ Marker='检查启动项'; Operation='\$autos\s*=\s*Get-AutoStart' },
            @{ Marker='检查计划任务'; Operation='\$tasks\s*=\s*Get-TasksInfo' },
            @{ Marker='匹配安全规则'; Operation='\$hits\s*=\s*Match-Profiles' },
            @{ Marker='生成扫描报告'; Operation='\$report\s*=\s*Write-ScanReport' }
        )
        $last = -1
        foreach ($phase in $expected) {
            [regex]::Matches($source, [regex]::Escape($phase.Marker)).Count | Should -Be 1
            $adjacent = "Write-Step\s+'{0}\.\.\.'(?:;|\r?\n)\s*{1}" -f [regex]::Escape($phase.Marker), $phase.Operation
            $source | Should -Match $adjacent
            $index = $source.IndexOf($phase.Marker, [System.StringComparison]::Ordinal)
            $index | Should -BeGreaterThan $last
            $last = $index
        }
    }
}
