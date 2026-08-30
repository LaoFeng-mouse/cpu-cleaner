# 系统采集 (v1.7.0 拆分): 概况/CPU 采样/服务/自启/任务/可疑进程
function Reset-ScanDiagnostics {
    $script:ScanWarnings = [System.Collections.Generic.List[string]]::new()
    $script:ScanHealth = [ordered]@{
        system_info = 'complete'
        services    = 'complete'
        tasks       = 'complete'
    }
}

function Set-ScanHealthDegraded {
    param([Parameter(Mandatory=$true)][ValidateSet('system_info','services','tasks')][string]$Category)
    if ($null -eq $script:ScanHealth) { Reset-ScanDiagnostics }
    $script:ScanHealth[$Category] = 'degraded'
}

function Test-ScanHealthDegraded {
    param($ScanHealth = $script:ScanHealth)
    if ($null -eq $ScanHealth) { return $false }
    return (@('system_info','services','tasks') | Where-Object { [string]$ScanHealth.$_ -ne 'complete' }).Count -gt 0
}

Reset-ScanDiagnostics

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

        $model = (($cs.Manufacturer, $cs.Model) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace([string]$cs.Name) -or
            [string]::IsNullOrWhiteSpace($model) -or
            [string]::IsNullOrWhiteSpace([string]$cpu.Name) -or
            [int64]$cpu.NumberOfCores -le 0 -or
            [int64]$cpu.NumberOfLogicalProcessors -le 0 -or
            [double]$cs.TotalPhysicalMemory -le 0) {
            throw 'CIM 系统概况缺少关键字段。'
        }

        $load = '未知'
        try {
            $loadSamples = @(Get-CimInstance Win32_Processor -ErrorAction Stop | Where-Object { $null -ne $_.LoadPercentage })
            if ($loadSamples.Count -eq 0) { throw 'CIM CPU 负载返回空值。' }
            $average = ($loadSamples | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -eq $average) { throw 'CIM CPU 负载无法计算。' }
            $load = [math]::Round($average, 1)
        } catch {
            Add-ScanWarning 'CIM CPU 负载不可用，系统概况中的即时负载标记为未知。'
            Set-ScanHealthDegraded system_info
        }

        return [pscustomobject]@{
            Computer   = $cs.Name
            Model      = $model
            CPU        = $cpu.Name
            Cores      = $cpu.NumberOfCores
            Threads    = $cpu.NumberOfLogicalProcessors
            RAM_GB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            CPU_Load   = $load
            BootTime   = if ($boot) { $boot.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
            Uptime     = if ($up) { '{0}天 {1}小时 {2}分' -f $up.Days, $up.Hours, $up.Minutes } else { 'N/A' }
        }
    } catch {
        Set-ScanHealthDegraded system_info
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
                if (-not $acc.ContainsKey($id)) {
                    $startTimeUtc = ''
                    try { $startTimeUtc = $_.StartTime.ToUniversalTime().ToString('o') } catch {}
                    $acc[$id] = @{ sum=0; peak=0; high=0; name=$_.ProcessName; path=$_.Path; startTimeUtc=$startTimeUtc; mem=0 }
                }
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
            StartTimeUtc = $e.startTimeUtc
        }
    }
    return ($result | Sort-Object 'CPU%' -Descending | Select-Object -First $TopN)
}

# ---------- 3. 未知高占用进程检测 (B3) ----------
function Get-SuspiciousProcesses($TopProcs, $ProfileHits = @()) {
    $sysNames = @('System','System Idle Process','svchost','dwm','lsass','services','winlogon','csrss','conhost','explorer','fontdrvhost','registry','smss','wininit','Memory Compression','MsMpEng','audiodg','SearchIndexer','WmiPrvSE','spoolsv','taskhostw','ShellExperienceHost','RuntimeBroker','sihost','dllhost','ctfmon','schedsvc','winlogon','SecurityHealthSystray','powershell','cmd')
    $susp = @()
    foreach ($p in $TopProcs) {
        $averageCpu = if ($p.'CPU%' -is [ValueType]) { [double]$p.'CPU%' } else { 0.0 }
        $peakCpu = if ($p.PSObject.Properties.Name -contains 'CPUPeak' -and $p.CPUPeak -is [ValueType]) { [double]$p.CPUPeak } else { $averageCpu }
        $samples = if ($p.PSObject.Properties.Name -contains 'Samples' -and $p.Samples -is [ValueType]) { [int]$p.Samples } else { 0 }
        $samplesHigh = if ($p.PSObject.Properties.Name -contains 'SamplesHigh' -and $p.SamplesHigh -is [ValueType]) { [int]$p.SamplesHigh } else { 0 }
        $sustained = $samples -ge 3 -and $samplesHigh -ge [math]::Ceiling($samples / 2.0)
        if ($averageCpu -lt 3 -and $peakCpu -lt 5 -and -not $sustained) { continue }

        $path = [string]$p.Path
        $pathLooksSuspicious = -not [string]::IsNullOrWhiteSpace($path) -and $path -match '\\Temp\\|\\AppData\\Roaming\\|\\AppData\\Local\\Temp\\|\\Downloads\\'
        $signatureStatus = 'Unknown'
        $signerSubject = ''
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try {
                $sig = Get-AuthenticodeSignature $path -ErrorAction Stop
                $signatureStatus = [string]$sig.Status
                if ($sig.PSObject.Properties.Name -contains 'SignerCertificate' -and $null -ne $sig.SignerCertificate) {
                    $signerSubject = [string]$sig.SignerCertificate.Subject
                }
            } catch { $signatureStatus = 'CheckFailed' }
        }

        # 仅保护可信位置/微软签名的系统进程；可疑目录中的同名程序不能借名称逃过扫描。
        if ($sysNames -contains $p.Name) {
            $underWindows = -not [string]::IsNullOrWhiteSpace($path) -and
                $path.StartsWith(([Environment]::GetFolderPath('Windows') + '\\'), [System.StringComparison]::OrdinalIgnoreCase)
            $microsoftSigned = $signatureStatus -eq 'Valid' -and $signerSubject -match 'Microsoft'
            if ([string]::IsNullOrWhiteSpace($path) -or $underWindows -or ($microsoftSigned -and -not $pathLooksSuspicious)) { continue }
        }

        $matchedProfile = @($ProfileHits | Where-Object {
            $_.hit_type -eq 'process' -and (
                (($_.process_id -is [ValueType]) -and [int64]$_.process_id -eq [int64]$p.PID) -or
                (-not [string]::IsNullOrWhiteSpace([string]$_.process_name) -and [string]$_.process_name -ieq [string]$p.Name)
            )
        } | Select-Object -First 1)
        $reasonParts = @('高 CPU: 平均 {0}% / 峰值 {1}% / 持续 {2}/{3}' -f $averageCpu, $peakCpu, $samplesHigh, $samples)
        if ($matchedProfile.Count -gt 0) {
            $profileName = [string]$matchedProfile[0].name_cn
            $profileReason = [string]$matchedProfile[0].reason_cn
            if (-not [string]::IsNullOrWhiteSpace($profileName)) { $reasonParts += ('命中规则: ' + $profileName) }
            if (-not [string]::IsNullOrWhiteSpace($profileReason)) { $reasonParts += $profileReason }
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $reasonParts += '无路径(可能是服务进程或已退出)'
        } elseif ($pathLooksSuspicious) {
            $reasonParts += ('路径可疑: ' + $path)
        } elseif ($signatureStatus -ne 'Valid') {
            $reasonParts += ('无有效数字签名: ' + $path)
        } else {
            $reasonParts += '有效签名的第三方进程；是否结束取决于你是否正在使用对应功能'
        }

        $completeIdentity = [int64]$p.PID -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$p.Name) -and
            -not [string]::IsNullOrWhiteSpace($path) -and
            [System.IO.Path]::IsPathRooted($path) -and
            -not [string]::IsNullOrWhiteSpace([string]$p.StartTimeUtc)
        $susp += [pscustomobject]@{
            PID = $p.PID
            Name = $p.Name
            'CPU%' = $averageCpu
            CPUPeak = $peakCpu
            SamplesHigh = $samplesHigh
            Samples = $samples
            MemMB = $p.MemMB
            Path = $path
            Necessity = '按需结束'
            Reason = ($reasonParts -join '；')
            Impact = '只结束当前进程实例；正在使用的功能可能中断，未保存的数据可能丢失，后台也可能自动重启。'
            StartTimeUtc = [string]$p.StartTimeUtc
            CanStop = [bool]$completeIdentity
            StopBlockReason = if ($completeIdentity) { '' } else { '进程身份不完整，不能安全停止' }
        }
    }
    return $susp
}

# ---------- 4. 服务列表 ----------
function ConvertTo-ServiceProcessStartTimeUtc {
    param($Value)

    try {
        $utc = $null
        if ($Value -is [datetimeoffset]) {
            $utc = $Value.ToUniversalTime()
        } elseif ($Value -is [datetime]) {
            if ($Value.Kind -eq [DateTimeKind]::Utc) {
                $utc = [datetimeoffset]::new($Value)
            } elseif ($Value.Kind -eq [DateTimeKind]::Local) {
                $utc = [datetimeoffset]::new($Value.ToUniversalTime())
            } else {
                return $null
            }
        } else {
            return $null
        }
        if ($utc.Year -lt 1970) { return $null }
        return $utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function Set-ServiceProcessIdentityFailureReason {
    param([ref]$FailureReason, [string]$Reason)
    if ($null -ne $FailureReason) { $FailureReason.Value = '服务进程身份无法安全确认，请重新扫描后再试。' }
}

function Get-StrictServiceProcessId {
    param($Value)

    if ($null -eq $Value) { return $null }
    $allowedTypes = @(
        'System.Byte','System.SByte','System.Int16','System.UInt16',
        'System.Int32','System.UInt32','System.Int64','System.UInt64'
    )
    if ($allowedTypes -cnotcontains $Value.GetType().FullName) { return $null }
    try {
        $numeric = [uint64]$Value
        if ($numeric -eq 0 -or $numeric -gt [int]::MaxValue) { return $null }
        return [int]$numeric
    } catch {
        return $null
    }
}

function Get-CurrentServiceExecutionSnapshot {
    param([Parameter(Mandatory=$true)][string]$ServiceName, [ref]$FailureReason)

    $escapedName = $ServiceName.Replace('\', '\\').Replace("'", "\'")
    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -Filter ("Name = '{0}'" -f $escapedName) -ErrorAction Stop)
    } catch {
        Set-ServiceProcessIdentityFailureReason $FailureReason ('无法读取当前服务身份: ' + $_.Exception.Message)
        return $null
    }
    if ($services.Count -ne 1 -or $null -eq $services[0]) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务身份缺失或不唯一，无法建立稳定快照。'
        return $null
    }
    $service = $services[0]
    if ($service.Name -isnot [string] -or $service.Name -cne $ServiceName) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务名称与精确命中名称不一致。'
        return $null
    }
    if ($service.State -isnot [string] -or $service.State -cne 'Running') {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务状态不是 Running，无法建立进程身份。'
        return $null
    }
    $processId = Get-StrictServiceProcessId $service.ProcessId
    if ($null -eq $processId) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务没有严格有效的正整数 PID。'
        return $null
    }
    if ($service.PathName -isnot [string] -or [string]::IsNullOrWhiteSpace($service.PathName)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务 PathName 缺失。'
        return $null
    }
    $binaryPath = Get-ServiceBinaryPathFromPathName $service.PathName
    if ([string]::IsNullOrWhiteSpace([string]$binaryPath) -or -not (Test-InventoryFullyQualifiedWindowsPath $binaryPath)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务二进制路径缺失、含糊或不是绝对路径。'
        return $null
    }
    try { $binaryPath = [System.IO.Path]::GetFullPath([string]$binaryPath) }
    catch {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务二进制路径无法规范化。'
        return $null
    }
    if (-not [System.IO.File]::Exists($binaryPath)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '当前服务二进制路径不存在。'
        return $null
    }
    return [pscustomobject]@{
        Name = $service.Name
        State = $service.State
        ProcessId = $processId
        PathName = $service.PathName
        BinaryPath = $binaryPath
    }
}

function Get-ServiceProcessExecutionIdentity {
    param($Service, [ref]$FailureReason)

    if ($null -ne $FailureReason) { $FailureReason.Value = '' }
    if ($null -eq $Service -or $Service.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Service.Name)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '扫描服务名称缺失，无法回读当前服务。'
        return $null
    }
    if ($Service.ProcessIdentitySource -isnot [string] -or $Service.ProcessIdentitySource -cne 'trusted_inventory_v3' -or
        $Service.ProcessIdentityStatus -isnot [string] -or $Service.ProcessIdentityStatus -cne 'complete') {
        Set-ServiceProcessIdentityFailureReason $FailureReason '扫描服务没有可信且完整的进程身份。'
        return $null
    }
    $first = Get-CurrentServiceExecutionSnapshot -ServiceName $Service.Name -FailureReason $FailureReason
    if ($null -eq $first) { return $null }

    $originalProcessId = Get-StrictServiceProcessId $Service.ProcessId
    if ($Service.Name -isnot [string] -or $Service.Name -cne $first.Name -or
        $Service.State -isnot [string] -or $Service.State -cne 'Running' -or
        $first.State -isnot [string] -or $first.State -cne 'Running' -or
        $null -eq $originalProcessId -or $originalProcessId -ne $first.ProcessId -or
        $Service.PathName -isnot [string] -or $Service.PathName -cne $first.PathName) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '扫描服务与首次当前服务快照的名称、状态、PID 或 PathName 不一致。'
        return $null
    }
    $originalBinaryPath = Get-ServiceBinaryPathFromPathName $Service.PathName
    try { $originalBinaryPath = [System.IO.Path]::GetFullPath([string]$originalBinaryPath) }
    catch {
        Set-ServiceProcessIdentityFailureReason $FailureReason '扫描服务二进制路径无法规范化。'
        return $null
    }
    if (-not [string]::Equals($originalBinaryPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '扫描服务与首次当前服务快照的二进制路径不一致。'
        return $null
    }

    $processName = [string]$Service.ProcessName
    $expectedName = [System.IO.Path]::GetFileName($first.BinaryPath)
    if ($Service.ProcessName -isnot [string] -or [string]::IsNullOrWhiteSpace($processName) -or
        $processName -cne $processName.Trim() -or
        [System.IO.Path]::GetFileName($processName) -cne $processName -or
        -not [string]::Equals($processName, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '进程名称与服务二进制名称不一致，无法安全结束。'
        return $null
    }

    $processPath = [string]$Service.ProcessPath
    if ($Service.ProcessPath -isnot [string] -or [string]::IsNullOrWhiteSpace($processPath) -or
        -not (Test-InventoryFullyQualifiedWindowsPath $processPath)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '进程路径缺失或不是绝对路径，无法安全结束。'
        return $null
    }
    try { $processPath = [System.IO.Path]::GetFullPath($processPath) }
    catch {
        Set-ServiceProcessIdentityFailureReason $FailureReason '进程路径无效，无法建立执行身份。'
        return $null
    }
    if (-not [System.IO.File]::Exists($processPath) -or
        -not [string]::Equals($processPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '进程路径与服务二进制路径不一致，无法安全结束。'
        return $null
    }

    $startTimeUtc = [string]$Service.ProcessStartTimeUtc
    $parsedStartTimeUtc = ConvertFrom-InventoryCanonicalUtc $Service.ProcessStartTimeUtc
    if ($null -eq $parsedStartTimeUtc) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '进程 UTC 启动时间缺失、时区不明确或格式无效，无法安全结束。'
        return $null
    }

    $second = Get-CurrentServiceExecutionSnapshot -ServiceName $first.Name -FailureReason $FailureReason
    if ($null -eq $second) { return $null }
    if ($second.Name -cne $first.Name -or $second.State -cne 'Running' -or
        $second.ProcessId -ne $first.ProcessId -or $second.PathName -cne $first.PathName -or
        -not [string]::Equals($second.BinaryPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-ServiceProcessIdentityFailureReason $FailureReason '服务在进程读取前后发生名称、状态、PID、PathName 或二进制路径漂移。'
        return $null
    }

    return [pscustomobject]@{
        service_binary_path = $first.BinaryPath
        process_id = $first.ProcessId
        process_name = $processName
        process_path = $processPath
        process_start_time_utc = $startTimeUtc
    }
}

function Test-ServiceTriggerHint {
    param([Parameter(Mandatory=$true)]$Service)

    # PathName 缺失时无法可靠区分系统/第三方服务，保持 fail-closed，不给触发器提示。
    $isThirdParty = -not [string]::IsNullOrWhiteSpace([string]$Service.PathName)
    if ($Service.PathName -match 'C:\\Windows\\' -or $Service.DisplayName -match 'Microsoft|Windows') { $isThirdParty = $false }
    return ($Service.StartMode -eq 'Manual' -and $Service.State -eq 'Running' -and $isThirdParty)
}

function Get-ServicesInfo {
    $svcs = @()
    try {
        $svcs = @(Get-CimInstance Win32_Service -ErrorAction Stop | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId)
        if ($svcs.Count -eq 0) { throw 'CIM 服务列表为空。' }
        $invalidCimServices = @($svcs | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.Name) -or
            [string]::IsNullOrWhiteSpace([string]$_.DisplayName) -or
            [string]::IsNullOrWhiteSpace([string]$_.State) -or
            [string]::IsNullOrWhiteSpace([string]$_.StartMode) -or
            [string]::IsNullOrWhiteSpace([string]$_.PathName)
        })
        if ($invalidCimServices.Count -gt 0) {
            throw 'CIM 服务列表包含不完整的服务身份或状态。'
        }
    } catch {
        $cimMessage = $_.Exception.Message
        Set-ScanHealthDegraded services
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
            $invalidFallbackServices = @($svcs | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.Name) -or
                [string]::IsNullOrWhiteSpace([string]$_.DisplayName) -or
                [string]::IsNullOrWhiteSpace([string]$_.State) -or
                [string]::IsNullOrWhiteSpace([string]$_.StartMode) -or
                [string]$_.StartMode -notin @('Automatic','Manual','Disabled','Boot','System')
            })
            if ($invalidFallbackServices.Count -gt 0) {
                throw 'Get-Service 返回不完整的服务身份或状态。'
            }
        } catch {
            Set-ScanHealthDegraded services
            throw ('无法读取系统服务；CIM 失败: {0}; Get-Service 失败: {1}' -f $cimMessage, $_.Exception.Message)
        }
    }
    # 触发器提示: Manual 却 Running = 可能被其他组件拉起 (B5)
    # 只对第三方服务标注 (系统服务太常见, 列出来是噪音)
    return @($svcs | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            State       = $_.State
            StartMode   = $_.StartMode
            PathName    = $_.PathName
            ProcessId   = $_.ProcessId
            TriggerHint = Test-ServiceTriggerHint $_
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
function ConvertTo-ScheduledTaskActionString {
    param([Parameter(Mandatory=$true)]$Action)
    if ($Action -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Action)) { throw '计划任务动作不能为空。' }
        return [string]$Action
    }
    if ($null -eq $Action) { throw '计划任务动作不能为空。' }
    $propertyNames = @($Action.PSObject.Properties.Name)
    if ($propertyNames -ccontains 'Execute') {
        if ([string]::IsNullOrWhiteSpace([string]$Action.Execute)) { throw '计划任务执行动作缺少可执行文件。' }
        if ($propertyNames -cnotcontains 'Arguments') { throw '计划任务执行动作缺少 Arguments 字段。' }
        $arguments = [string]$Action.Arguments
        if ([string]::IsNullOrWhiteSpace($arguments)) { return [string]$Action.Execute }
        return ('{0} {1}' -f $Action.Execute, $arguments)
    }

    $stable = [ordered]@{}
    foreach ($property in @($Action.PSObject.Properties | Sort-Object Name)) {
        if ($property.Name -in @('CimClass','CimInstanceProperties','CimSystemProperties','PSComputerName','RunspaceId')) { continue }
        if ($null -eq $property.Value -or $property.Value -is [string] -or $property.Value -is [ValueType]) {
            $stable[$property.Name] = $property.Value
        }
    }
    if ($stable.Count -eq 0) { throw '计划任务动作无法生成稳定表示。' }
    return (ConvertTo-Json -InputObject $stable -Compress -Depth 4)
}

function Invoke-TaskSchedulerComQuery {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $rootPath = [string][char]92
    $stack = [System.Collections.Stack]::new()
    $stack.Push($scheduler.GetFolder($rootPath))
    $records = @()
    while ($stack.Count -gt 0) {
        $folder = $stack.Pop()
        foreach ($task in @($folder.GetTasks(1))) {
            $triggerTypes = @($task.Definition.Triggers | ForEach-Object { [int]$_.Type })
            $definition = $task.Definition
            if ($null -eq $definition -or $null -eq $definition.RegistrationInfo -or $null -eq $definition.Actions) {
                throw ('Task Scheduler COM 任务定义不完整: ' + [string]$task.Path)
            }
            $registration = $definition.RegistrationInfo
            $registrationProperties = @($registration.PSObject.Properties.Name)
            if ($registrationProperties -cnotcontains 'Author' -or $registrationProperties -cnotcontains 'Description') {
                throw ('Task Scheduler COM 注册信息缺少 Author 或 Description: ' + [string]$task.Path)
            }
            $actions = @($definition.Actions | ForEach-Object { ConvertTo-ScheduledTaskActionString $_ })
            $records += [pscustomobject]@{
                Path         = [string]$task.Path
                State        = [int]$task.State
                TriggerTypes = $triggerTypes
                Author       = [string]$registration.Author
                Description  = [string]$registration.Description
                Actions      = [object[]]$actions
            }
        }
        foreach ($child in @($folder.GetFolders(0))) { $stack.Push($child) }
    }
    if ($records.Count -eq 0) { throw 'Task Scheduler COM 返回空任务列表。' }
    return $records
}

function Convert-TaskSchedulerComRecord {
    param([Parameter(Mandatory=$true)]$Record)
    $propertyNames = @($Record.PSObject.Properties.Name)
    $missingFields = @('Path','State','TriggerTypes','Author','Description','Actions' | Where-Object { $_ -notin $propertyNames })
    if ($missingFields.Count -gt 0) {
        throw ('Task Scheduler COM 记录缺少字段: {0}' -f ($missingFields -join ', '))
    }
    $fullName = [string]$Record.Path
    if ([string]::IsNullOrWhiteSpace($fullName) -or
        -not $fullName.StartsWith('\', [System.StringComparison]::Ordinal)) {
        throw 'Task Scheduler COM 返回无效任务路径。'
    }
    $separator = $fullName.LastIndexOf('\')
    if ($separator -lt 0 -or $separator -eq ($fullName.Length - 1)) {
        throw ('Task Scheduler COM 返回无效任务身份: {0}' -f $fullName)
    }
    if (@($Record.State).Count -ne 1) { throw 'Task Scheduler COM 返回无效状态字段。' }
    $stateValue = 0
    if (-not [int]::TryParse([string]$Record.State, [ref]$stateValue)) { throw 'Task Scheduler COM 返回非整数状态。' }
    if ($stateValue -lt 0 -or $stateValue -gt 4) { throw ('Task Scheduler COM 返回无效状态: {0}' -f $stateValue) }
    $stateNames = @('Unknown','Disabled','Queued','Ready','Running')
    $triggerTypes = @()
    $validTriggerTypes = @(0,1,2,3,4,5,6,7,8,9,11,12)
    foreach ($rawTriggerType in @($Record.PSObject.Properties['TriggerTypes'].Value)) {
        $triggerType = 0
        if (-not [int]::TryParse([string]$rawTriggerType, [ref]$triggerType) -or $triggerType -notin $validTriggerTypes) {
            throw ('Task Scheduler COM 返回无效触发器类型: {0}' -f $rawTriggerType)
        }
        $triggerTypes += $triggerType
    }
    if ($Record.Author -isnot [string]) { throw 'Task Scheduler COM 返回无效 Author 字段。' }
    if ($Record.Description -isnot [string]) { throw 'Task Scheduler COM 返回无效 Description 字段。' }
    if ($Record.Actions -isnot [System.Array]) { throw 'Task Scheduler COM 返回无效 Actions 字段。' }
    $actions = @($Record.Actions | ForEach-Object { ConvertTo-ScheduledTaskActionString $_ })
    return [pscustomobject]@{
        TaskPath     = if ($separator -eq 0) { '\' } else { $fullName.Substring(0, $separator + 1) }
        TaskName     = $fullName.Substring($separator + 1)
        State        = $stateNames[$stateValue]
        LoginTrigger = (@($triggerTypes | Where-Object { $_ -in @(8, 9) }).Count -gt 0)
        Author       = [string]$Record.Author
        Description  = [string]$Record.Description
        Actions      = [object[]]$actions
    }
}

function Get-TasksInfo {
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $propertyNames = @($_.PSObject.Properties.Name)
            $missingFields = @('TaskName','TaskPath','State','Author','Description','Actions','Triggers' | Where-Object { $_ -notin $propertyNames })
            if ($missingFields.Count -gt 0) {
                throw ('Get-ScheduledTask 记录缺少字段: {0}' -f ($missingFields -join ', '))
            }
            if ([string]::IsNullOrWhiteSpace([string]$_.TaskName) -or
                [string]::IsNullOrWhiteSpace([string]$_.TaskPath) -or
                -not ([string]$_.TaskPath).StartsWith('\', [System.StringComparison]::Ordinal) -or
                $_.State -is [System.Array] -or [string]::IsNullOrWhiteSpace([string]$_.State) -or
                $_.Author -isnot [string] -or $_.Description -isnot [string] -or
                $null -eq $_.Actions) {
                throw 'Get-ScheduledTask 返回无效任务身份。'
            }
            $login = $false
            foreach ($t in $_.Triggers) {
                if ($t.CimClass.CimClassName -match 'Logon|Boot') { $login = $true }
            }
            [pscustomobject]@{
                TaskPath = $_.TaskPath
                TaskName = $_.TaskName
                State    = [string]$_.State
                LoginTrigger = $login
                Author = [string]$_.Author
                Description = [string]$_.Description
                Actions = [object[]]@($_.Actions | ForEach-Object { ConvertTo-ScheduledTaskActionString $_ })
            }
        })
        if ($tasks.Count -eq 0) { throw 'Get-ScheduledTask 返回空任务列表。' }
    } catch {
        $primaryMessage = $_.Exception.Message
        Set-ScanHealthDegraded tasks
        Add-ScanWarning ('Get-ScheduledTask 不可用，已使用 Task Scheduler COM 兼容采集: ' + $primaryMessage)
        try {
            $records = @(Invoke-TaskSchedulerComQuery)
            if ($records.Count -eq 0) { throw 'Task Scheduler COM 返回空任务列表。' }
            $tasks = @($records | ForEach-Object { Convert-TaskSchedulerComRecord $_ })
            if ($tasks.Count -ne $records.Count) { throw 'Task Scheduler COM 任务转换数量不一致。' }
            $script:ScanHealth['tasks'] = 'complete'
        } catch {
            throw ('无法读取计划任务；Get-ScheduledTask 失败: {0}; Task Scheduler COM 失败: {1}' -f $primaryMessage, $_.Exception.Message)
        }
    }
    return $tasks
}

function Get-ScanServiceTaskInventory {
    param(
        [string]$InventoryNonce = '',
        [switch]$AllowLimited
    )

    if ($AllowLimited -and -not [string]::IsNullOrEmpty($InventoryNonce)) {
        throw 'InventoryNonce and AllowLimited are mutually exclusive.'
    }

    if (-not [string]::IsNullOrEmpty($InventoryNonce)) {
        if (-not (Test-InventoryNonce $InventoryNonce)) { throw 'Invalid inventory nonce.' }
        $trusted = Read-TrustedInventoryPackage -Nonce $InventoryNonce
        foreach ($warning in @($trusted.Package.warnings)) { Add-ScanWarning ([string]$warning) }
        $script:ScanHealth['services'] = 'complete'
        $script:ScanHealth['tasks'] = 'complete'
        $trustedServices = @($trusted.Package.services | ForEach-Object {
            [pscustomobject]@{
                Name        = $_.Name
                DisplayName = $_.DisplayName
                State       = $_.State
                StartMode   = $_.StartMode
                PathName    = $_.PathName
                ProcessId   = $_.ProcessId
                ProcessIdentityStatus = $_.ProcessIdentityStatus
                ProcessName = $_.ProcessName
                ProcessPath = $_.ProcessPath
                ProcessStartTimeUtc = $_.ProcessStartTimeUtc
                LaunchProtectedStatus = $_.LaunchProtectedStatus
                LaunchProtectedLevel = $_.LaunchProtectedLevel
                UninstallEvidenceStatus = $_.UninstallEvidenceStatus
                UninstallRegistryPath = $_.UninstallRegistryPath
                UninstallDisplayName = $_.UninstallDisplayName
                UninstallPublisher = $_.UninstallPublisher
                UninstallDisplayVersion = $_.UninstallDisplayVersion
                UninstallInstallLocation = $_.UninstallInstallLocation
                UninstallString = $_.UninstallString
                UninstallExecutablePath = $_.UninstallExecutablePath
                ProcessIdentitySource = 'trusted_inventory_v3'
                TriggerHint = Test-ServiceTriggerHint $_
            }
        })
        return [pscustomobject]@{
            Services = [object[]]@($trustedServices)
            Tasks    = [object[]]@($trusted.Package.tasks)
        }
    }

    if ($AllowLimited) {
        $services = @()
        $script:ScanHealth['tasks'] = 'unavailable'
        Add-ScanWarning '显式 limited 扫描不采集计划任务；计划任务状态不可用。'
        try {
            $services = @(Get-ServicesInfo)
        } catch {
            Set-ScanHealthDegraded services
            Add-ScanWarning ('显式 limited 扫描无法读取系统服务，已使用安全空结果: ' + $_.Exception.Message)
            $services = @()
        }
        if ([string]$script:ScanHealth.services -cne 'complete') {
            Add-ScanWarning '显式 limited 扫描的系统服务采集不完整；仅保留安全的可用结果。'
        }
        return [pscustomobject]@{
            Services = [object[]]$services
            Tasks    = [object[]]@()
        }
    }

    $services = @()
    $tasks = @()
    $collectionErrors = [System.Collections.Generic.List[string]]::new()
    try {
        $services = @(Get-ServicesInfo)
    } catch {
        $collectionErrors.Add(('services: ' + $_.Exception.Message))
    }
    try {
        $tasks = @(Get-TasksInfo)
    } catch {
        $collectionErrors.Add(('tasks: ' + $_.Exception.Message))
    }
    if ($collectionErrors.Count -gt 0 -or
        [string]$script:ScanHealth.services -cne 'complete' -or
        [string]$script:ScanHealth.tasks -cne 'complete') {
        $details = [System.Collections.Generic.List[string]]::new()
        if ($collectionErrors.Count -gt 0) {
            $details.Add(('采集报错: ' + ($collectionErrors -join '; ')))
        }
        if ([string]$script:ScanHealth.services -cne 'complete') {
            $details.Add(('服务健康状态=' + $script:ScanHealth.services))
        }
        if ([string]$script:ScanHealth.tasks -cne 'complete') {
            $details.Add(('任务健康状态=' + $script:ScanHealth.tasks))
        }
        if (-not (Is-Admin) -and -not $AllowLimited -and [string]::IsNullOrWhiteSpace($InventoryNonce)) {
            $details.Add('当前会话非管理员；命令行完整扫描会被视为不完整。如果要做可执行清理的完整扫描，请使用管理员权限采集；若仅做观察扫描可加 -AllowLimited。')
        }
        $detail = if ($details.Count -gt 0) { ': ' + ($details -join '; ') } else { '' }
        throw ('系统服务或计划任务采集不完整' + $detail)
    }
    return [pscustomobject]@{
        Services = [object[]]$services
        Tasks    = [object[]]$tasks
    }
}

function Remove-PendingForScan {
    $path = $script:PendingFile
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) {
        throw 'pending 文件路径无效，拒绝开始扫描。'
    }

    try {
        $attributes = [System.IO.File]::GetAttributes($path)
    } catch [System.IO.FileNotFoundException] {
        return
    } catch [System.IO.DirectoryNotFoundException] {
        return
    }

    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        throw 'pending 文件路径不能是目录，拒绝开始扫描。'
    }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'pending 文件路径不能是 reparse point，拒绝开始扫描。'
    }
    Assert-PendingPathIsNotReparsePoint $path
    [System.IO.File]::Delete($path)
}

function Invoke-ScanMode {
    param(
        [string]$InventoryNonce = '',
        [switch]$AllowLimited,
        [string]$ReportPath = ''
    )

    Remove-PendingForScan
    Reset-ScanDiagnostics
    Write-Step '读取系统信息...';             $sys = Get-SystemInfo
    Write-Step '检查高占用进程...';           $procs = Get-TopProcesses 12
    Write-Step '检查系统服务与计划任务...';   $inventory = Get-ScanServiceTaskInventory -InventoryNonce $InventoryNonce -AllowLimited:$AllowLimited
    $svcs = [object[]]@($inventory.Services)
    $tasks = [object[]]@($inventory.Tasks)
    Write-Step '检查启动项...';               $autos = Get-AutoStart
    Write-Step '匹配安全规则...';             $hits = Match-Profiles -Services $svcs -AutoStarts $autos -Tasks $tasks -TopProcs $procs
    $susp = Get-SuspiciousProcesses $procs $hits
    $autoStartNames = Get-AutoStartProcessNames $autos

    Write-Step '生成扫描报告...'
    $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious $susp -Services $svcs -AutoStarts $autos -Tasks $tasks -Hits $hits -AutoStartNames $autoStartNames -ScanHealth $script:ScanHealth -ScanWarnings $script:ScanWarnings
    Write-Host $report

    if ($ReportPath) {
        $html = Write-HtmlReport -SysInfo $sys -TopProcs $procs -Suspicious $susp -AutoStarts $autos -Tasks $tasks -Hits $hits -AutoStartNames $autoStartNames -ScanHealth $script:ScanHealth -ScanWarnings $script:ScanWarnings
        [System.IO.File]::WriteAllText($ReportPath, $html, [System.Text.Encoding]::UTF8)
        Write-Host "报告已保存: $ReportPath" -ForegroundColor Green
    }
    Save-PendingActions -Hits $hits -Suspicious $susp -ScanHealth $script:ScanHealth -ScanWarnings $script:ScanWarnings
    return $report
}

