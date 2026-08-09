# 系统采集 (v1.7.0 拆分): 概况/CPU 采样/服务/自启/任务/可疑进程
# ---------- 1. 系统与 CPU 概况 ----------
function Get-SystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    $boot = $os.LastBootUpTime
    $up = if ($boot) { (Get-Date) - $boot } else { $null }

    $load = 0
    try { $load = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1) } catch {}

    return [pscustomobject]@{
        Computer   = $cs.Name
        Model      = $cs.Manufacturer + ' ' + $cs.Model
        CPU        = $cpu.Name
        Cores      = $cpu.NumberOfCores
        Threads    = $cpu.NumberOfLogicalProcessors
        RAM_GB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        CPU_Load   = $load
        BootTime   = if ($boot) { $boot.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
        Uptime     = if ($up) { '{0}天 {1}小时 {2}分' -f $up.Days, $up.Hours, $up.Minutes } else { 'N/A' }
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
    $svcs = Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId
    # 触发器提示: Manual 却 Running = 可能被其他组件拉起 (B5)
    # 只对第三方服务标注 (系统服务太常见, 列出来是噪音)
    return @($svcs | ForEach-Object {
        $isThirdParty = $true
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
function Get-TasksInfo {
    $tasks = @()
    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
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
        }
    } catch {}
    return $tasks
}

