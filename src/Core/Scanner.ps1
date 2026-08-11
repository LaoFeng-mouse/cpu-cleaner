# 系统采集 (v1.7.0 拆分): 概况/CPU 采样/服务/自启/任务/可疑进程
$script:ScanWarnings = [System.Collections.Generic.List[string]]::new()

function Add-ScanWarning {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    if ($null -eq $script:ScanWarnings) {
        $script:ScanWarnings = [System.Collections.Generic.List[string]]::new()
    }
    if (-not $script:ScanWarnings.Contains($Message)) { $script:ScanWarnings.Add($Message) }
}

# ---------- 1. 系统与 CPU 概况 ----------
function Get-SystemInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($null -eq $os -or $null -eq $cpu -or $null -eq $cs) { throw 'CIM 系统概况返回空结果。' }
        $boot = $os.LastBootUpTime
        $up = if ($boot) { (Get-Date) - $boot } else { $null }

        $load = '未知'
        try {
            $average = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -ne $average) { $load = [math]::Round($average, 1) }
        } catch {
            Add-ScanWarning 'CIM CPU 负载不可用，系统概况中的即时负载标记为未知。'
        }

        return [pscustomobject]@{
            Computer   = $cs.Name
            Model      = (($cs.Manufacturer, $cs.Model) -join ' ').Trim()
            CPU        = $cpu.Name
            Cores      = $cpu.NumberOfCores
            Threads    = $cpu.NumberOfLogicalProcessors
            RAM_GB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            CPU_Load   = $load
            BootTime   = if ($boot) { $boot.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
            Uptime     = if ($up) { '{0}天 {1}小时 {2}分' -f $up.Days, $up.Hours, $up.Minutes } else { 'N/A' }
        }
    } catch {
        Add-ScanWarning ('CIM 系统概况不可用，已使用兼容信息: ' + $_.Exception.Message)
        $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
        $processor = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
        $computer = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { [Environment]::MachineName }
        $model = (($bios.SystemManufacturer, $bios.SystemProductName) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($model)) { $model = '未知机型' }
        $cpuName = [string]$processor.ProcessorNameString
        if ([string]::IsNullOrWhiteSpace($cpuName)) { $cpuName = '未知 CPU' }
        $boot = $null
        $up = $null
        try {
            $up = [TimeSpan]::FromMilliseconds([Environment]::TickCount64)
            $boot = (Get-Date).Subtract($up)
        } catch {}
        $ram = '未知'
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            $ram = [math]::Round(([Microsoft.VisualBasic.Devices.ComputerInfo]::new().TotalPhysicalMemory / 1GB), 1)
        } catch {}

        return [pscustomobject]@{
            Computer   = $computer
            Model      = $model
            CPU        = $cpuName
            Cores      = '未知'
            Threads    = [Environment]::ProcessorCount
            RAM_GB     = $ram
            CPU_Load   = '未知'
            BootTime   = if ($boot) { $boot.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
            Uptime     = if ($up) { '{0}天 {1}小时 {2}分' -f $up.Days, $up.Hours, $up.Minutes } else { 'N/A' }
        }
    }
}

# ---------- 2. Top CPU 进程 (两次采样) ----------
# v1.5.7: 多次采样 Top 进程 — 平均 CPU / 峰值 / 持续占用 / 子进程数
# 旧版 2 秒单次采样只看瞬间; 现在默认 5 次 × 3 秒 ≈ 15 秒, 区分"瞬间吃一下"vs"持续后台发疯"
function Get-TopProcesses([int]$TopN = 12, [int]$Samples = 5, [int]$IntervalSec = 3) {
    $prev = @{}
    Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }
    $acc = @{}
    for ($i = 0; $i -lt $Samples; $i++) {
        Start-Sleep -Seconds $IntervalSec
        Get-Process | ForEach-Object {
            $id = $_.Id
            if ($prev.ContainsKey($id)) {
                $delta = $_.CPU - $prev[$id]
                if ($delta -lt 0) { $delta = 0 }
                $cpuPct = [math]::Round($delta / $IntervalSec * 100 / [Environment]::ProcessorCount, 2)
                if (-not $acc.ContainsKey($id)) { $acc[$id] = @{ sum=0; peak=0; high=0; name=$_.ProcessName; path=$_.Path; mem=0 } }
                $e = $acc[$id]
                $e.sum += $cpuPct
                if ($cpuPct -gt $e.peak) { $e.peak = $cpuPct }
                if ($cpuPct -ge 5) { $e.high++ }
                $e.mem = $_.WorkingSet64
            }
            $prev[$id] = $_.CPU
        }
    }
    # 子进程数: 一次 CIM 查询构建 parent→children 映射 (普通权限可见范围内)
    $children = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $ppid = [int]$_.ParentProcessId
            if ($ppid -gt 0) {
                if ($children.ContainsKey($ppid)) { $children[$ppid]++ } else { $children[$ppid] = 1 }
            }
        }
    } catch {}
    $result = @()
    foreach ($id in $acc.Keys) {
        $e = $acc[$id]
        $result += [pscustomobject]@{
            PID         = $id
            Name        = $e.name
            'CPU%'      = [math]::Round($e.sum / $Samples, 2)   # 平均 CPU (兼容旧字段)
            CPUPeak     = $e.peak                               # 峰值 CPU
            SamplesHigh = $e.high                               # 持续占用: 采样中 CPU≥5% 的次数
            Samples     = $Samples
            ChildCount  = if ($children.ContainsKey($id)) { $children[$id] } else { 0 }
            MemMB       = [math]::Round($e.mem / 1MB, 0)
            Path        = $e.path
        }
    }
    return ($result | Sort-Object 'CPU%' -Descending | Select-Object -First $TopN)
}

# ---------- 3. 未知高占用进程检测 (B3) ----------
function Get-SuspiciousProcesses($TopProcs) {
    $sysNames = @('System','System Idle Process','svchost','dwm','lsass','services','winlogon','csrss','conhost','explorer','fontdrvhost','registry','smss','wininit','Memory Compression','MsMpEng','audiodg','SearchIndexer','WmiPrvSE','spoolsv','taskhostw','ShellExperienceHost','RuntimeBroker','sihost','dllhost','ctfmon','schedsvc','winlogon','SecurityHealthSystray','powershell','cmd')
    $susp = @()
    foreach ($p in $TopProcs) {
        if ($p.'CPU%' -lt 3) { continue }              # 只查高占用
        if ($sysNames -contains $p.Name) { continue }  # 排除系统进程
        $path = $p.Path
        $reason = ''
        if (-not $path) {
            $reason = '无路径(可能是服务进程或已退出)'
        } elseif ($path -match '\\Temp\\|\\AppData\\Roaming\\|\\AppData\\Local\\Temp\\|\\Downloads\\') {
            $reason = '路径可疑: ' + $path
        } else {
            try {
                $sig = Get-AuthenticodeSignature $path -ErrorAction Stop
                if ($sig.Status -ne 'Valid') { $reason = '无有效数字签名: ' + $path }
            } catch { $reason = '签名检查失败: ' + $path }
        }
        if ($reason) {
            $susp += [pscustomobject]@{
                PID = $p.PID
                Name = $p.Name
                'CPU%' = $p.'CPU%'
                MemMB = $p.MemMB
                Path = $path
                Reason = $reason
            }
        }
    }
    return $susp
}

# ---------- 4. 服务列表 ----------
function Get-ServicesInfo {
    $svcs = @()
    try {
        $svcs = @(Get-CimInstance Win32_Service -ErrorAction Stop | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId)
        if ($svcs.Count -eq 0) { throw 'CIM 服务列表为空。' }
    } catch {
        $cimMessage = $_.Exception.Message
        Add-ScanWarning ('CIM 服务信息不可用，已使用 Get-Service 兼容采集: ' + $cimMessage)
        try {
            $svcs = @(Get-Service -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.Name
                    DisplayName = $_.DisplayName
                    State       = [string]$_.Status
                    StartMode   = [string]$_.StartType
                    PathName    = ''
                    ProcessId   = 0
                }
            })
            if ($svcs.Count -eq 0) { throw 'Get-Service 返回空列表。' }
        } catch {
            throw ('无法读取系统服务；CIM 失败: {0}; Get-Service 失败: {1}' -f $cimMessage, $_.Exception.Message)
        }
    }
    # 触发器提示: Manual 却 Running = 可能被其他组件拉起 (B5)
    # 只对第三方服务标注 (系统服务太常见, 列出来是噪音)
    return @($svcs | ForEach-Object {
        # PathName 缺失时无法可靠区分系统/第三方服务，保持 fail-closed，不给触发器提示。
        $isThirdParty = -not [string]::IsNullOrWhiteSpace([string]$_.PathName)
        if ($_.PathName -match 'C:\\Windows\\' -or $_.DisplayName -match 'Microsoft|Windows') { $isThirdParty = $false }
        $triggerHint = $false
        if ($_.StartMode -eq 'Manual' -and $_.State -eq 'Running' -and $isThirdParty) { $triggerHint = $true }
        [pscustomobject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            State       = $_.State
            StartMode   = $_.StartMode
            PathName    = $_.PathName
            ProcessId   = $_.ProcessId
            TriggerHint = $triggerHint
        }
    })
}

# ---------- 5. 自启动项 ----------
function Get-AutoStart {
    $items = @()
    $runPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($rp in $runPaths) {
        $key = Get-ItemProperty $rp -ErrorAction SilentlyContinue
        if ($key) {
            $key.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $items += [pscustomobject]@{ Source = $rp; Name = $_.Name; Value = $_.Value }
            }
        }
    }
    $startupDirs = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($sd in $startupDirs) {
        if (Test-Path $sd) {
            Get-ChildItem $sd -File | ForEach-Object {
                $items += [pscustomobject]@{ Source = 'StartupFolder'; Name = $_.Name; Value = $_.FullName }
            }
        }
    }
    return $items
}

# ---------- 6. 计划任务 ----------
function Invoke-SchtasksQueryCsv {
    $schtasksPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $raw = @(& $schtasksPath /Query /FO CSV /V 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (@($raw) | ForEach-Object { [string]$_ }) -join ' '
        throw "schtasks /Query 失败 (ExitCode=$exitCode): $detail"
    }
    $rows = @($raw | ConvertFrom-Csv)
    return @($rows | ForEach-Object {
        $values = @($_.PSObject.Properties | ForEach-Object { $_.Value })
        if ($values.Count -lt 19) { throw 'schtasks CSV 字段不足，无法安全解析。' }
        [pscustomobject]@{
            FullTaskName  = [string]$values[1]
            Status        = [string]$values[3]
            ScheduledState = [string]$values[11]
            ScheduleType  = [string]$values[18]
        }
    })
}

function Get-TasksInfo {
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $login = $false
            foreach ($t in $_.Triggers) {
                if ($t.CimClass.CimClassName -match 'Logon|Boot') { $login = $true }
            }
            [pscustomobject]@{
                TaskPath = $_.TaskPath
                TaskName = $_.TaskName
                State    = $_.State
                LoginTrigger = $login
            }
        })
    } catch {
        $primaryMessage = $_.Exception.Message
        Add-ScanWarning ('Get-ScheduledTask 不可用，已使用 schtasks 兼容采集: ' + $primaryMessage)
        try {
            $tasks = @(Invoke-SchtasksQueryCsv | ForEach-Object {
                $fullName = [string]$_.FullTaskName
                if ([string]::IsNullOrWhiteSpace($fullName)) { return }
                if (-not $fullName.StartsWith('\', [System.StringComparison]::Ordinal)) { $fullName = '\' + $fullName }
                $separator = $fullName.LastIndexOf('\')
                if ($separator -lt 0 -or $separator -eq ($fullName.Length - 1)) { return }
                $taskPath = if ($separator -eq 0) { '\' } else { $fullName.Substring(0, $separator + 1) }
                $taskName = $fullName.Substring($separator + 1)
                $scheduleType = [string]$_.ScheduleType
                [pscustomobject]@{
                    TaskPath     = $taskPath
                    TaskName     = $taskName
                    State        = if (-not [string]::IsNullOrWhiteSpace([string]$_.ScheduledState)) { [string]$_.ScheduledState } else { [string]$_.Status }
                    LoginTrigger = ($scheduleType -match '(?i)logon|system start|登录|系统启动|开机|用户登录')
                }
            })
        } catch {
            throw ('无法读取计划任务；Get-ScheduledTask 失败: {0}; schtasks 失败: {1}' -f $primaryMessage, $_.Exception.Message)
        }
    }
    return $tasks
}

