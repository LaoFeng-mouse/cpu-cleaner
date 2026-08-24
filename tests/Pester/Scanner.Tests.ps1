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
        $script:PendingFile = Join-Path $TestDrive 'pending_actions.json'
        if ([System.IO.File]::Exists($script:PendingFile)) { [System.IO.File]::Delete($script:PendingFile) }
        if ([System.IO.Directory]::Exists($script:PendingFile)) { [System.IO.Directory]::Delete($script:PendingFile, $true) }
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
    It '可疑进程保留 PID 名称 路径与 UTC 启动时间' {
        $top = [pscustomobject]@{
            PID=4242; Name='suspect'; 'CPU%'=8; MemMB=50
            Path='C:\Temp\suspect.exe'; StartTimeUtc='2026-08-11T00:00:00.0000000Z'
        }

        $row = @(Get-SuspiciousProcesses @($top))[0]

        $row.PID | Should -Be 4242
        $row.Name | Should -BeExactly 'suspect'
        $row.Path | Should -BeExactly 'C:\Temp\suspect.exe'
        $row.StartTimeUtc | Should -BeExactly '2026-08-11T00:00:00.0000000Z'
        $row.CanStop | Should -BeTrue
        $row.StopBlockReason | Should -BeExactly ''
    }
    It '可疑进程身份缺少路径或启动时间时不可停止' {
        $top = [pscustomobject]@{PID=4242;Name='suspect';'CPU%'=8;MemMB=50;Path='';StartTimeUtc=''}

        $row = @(Get-SuspiciousProcesses @($top))[0]

        $row.CanStop | Should -BeFalse
        $row.StopBlockReason | Should -Match '身份不完整'
    }
    It '有效签名的第三方高 CPU 进程仍进入按需停止清单' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ Subject='CN=Vendor' } } }
        $top = [pscustomobject]@{
            PID=4301; Name='VendorAgent'; 'CPU%'=6.5; CPUPeak=9.2; SamplesHigh=4; Samples=5; MemMB=120
            Path='C:\Program Files\Vendor\VendorAgent.exe'; StartTimeUtc='2026-08-24T00:00:00.0000000Z'
        }

        $row = @(Get-SuspiciousProcesses @($top))[0]

        $row.Name | Should -BeExactly 'VendorAgent'
        $row.CanStop | Should -BeTrue
        $row.Necessity | Should -BeExactly '按需结束'
        $row.Reason | Should -Match '高 CPU'
        $row.Impact | Should -Match '当前进程'
    }
    It '系统进程名若运行在可疑路径不能冒充受保护进程' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='NotSigned' } }
        $top = [pscustomobject]@{
            PID=4302; Name='svchost'; 'CPU%'=7; CPUPeak=8; SamplesHigh=4; Samples=5; MemMB=30
            Path='C:\Users\Public\Downloads\svchost.exe'; StartTimeUtc='2026-08-24T00:00:00.0000000Z'
        }

        $row = @(Get-SuspiciousProcesses @($top))[0]

        $row.Name | Should -BeExactly 'svchost'
        $row.Reason | Should -Match '路径可疑'
        $row.CanStop | Should -BeTrue
    }
    It '低 CPU 的普通第三方进程不进入停止清单' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid' } }
        $top = [pscustomobject]@{
            PID=4303; Name='QuietAgent'; 'CPU%'=0.4; CPUPeak=0.8; SamplesHigh=0; Samples=5; MemMB=80
            Path='C:\Program Files\Vendor\QuietAgent.exe'; StartTimeUtc='2026-08-24T00:00:00.0000000Z'
        }

        @(Get-SuspiciousProcesses @($top)).Count | Should -Be 0
    }
    It '高 CPU 进程命中特征规则时解释具体 OEM 原因' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid' } }
        $top = [pscustomobject]@{
            PID=4304; Name='mcpman'; 'CPU%'=8; CPUPeak=11; SamplesHigh=5; Samples=5; MemMB=90
            Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe'; StartTimeUtc='2026-08-24T00:00:00.0000000Z'
        }
        $hits = @([pscustomobject]@{ hit_type='process'; process_id=4304; name_cn='联想 AI MCP 管理器'; reason_cn='联想 AI 全家桶核心后台' })

        $row = @(Get-SuspiciousProcesses @($top) $hits)[0]

        $row.Reason | Should -Match '联想 AI MCP 管理器'
        $row.Reason | Should -Match '联想 AI 全家桶核心后台'
    }
    It 'CIM 服务采集被拒时 Get-Service fallback 保留观察身份但标记降级' {
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
        $services[0].PathName | Should -BeExactly ''
        $services[0].ProcessId | Should -Be 0
        $services[0].TriggerHint | Should -BeFalse
        @($script:ScanWarnings).Count | Should -BeGreaterThan 0
        ($script:ScanWarnings -join "`n") | Should -Match 'CIM'
        $script:ScanHealth.services | Should -BeExactly 'degraded'
    }
    It 'CIM 与 Get-Service 都失败时拒绝生成假干净服务列表' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-Service { throw [System.InvalidOperationException]::new('service fallback denied') }

        { Get-ServicesInfo } | Should -Throw '*无法读取系统服务*'
        $script:ScanHealth.services | Should -Not -BeExactly 'complete'
    }
    It 'CIM 服务对象存在但身份为空时转入 Get-Service 兼容采集' {
        Mock Get-CimInstance { [pscustomobject]@{ Name=''; DisplayName=''; State='Running'; StartMode='Auto'; PathName=''; ProcessId=1 } }
        Mock Get-Service { [pscustomobject]@{ Name='FallbackService'; DisplayName='Fallback Service'; Status='Running'; StartType='Automatic' } }

        $services = @(Get-ServicesInfo)

        $services.Count | Should -Be 1
        $services[0].Name | Should -Be 'FallbackService'
        $script:ScanHealth.services | Should -BeExactly 'degraded'
    }
    It 'CIM 服务名称有效但显示名或状态字段为空时转入兼容采集' {
        Mock Get-CimInstance {
            [pscustomobject]@{ Name='PrimaryService'; DisplayName=''; State=''; StartMode=''; PathName=''; ProcessId=1 }
        }
        Mock Get-Service {
            [pscustomobject]@{ Name='FallbackService'; DisplayName='Fallback Service'; Status='Running'; StartType='Automatic' }
        }

        $services = @(Get-ServicesInfo)

        $services.Count | Should -Be 1
        $services[0].Name | Should -Be 'FallbackService'
        $services[0].DisplayName | Should -Be 'Fallback Service'
        $script:ScanHealth.services | Should -BeExactly 'degraded'
    }
    It 'Get-Service 兼容采集返回空身份时拒绝假报服务列表' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-Service { [pscustomobject]@{ Name=''; DisplayName=''; Status='Running'; StartType='Automatic' } }

        { Get-ServicesInfo } | Should -Throw '*无法读取系统服务*'
        $script:ScanHealth.services | Should -Not -BeExactly 'complete'
    }
    It 'Get-Service 兼容采集缺少动作所需状态时失败关闭' {
        Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
        Mock Get-Service { [pscustomobject]@{ Name='ExactSvc'; DisplayName='Exact'; Status=''; StartType='Automatic' } }

        { Get-ServicesInfo } | Should -Throw '*不完整*'
        $script:ScanHealth.services | Should -Not -BeExactly 'complete'
    }
    It 'Get-Service 兼容采集拒绝不可恢复的未知 StartMode' {
        foreach ($invalidStartMode in @('Unknown','DelayedAuto','arbitrary')) {
            Reset-ScanDiagnostics
            Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
            Mock Get-Service {
                [pscustomobject]@{ Name='ExactSvc'; DisplayName='Exact'; Status='Running'; StartType=$invalidStartMode }
            }

            { Get-ServicesInfo } | Should -Throw '*不完整*' -Because "StartMode $invalidStartMode cannot be restored safely"
            $script:ScanHealth.services | Should -Not -BeExactly 'complete'
        }
    }
    It 'Get-Service 兼容采集接受可恢复 StartMode 但始终保持降级' {
        foreach ($validStartMode in @('Automatic','manual','DISABLED','Boot','system')) {
            Reset-ScanDiagnostics
            Mock Get-CimInstance { throw [System.UnauthorizedAccessException]::new('CIM denied') }
            Mock Get-Service {
                [pscustomobject]@{ Name='ExactSvc'; DisplayName='Exact'; Status='Running'; StartType=$validStartMode }
            }

            $services = @(Get-ServicesInfo)
            $services.Count | Should -Be 1
            $script:ScanHealth.services | Should -BeExactly 'degraded'
        }
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
        $script:ScanHealth.system_info | Should -Be 'degraded'
    }
    It 'CIM 系统概况对象存在但关键字段为空时使用兼容信息并标记降级' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { [pscustomobject]@{ LastBootUpTime = Get-Date } }
                'Win32_Processor' { [pscustomobject]@{ Name=''; NumberOfCores=0; NumberOfLogicalProcessors=0; LoadPercentage=$null } }
                'Win32_ComputerSystem' { [pscustomobject]@{ Name=''; Manufacturer=''; Model=''; TotalPhysicalMemory=0 } }
            }
        }
        Mock Get-ItemProperty {
            param($Path)
            if ($Path -like '*CentralProcessor*') { return [pscustomobject]@{ ProcessorNameString = 'Fallback CPU' } }
            return [pscustomobject]@{ SystemManufacturer = 'Fallback Vendor'; SystemProductName = 'Fallback Model' }
        }

        $info = Get-SystemInfo

        $info.Model | Should -Be 'Fallback Vendor Fallback Model'
        $info.CPU | Should -Be 'Fallback CPU'
        $script:ScanHealth.system_info | Should -Be 'degraded'
    }
    It 'CIM 系统概况关键身份完整但 CPU 负载为空时标记降级' {
        Mock Get-CimInstance {
            param($ClassName)
            switch ($ClassName) {
                'Win32_OperatingSystem' { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddHours(-1) } }
                'Win32_Processor' { [pscustomobject]@{ Name='CPU'; NumberOfCores=4; NumberOfLogicalProcessors=8; LoadPercentage=$null } }
                'Win32_ComputerSystem' { [pscustomobject]@{ Name='PC'; Manufacturer='Vendor'; Model='Model'; TotalPhysicalMemory=16GB } }
            }
        }

        $info = Get-SystemInfo

        $info.CPU_Load | Should -Be '未知'
        $script:ScanHealth.system_info | Should -Be 'degraded'
        ($script:ScanWarnings -join "`n") | Should -Match 'CPU 负载'
    }
    It 'Get-ScheduledTask 主路径从真实 cmdlet 形状收集全部必需字段' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                TaskName='PrimaryTask'; TaskPath='\Vendor\'; State=[System.ServiceProcess.ServiceControllerStatus]::Running
                Author='Vendor'; Description='Primary description'
                Triggers=@([pscustomobject]@{ CimClass=[pscustomobject]@{ CimClassName='MSFT_TaskLogonTrigger' } })
                Actions=@([pscustomobject]@{ CimClass=[pscustomobject]@{ CimClassName='MSFT_TaskExecAction' }; Execute='C:\Program Files\Vendor\task.exe'; Arguments='--run'; WorkingDirectory='C:\Program Files\Vendor' })
            }
        }

        $tasks = @(Get-TasksInfo)

        $tasks.Count | Should -Be 1
        @($tasks[0].PSObject.Properties.Name) | Should -Contain 'Author'
        @($tasks[0].PSObject.Properties.Name) | Should -Contain 'Description'
        @($tasks[0].PSObject.Properties.Name) | Should -Contain 'Actions'
        $tasks[0].Author | Should -BeExactly 'Vendor'
        $tasks[0].Description | Should -BeExactly 'Primary description'
        @($tasks[0].Actions) | Should -Be @('C:\Program Files\Vendor\task.exe --run')
        $tasks[0].State -is [string] | Should -BeTrue
        $tasks[0].State | Should -BeExactly 'Running'
        $script:ScanHealth.tasks | Should -BeExactly 'complete'
    }
    It 'Task Scheduler COM query collects registration metadata and normalized actions from COM-shaped objects' {
        $script:FakeComTask = [pscustomobject]@{
            Path='\Vendor\ComTask'; State=3
            Definition=[pscustomobject]@{
                Triggers=@([pscustomobject]@{ Type=8 })
                RegistrationInfo=[pscustomobject]@{ Author='Vendor'; Description='COM description' }
                Actions=@([pscustomobject]@{ Type=0; Execute='C:\Vendor\com-task.exe'; Arguments='/quiet'; WorkingDirectory='C:\Vendor' })
            }
        }
        $script:FakeTaskFolder = [pscustomobject]@{}
        $script:FakeTaskFolder | Add-Member ScriptMethod GetTasks { param($Flags) return @($script:FakeComTask) }
        $script:FakeTaskFolder | Add-Member ScriptMethod GetFolders { param($Flags) return @() }
        $script:FakeScheduler = [pscustomobject]@{}
        $script:FakeScheduler | Add-Member ScriptMethod Connect {}
        $script:FakeScheduler | Add-Member ScriptMethod GetFolder { param($Path) return $script:FakeTaskFolder }
        Mock New-Object { $script:FakeScheduler } -ParameterFilter { $ComObject -eq 'Schedule.Service' }

        $records = @(Invoke-TaskSchedulerComQuery)

        $records.Count | Should -Be 1
        $records[0].Path | Should -BeExactly '\Vendor\ComTask'
        $records[0].Author | Should -BeExactly 'Vendor'
        $records[0].Description | Should -BeExactly 'COM description'
        @($records[0].Actions) | Should -Be @('C:\Vendor\com-task.exe /quiet')
    }
    It 'Get-ScheduledTask 主路径拒绝缺失必需采集字段' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskName='Missing'; TaskPath='\'; State='Ready'; Triggers=@(); Actions=@() }
        }
        function Invoke-TaskSchedulerComQuery { throw 'COM incomplete' }

        { Get-TasksInfo } | Should -Throw '*无法读取计划任务*'
        $script:ScanHealth.tasks | Should -Not -BeExactly 'complete'
    }
    It 'Get-ScheduledTask 被拒时从完整 COM 记录恢复全部必需字段' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-TaskSchedulerComQuery {
            @(
                [pscustomobject]@{ Path='\Vendor\BootTask'; State=3; TriggerTypes=@(8); Author='Vendor'; Description='Boot description'; Actions=@('C:\boot.exe --start') },
                [pscustomobject]@{ Path='\Vendor\DailyTask'; State=3; TriggerTypes=@(2); Author='Vendor'; Description='Daily description'; Actions=@('C:\daily.exe') }
            )
        }

        $tasks = @(Get-TasksInfo)

        $tasks.Count | Should -Be 2
        $tasks[0].TaskPath | Should -Be '\Vendor\'
        $tasks[0].TaskName | Should -Be 'BootTask'
        $tasks[0].LoginTrigger | Should -BeTrue
        $tasks[0].Author | Should -BeExactly 'Vendor'
        $tasks[0].Description | Should -BeExactly 'Boot description'
        @($tasks[0].Actions) | Should -Be @('C:\boot.exe --start')
        $tasks[1].LoginTrigger | Should -BeFalse
        @($script:ScanWarnings).Count | Should -BeGreaterThan 0
        $script:ScanHealth.tasks | Should -Be 'complete'
    }
    It '数字触发器类型不受本地化文本影响' {
        $task = Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path='\Hersteller\Beim Systemstart'; State=3; TriggerTypes=@(8); Author='Hersteller'; Description='Beschreibung'; Actions=@('C:\start.exe') })

        $task.LoginTrigger | Should -BeTrue
        $task.TaskName | Should -Be 'Beim Systemstart'
    }
    It 'COM 任务记录缺少状态或触发器字段时拒绝默认成 Unknown 和无触发器' {
        { Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path='\Vendor\MissingFields' }) } | Should -Throw '*缺少字段*'
        { Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path='\Vendor\MissingTriggers'; State=3 }) } | Should -Throw '*缺少字段*'
    }
    It 'COM 任务触发器枚举只接受 Windows 官方完整取值集合' {
        foreach ($value in @(0,1,2,3,4,5,6,7,8,9,11,12)) {
            { Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path="\Vendor\Valid$value"; State=3; TriggerTypes=@($value); Author='Vendor'; Description='Valid'; Actions=@('C:\task.exe') }) } | Should -Not -Throw -Because "trigger type $value is defined by TASK_TRIGGER_TYPE2"
        }
        foreach ($value in @(-1,10,13,99)) {
            { Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path="\Vendor\Invalid$value"; State=3; TriggerTypes=@($value); Author='Vendor'; Description='Invalid'; Actions=@('C:\task.exe') }) } | Should -Throw '*无效触发器类型*' -Because "trigger type $value is not defined by TASK_TRIGGER_TYPE2"
        }
        { Convert-TaskSchedulerComRecord ([pscustomobject]@{ Path='\Vendor\InvalidText'; State=3; TriggerTypes=@('x'); Author='Vendor'; Description='Invalid'; Actions=@('C:\task.exe') }) } | Should -Throw '*无效触发器类型*'
    }
    It '主任务采集返回空列表时必须转入兼容采集' {
        Mock Get-ScheduledTask { @() }
        function Invoke-TaskSchedulerComQuery {
            @([pscustomobject]@{ Path='\Vendor\FallbackTask'; State=3; TriggerTypes=@(9); Author='Vendor'; Description='Fallback'; Actions=@('C:\fallback.exe') })
        }

        $tasks = @(Get-TasksInfo)

        $tasks.Count | Should -Be 1
        $tasks[0].TaskName | Should -Be 'FallbackTask'
        $script:ScanHealth.tasks | Should -Be 'complete'
    }
    It '任务兼容采集返回空列表时拒绝假报无任务' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-TaskSchedulerComQuery { @() }

        { Get-TasksInfo } | Should -Throw '*无法读取计划任务*'
    }
    It '任务兼容采集包含畸形身份时拒绝静默丢弃' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-TaskSchedulerComQuery {
            @([pscustomobject]@{ Path='\'; State=3; TriggerTypes=@(8) })
        }

        { Get-TasksInfo } | Should -Throw '*无法读取计划任务*'
    }
    It '计划任务主采集与兼容采集都失败时拒绝假报无任务' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('scheduled task denied') }
        function Invoke-TaskSchedulerComQuery { throw [System.InvalidOperationException]::new('task scheduler denied') }

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
    It '有效可信 inventory 为第三方手动运行服务派生内存 TriggerHint 且不扩展包对象' {
        $service = [pscustomobject]@{ Name='TrustedSvc';DisplayName='Trusted Service';State='Running';StartMode='Manual';PathName='C:\Program Files\Vendor\trusted.exe';ProcessId=7 }
        $task = [pscustomobject]@{ TaskName='TrustedTask';TaskPath='\Trusted\';State='Ready';Author='Vendor';Description='Trusted';Actions=[object[]]@('C:\trusted-task.exe') }
        Mock Read-TrustedInventoryPackage {
            [pscustomobject]@{ Package=[pscustomobject]@{ services=[object[]]@($service);tasks=[object[]]@($task);health=[pscustomobject]@{services='complete';tasks='complete'};warnings=[object[]]@() };Sha256=('a' * 64) }
        }
        Mock Get-ServicesInfo { throw 'normal service collector must be bypassed' }
        Mock Get-TasksInfo { throw 'normal task collector must be bypassed' }

        $result = Get-ScanServiceTaskInventory -InventoryNonce ('a' * 64)

        $result.Services -is [System.Array] | Should -BeTrue
        $result.Tasks -is [System.Array] | Should -BeTrue
        $result.Services[0].TriggerHint | Should -BeTrue
        $result.Services[0].Name | Should -BeExactly 'TrustedSvc'
        $service.PSObject.Properties.Name | Should -Not -Contain 'TriggerHint'
        [object]::ReferenceEquals($result.Services[0], $service) | Should -BeFalse
        [object]::ReferenceEquals($result.Tasks[0], $task) | Should -BeTrue
        $script:ScanHealth.services | Should -BeExactly 'complete'
        $script:ScanHealth.tasks | Should -BeExactly 'complete'
        Assert-MockCalled Read-TrustedInventoryPackage -Times 1 -Exactly -ParameterFilter { $Nonce -ceq ('a' * 64) }
        Assert-MockCalled Get-ServicesInfo -Times 0 -Exactly
        Assert-MockCalled Get-TasksInfo -Times 0 -Exactly
    }
    It '可信 inventory 读取失败时中止且不生成报告或 pending' {
        Mock Get-SystemInfo { [pscustomobject]@{} }
        Mock Get-TopProcesses { @() }
        Mock Read-TrustedInventoryPackage { throw 'invalid trusted package' }
        Mock Write-ScanReport {}
        Mock Write-HtmlReport {}
        Mock Save-PendingActions {}

        { Invoke-ScanMode -InventoryNonce ('b' * 64) } | Should -Throw '*invalid trusted package*'

        Assert-MockCalled Write-ScanReport -Times 0 -Exactly
        Assert-MockCalled Write-HtmlReport -Times 0 -Exactly
        Assert-MockCalled Save-PendingActions -Times 0 -Exactly
    }
    It 'pending 不存在时扫描前失效处理成功' {
        { Remove-PendingForScan } | Should -Not -Throw
        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
    }
    It '早期采集失败前先删除旧 pending' {
        [System.IO.File]::WriteAllText($script:PendingFile, 'old pending')
        Mock Get-SystemInfo { throw 'collector failed' }

        { Invoke-ScanMode } | Should -Throw '*collector failed*'

        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
    }
    It 'pending 失效失败时在任何采集器前中止' {
        $null = [System.IO.Directory]::CreateDirectory($script:PendingFile)
        Mock Get-SystemInfo { [pscustomobject]@{} }
        Mock Get-TopProcesses { @() }
        Mock Get-ScanServiceTaskInventory { [pscustomobject]@{ Services=@(); Tasks=@() } }
        Mock Get-AutoStart { @() }
        Mock Match-Profiles { @() }

        { Invoke-ScanMode } | Should -Throw

        Assert-MockCalled Get-SystemInfo -Times 0 -Exactly
        Assert-MockCalled Get-TopProcesses -Times 0 -Exactly
        Assert-MockCalled Get-ScanServiceTaskInventory -Times 0 -Exactly
        Assert-MockCalled Get-AutoStart -Times 0 -Exactly
        Assert-MockCalled Match-Profiles -Times 0 -Exactly
    }
    It 'HTML 生成失败时不创建 pending' {
        Mock Get-SystemInfo { [pscustomobject]@{ Computer='PC' } }
        Mock Get-TopProcesses { @() }
        Mock Get-SuspiciousProcesses { @() }
        Mock Get-ScanServiceTaskInventory { [pscustomobject]@{ Services=@(); Tasks=@() } }
        Mock Get-AutoStart { @() }
        Mock Match-Profiles { @() }
        Mock Get-AutoStartProcessNames { @() }
        Mock Write-ScanReport { 'text report' }
        Mock Write-HtmlReport { throw 'html failed' }
        Mock Save-PendingActions { [System.IO.File]::WriteAllText($script:PendingFile, 'new pending') }

        { Invoke-ScanMode -ReportPath (Join-Path $TestDrive 'report.html') } | Should -Throw '*html failed*'

        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
        Assert-MockCalled Save-PendingActions -Times 0 -Exactly
    }
    It '文本与可选 HTML 完成后最后保存 pending' {
        $script:scanEvents = [System.Collections.Generic.List[string]]::new()
        Mock Get-SystemInfo { [pscustomobject]@{ Computer='PC' } }
        Mock Get-TopProcesses { @() }
        Mock Get-SuspiciousProcesses { @() }
        Mock Get-ScanServiceTaskInventory { [pscustomobject]@{ Services=@(); Tasks=@() } }
        Mock Get-AutoStart { @() }
        Mock Match-Profiles { @() }
        Mock Get-AutoStartProcessNames { @() }
        Mock Write-ScanReport { $script:scanEvents.Add('text'); 'text report' }
        Mock Write-HtmlReport { $script:scanEvents.Add('html'); 'html report' }
        Mock Save-PendingActions { $script:scanEvents.Add('save') }

        $result = Invoke-ScanMode -ReportPath (Join-Path $TestDrive 'report.html')

        $result | Should -BeExactly 'text report'
        @($script:scanEvents) -join ',' | Should -BeExactly 'text,html,save'
        $scannerSource = Get-Content (Join-Path $projectRoot 'src\Core\Scanner.ps1') -Raw -Encoding UTF8
        $scannerSource | Should -Match 'Save-PendingActions[^\r\n]*\r?\n\s*return \$report'
    }
    It 'pending 保存失败在报告完成后向上传播' {
        $script:scanEvents = [System.Collections.Generic.List[string]]::new()
        $reportPath = Join-Path $TestDrive 'report.html'
        Mock Get-SystemInfo { [pscustomobject]@{ Computer='PC' } }
        Mock Get-TopProcesses { @() }
        Mock Get-SuspiciousProcesses { @() }
        Mock Get-ScanServiceTaskInventory { [pscustomobject]@{ Services=@(); Tasks=@() } }
        Mock Get-AutoStart { @() }
        Mock Match-Profiles { @() }
        Mock Get-AutoStartProcessNames { @() }
        Mock Write-ScanReport { $script:scanEvents.Add('text'); 'text report' }
        Mock Write-HtmlReport { $script:scanEvents.Add('html'); 'html report' }
        Mock Save-PendingActions { $script:scanEvents.Add('save'); throw 'save failed' }

        { Invoke-ScanMode -ReportPath $reportPath } | Should -Throw '*save failed*'

        @($script:scanEvents) -join ',' | Should -BeExactly 'text,html,save'
        Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
    }
    It '默认 scan 服务或任务不完整时全部尝试后失败关闭' {
        Mock Get-ServicesInfo { Set-ScanHealthDegraded services; throw 'services unavailable' }
        Mock Get-TasksInfo { Set-ScanHealthDegraded tasks; throw 'tasks unavailable' }

        { Get-ScanServiceTaskInventory } | Should -Throw '*完整*'

        $script:ScanHealth.services | Should -Not -BeExactly 'complete'
        $script:ScanHealth.tasks | Should -Not -BeExactly 'complete'
        Assert-MockCalled Get-ServicesInfo -Times 1 -Exactly
        Assert-MockCalled Get-TasksInfo -Times 1 -Exactly
    }
    It '默认 scan 即使采集器返回数据也拒绝不完整健康状态' {
        Mock Get-ServicesInfo {
            Set-ScanHealthDegraded services
            [pscustomobject]@{ Name='PartialSvc';DisplayName='Partial';State='Running';StartMode='Manual';PathName='';ProcessId=0;TriggerHint=$false }
        }
        Mock Get-TasksInfo {
            [pscustomobject]@{ TaskName='Task';TaskPath='\';State='Ready';Author='';Description='';Actions=[object[]]@() }
        }

        { Get-ScanServiceTaskInventory } | Should -Throw '*完整*'
    }
    It '显式 limited 不尝试任务并将空任务标为 unavailable 且告警' {
        Mock Get-ServicesInfo { [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Running';StartMode='Auto';PathName='C:\svc.exe';ProcessId=1;TriggerHint=$false } }
        Mock Get-TasksInfo { throw 'tasks must not be attempted in limited mode' }

        $result = Get-ScanServiceTaskInventory -AllowLimited

        $result.Tasks -is [System.Array] | Should -BeTrue
        $result.Tasks.Count | Should -Be 0
        $script:ScanHealth.tasks | Should -BeExactly 'unavailable'
        @($script:ScanWarnings) -join "`n" | Should -Match '计划任务|scheduled tasks'
        Assert-MockCalled Get-TasksInfo -Times 0 -Exactly
    }
    It '显式 limited 服务失败时以 degraded 空数组继续并告警' {
        Mock Get-ServicesInfo { throw 'service access denied' }

        $result = Get-ScanServiceTaskInventory -AllowLimited

        $result.Services -is [System.Array] | Should -BeTrue
        $result.Services.Count | Should -Be 0
        $script:ScanHealth.services | Should -BeExactly 'degraded'
        @($script:ScanWarnings) -join "`n" | Should -Match '服务|services'
    }
    It '显式 limited 保留服务兼容采集的安全部分并补充降级告警' {
        Mock Get-ServicesInfo {
            Set-ScanHealthDegraded services
            [pscustomobject]@{ Name='PartialSvc';DisplayName='Partial';State='Running';StartMode='Manual';PathName='';ProcessId=0;TriggerHint=$false }
        }

        $result = Get-ScanServiceTaskInventory -AllowLimited

        $result.Services.Count | Should -Be 1
        $result.Services[0].Name | Should -BeExactly 'PartialSvc'
        $script:ScanHealth.services | Should -BeExactly 'degraded'
        @($script:ScanWarnings) -join "`n" | Should -Match '服务|services'
    }
    It '显式 limited 成功生成结果并把健康状态与警告传给报告和 pending' {
        Mock Get-SystemInfo { [pscustomobject]@{ Computer='PC' } }
        Mock Get-TopProcesses { @() }
        Mock Get-SuspiciousProcesses { @() }
        Mock Get-ServicesInfo { [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Running';StartMode='Auto';PathName='C:\svc.exe';ProcessId=1;TriggerHint=$false } }
        Mock Get-AutoStart { @() }
        Mock Match-Profiles { @() }
        Mock Get-AutoStartProcessNames { @() }
        Mock Write-ScanReport { 'limited report' }
        Mock Write-HtmlReport { 'limited html' }
        Mock Save-PendingActions {}

        $result = Invoke-ScanMode -AllowLimited

        $result | Should -BeExactly 'limited report'
        Assert-MockCalled Write-ScanReport -Times 1 -Exactly -ParameterFilter { $ScanHealth.tasks -ceq 'unavailable' -and @($ScanWarnings).Count -gt 0 }
        Assert-MockCalled Save-PendingActions -Times 1 -Exactly -ParameterFilter { $ScanHealth.tasks -ceq 'unavailable' -and @($ScanWarnings).Count -gt 0 }
    }
    It '入口参数拒绝 nonce 与 limited 组合 limited 非 scan 及非法 nonce' {
        $entry = Join-Path $projectRoot 'cpu-cleaner.ps1'
        $cases = @(
            @('-Mode','scan','-InventoryNonce',('a' * 64),'-AllowLimited'),
            @('-Mode','clean','-AllowLimited'),
            @('-Mode','scan','-InventoryNonce','not-a-valid-nonce')
        )
        foreach ($arguments in $cases) {
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry @arguments 2>&1
            $LASTEXITCODE | Should -Not -Be 0 -Because ($arguments -join ' ')
        }
    }
    It '入口 scan 仅调度编排函数并由编排函数保持只读阶段顺序' {
        $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $dispatchPattern = [regex]::Escape("'scan'") + '\s*\{\s*try\s*\{\s*\$null\s*=\s*Invoke-ScanMode\s+-InventoryNonce\s+\$InventoryNonce\s+-AllowLimited:\$AllowLimited\s+-ReportPath\s+\$ReportPath'
        $source | Should -Match $dispatchPattern
        [regex]::Matches($source, 'Get-ServicesInfo').Count | Should -Be 0
        [regex]::Matches($source, 'Get-TasksInfo').Count | Should -Be 0

        $scannerSource = Get-Content (Join-Path $projectRoot 'src\Core\Scanner.ps1') -Raw -Encoding UTF8
        $expected = @(
            @{ Marker='读取系统信息'; Operation='\$sys\s*=\s*Get-SystemInfo' },
            @{ Marker='检查高占用进程'; Operation='\$procs\s*=\s*Get-TopProcesses\s+12' },
            @{ Marker='检查系统服务与计划任务'; Operation='\$inventory\s*=\s*Get-ScanServiceTaskInventory' },
            @{ Marker='检查启动项'; Operation='\$autos\s*=\s*Get-AutoStart' },
            @{ Marker='匹配安全规则'; Operation='\$hits\s*=\s*Match-Profiles' },
            @{ Marker='生成扫描报告'; Operation='\$report\s*=\s*Write-ScanReport' }
        )
        $last = -1
        foreach ($phase in $expected) {
            [regex]::Matches($scannerSource, [regex]::Escape($phase.Marker)).Count | Should -Be 1
            $adjacent = "Write-Step\s+'{0}\.\.\.'(?:;|\r?\n)\s*{1}" -f [regex]::Escape($phase.Marker), $phase.Operation
            $scannerSource | Should -Match $adjacent
            $index = $scannerSource.IndexOf($phase.Marker, [System.StringComparison]::Ordinal)
            $index | Should -BeGreaterThan $last
            $last = $index
        }
    }
}
