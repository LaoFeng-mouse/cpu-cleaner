# ============================================================
#  CPU 后台整理工具 v1.2 (cpu-cleaner.ps1) — Reliability Release
#  适用: Windows 10/11, PowerShell 5.1+
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan -ReportPath D:\报告.html
#    (管理员) powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode clean
#    (管理员) powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode restore -BackupDir D:\CPU后台整理工具\backups\20260809_120000
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode update    (需先配置 ProfileUrl)
#
#  安全设计:
#    - scan 完全只读
#    - clean 必须先 scan, 逐条确认后才执行; 结束进程必须显式输入 PID, 绝不自动杀
#    - 每个处理动作自动备份到 backups\, restore 一键恢复
# ============================================================

param(
    [ValidateSet('scan','clean','restore','update')]
    [string]$Mode = 'scan',
    [string]$ReportPath = '',
    [string]$BackupDir = '',
    [switch]$YesToAll
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
$script:PendingFile = Join-Path $script:Root 'pending_actions.json'
$script:BackupRoot = Join-Path $script:Root 'backups'
# 特征库更新地址(可选): 填入指向 bloatware-profiles.json 的 URL 后可用 -Mode update
$script:ProfileUrl = ''

# ---------- 工具函数 ----------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Utf8Json($path) {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return $raw | ConvertFrom-Json
}

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
function Get-TopProcesses([int]$TopN = 12) {
    $p1 = @{}
    Get-Process | ForEach-Object { $p1[$_.Id] = $_.CPU }
    Start-Sleep -Seconds 2
    $samples = @()
    Get-Process | ForEach-Object {
        $id = $_.Id
        if ($p1.ContainsKey($id)) {
            $delta = $_.CPU - $p1[$id]
            if ($delta -lt 0) { $delta = 0 }
            $cpuPct = [math]::Round($delta / 2 * 100 / [Environment]::ProcessorCount, 2)
            $samples += [pscustomobject]@{
                PID   = $id
                Name  = $_.ProcessName
                'CPU%' = $cpuPct
                MemMB = [math]::Round($_.WorkingSet64 / 1MB, 0)
                Path  = $_.Path
            }
        }
    }
    return ($samples | Sort-Object 'CPU%' -Descending | Select-Object -First $TopN)
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

# ---------- 7. 特征库匹配 (A2: 多类型同时命中, 结构化字段) ----------
function Match-Profiles {
    param($Services, $AutoStarts, $Tasks, $TopProcs)

    $profiles = Read-Utf8Json $script:ProfileFile
    $hits = @()

    foreach ($p in $profiles.profiles) {
        # 服务命中 (同一 profile 可能有多个服务, 取全部)
        foreach ($s in $Services) {
            $m = $p.match | Where-Object { $s.Name -like "*$_*" -or $s.DisplayName -like "*$_*" } | Select-Object -First 1
            if ($m) {
                $hits += [pscustomobject]@{
                    id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
                    risk = $p.risk; action = $p.action; safe = $p.safe; reason_cn = $p.reason_cn
                    hit_type = 'service'
                    detail = "$($s.Name) | $($s.DisplayName) | $($s.State)/$($s.StartMode)"
                    service_name = $s.Name
                    autostart_source = ''; autostart_name = ''; task_path = ''; process_name = ''
                }
            }
        }
        # 自启命中
        foreach ($a in $AutoStarts) {
            $m = $p.match | Where-Object { $a.Name -like "*$_*" -or $a.Value -like "*$_*" } | Select-Object -First 1
            if ($m) {
                $hits += [pscustomobject]@{
                    id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
                    risk = $p.risk; action = $p.action; safe = $p.safe; reason_cn = $p.reason_cn
                    hit_type = 'autostart'
                    detail = "$($a.Name) => $($a.Value)"
                    service_name = ''
                    autostart_source = $a.Source; autostart_name = $a.Name; task_path = ''; process_name = ''
                }
            }
        }
        # 计划任务命中
        foreach ($t in $Tasks) {
            $m = $p.match | Where-Object { $t.TaskName -like "*$_*" -or $t.TaskPath -like "*$_*" } | Select-Object -First 1
            if ($m) {
                $hits += [pscustomobject]@{
                    id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
                    risk = $p.risk; action = $p.action; safe = $p.safe; reason_cn = $p.reason_cn
                    hit_type = 'task'
                    detail = "$($t.TaskPath)$($t.TaskName) | $($t.State)"
                    service_name = ''
                    autostart_source = ''; autostart_name = ''; task_path = "$($t.TaskPath)$($t.TaskName)"; process_name = ''
                }
            }
        }
        # 进程命中 (仅提示)
        foreach ($tp in $TopProcs) {
            $m = $p.match | Where-Object { $tp.Name -like "*$_*" } | Select-Object -First 1
            if ($m) {
                $hits += [pscustomobject]@{
                    id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
                    risk = $p.risk; action = $p.action; safe = $p.safe; reason_cn = $p.reason_cn
                    hit_type = 'process'
                    detail = "$($tp.Name) PID=$($tp.PID) CPU=$($tp.'CPU%')%"
                    service_name = ''
                    autostart_source = ''; autostart_name = ''; task_path = ''; process_name = $tp.Name
                }
            }
        }
    }
    return $hits
}

# ---------- 8. 报告输出 ----------
function Write-ScanReport {
    param($SysInfo, $TopProcs, $Suspicious, $Services, $AutoStarts, $Tasks, $Hits)

    $lines = @()
    $lines += '=' * 60
    $lines += '  CPU 后台整理工具 - 诊断报告 v1.2'
    $lines += '  生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += '=' * 60
    $lines += ''
    $lines += '【1. 系统概况】'
    $lines += ('  电脑: {0}  {1}' -f $SysInfo.Computer, $SysInfo.Model)
    $lines += ('  CPU : {0}' -f $SysInfo.CPU)
    $lines += ('  核心: {0} 核 / {1} 线程, 内存 {2} GB' -f $SysInfo.Cores, $SysInfo.Threads, $SysInfo.RAM_GB)
    $lines += ('  当前 CPU 负载: {0}%' -f $SysInfo.CPU_Load)
    $lines += ('  开机时间: {0}  (已运行 {1})' -f $SysInfo.BootTime, $SysInfo.Uptime)
    $lines += ''

    $lines += '【2. 当前占用 CPU 最高的进程】'
    $lines += ('  {0,-6} {1,-24} {2,8} {3,8}  {4}' -f 'PID','进程名','CPU%','内存MB','路径')
    foreach ($p in $TopProcs) {
        $lines += ('  {0,-6} {1,-24} {2,8} {3,8}  {4}' -f $p.PID, $p.Name, $p.'CPU%', $p.MemMB, $p.Path)
    }
    $lines += ''

    $lines += '【3. 未知高占用进程 (路径可疑或无签名, 建议人工调查)】'
    if ($Suspicious.Count -eq 0) {
        $lines += '  (无 - 高占用进程均正常)'
    } else {
        foreach ($s in $Suspicious) {
            $lines += ('  !! {0} PID={1} CPU={2}%' -f $s.Name, $s.PID, $s.'CPU%')
            $lines += ('     原因: {0}' -f $s.Reason)
        }
        $lines += '  (处理方式: 用 -Mode clean 时按提示输入 PID 结束, 或任务管理器手动结束)'
    }
    $lines += ''

    $lines += '【4. 开机自启动项】'
    if ($AutoStarts.Count -eq 0) { $lines += '  (无)' }
    foreach ($a in $AutoStarts) {
        $lines += ('  [{0}] {1} => {2}' -f $a.Source, $a.Name, $a.Value)
    }
    $lines += ''

    $lines += '【5. 登录/开机触发的计划任务】'
    $loginTasks = @($Tasks | Where-Object { $_.LoginTrigger })
    if ($loginTasks.Count -eq 0) { $lines += '  (无)' }
    foreach ($t in $loginTasks) {
        $lines += ('  {0}{1} | {2}' -f $t.TaskPath, $t.TaskName, $t.State)
    }
    $lines += ''

    $lines += '【6. 特征库命中 (预装全家桶/可疑后台)】'
    if ($Hits.Count -eq 0) {
        $lines += '  (未命中特征库, 这台机器比较干净)'
    } else {
        foreach ($h in $Hits) {
            $riskMark = switch ($h.risk) { 'high' { '!!' } 'medium' { '! ' } default { '  ' } }
            $lines += ('  {0} [{1}] {2} ({3})' -f $riskMark, $h.vendor, $h.name_cn, $h.name)
            $lines += ('      命中: {0}  |  {1}' -f $h.hit_type, $h.detail)
            $lines += ('      建议: {0}  |  安全: {1}' -f $h.action, $(if ($h.safe) { '是' } else { '否-谨慎' }))
            $lines += ('      原因: {0}' -f $h.reason_cn)
        }
    }
    $lines += ''

    $lines += '【7. 手动启动却正在运行的服务 (可能被其他组件拉起, 禁用不一定立即停止)】'
    $trig = @($Services | Where-Object { $_.TriggerHint })
    if ($trig.Count -eq 0) {
        $lines += '  (无)'
    } else {
        foreach ($t in $trig) {
            $lines += ('  {0} | {1}' -f $t.Name, $t.DisplayName)
        }
    }
    $lines += ''

    $lines += '【8. 处理原则 (别乱动)】'
    $notes = (Read-Utf8Json $script:ProfileFile).keep_notes_cn
    foreach ($n in $notes) { $lines += ('  - ' + $n) }
    $lines += ''
    $lines += ('待处理清单已保存: {0}' -f $script:PendingFile)
    $lines += '确认无误后, 用管理员身份运行: cpu-cleaner.ps1 -Mode clean'
    $lines += ''

    return ($lines -join "`r`n")
}

# ---------- 9. 待办清单 (v1.2: safe 强制规则 + status 状态机) ----------
function Save-PendingActions($Hits, $Suspicious) {
    $actions = @()
    foreach ($h in $Hits) {
        if ($h.action -eq 'none' -or $h.action -eq 'investigate') { continue }
        # v1.2 强制规则: safe=false 只报告, 永不进入待办队列 (即使 -YesToAll 也不能执行)
        if (-not $h.safe) { continue }

        # 跳过已经是目标状态的条目
        $skip = $false
        if ($h.action -eq 'disable_service' -and $h.service_name) {
            $svc = Get-Service -Name $h.service_name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled' -and $svc.Status -eq 'Stopped') { $skip = $true }
        }
        elseif ($h.action -eq 'disable_task' -and $h.task_path) {
            $taskName = $h.task_path.Split('\')[-1]
            $taskFolder = if ($h.task_path.Length -gt $taskName.Length) { $h.task_path.Substring(0, $h.task_path.Length - $taskName.Length) } else { '\' }
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
            if ($task -and $task.State -eq 'Disabled') { $skip = $true }
        }
        elseif ($h.action -eq 'remove_autostart' -and $h.autostart_source -and $h.autostart_name) {
            $key = Get-ItemProperty $h.autostart_source -ErrorAction SilentlyContinue
            if (-not $key -or -not ($key.PSObject.Properties | Where-Object { $_.Name -eq $h.autostart_name })) { $skip = $true }
        }
        if ($skip) { continue }

        $actions += [pscustomobject]@{
            id        = $h.id
            vendor    = $h.vendor
            name_cn   = $h.name_cn
            action    = $h.action
            hit_type  = $h.hit_type
            detail    = $h.detail
            reason_cn = $h.reason_cn
            service_name      = $h.service_name
            autostart_source  = $h.autostart_source
            autostart_name    = $h.autostart_name
            task_path         = $h.task_path
            process_name      = $h.process_name
            safe      = $h.safe
            # v1.2 状态机: pending / success / failed / skipped / manual_required
            status    = 'pending'
        }
    }

    # 变量方式构造数组 (if/else 表达式输出空数组会被当成 $null, 序列化成 {} 而非 [])
    $suspArr = @()
    if ($Suspicious) {
        $suspArr = @($Suspicious | ForEach-Object {
            [pscustomobject]@{ PID=$_.PID; Name=$_.Name; 'CPU%'=$_.'CPU%'; MemMB=$_.MemMB; Path=$_.Path; Reason=$_.Reason }
        })
    }
    $payload = [pscustomobject]@{
        generated  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions    = $actions
        suspicious = $suspArr
    }
    # 用 -InputObject 强制序列化, 避免管道展开导致空数组写空文件
    $json = ConvertTo-Json -InputObject $payload -Depth 5
    [System.IO.File]::WriteAllText($script:PendingFile, $json, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- 10. clean 模式 ----------
# v1.2: 服务启动类型映射 (sc.exe 参数 vs StartType 枚举)
function Convert-StartTypeToSc($startType) {
    switch ($startType.ToString()) {
        'Automatic' { return 'auto' }
        'Manual'    { return 'demand' }
        'Disabled'  { return 'disabled' }
        'Boot'      { return 'boot' }
        'System'    { return 'system' }
        default     { return 'disabled' }
    }
}

# 旧 manifest 兼容: 数字枚举 0=Boot 1=System 2=Automatic 3=Manual 4=Disabled
function Convert-NumberToSc($n) {
    switch ([int]$n) {
        0 { return 'boot' }
        1 { return 'system' }
        2 { return 'auto' }
        3 { return 'demand' }
        4 { return 'disabled' }
        default { return 'disabled' }
    }
}

# 采集服务备份信息: 启动类型(sc 格式/显示格式) + 运行状态 + DelayedAutoStart
function Get-ServiceBackupInfo($srvName) {
    $svc = Get-Service -Name $srvName -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $startType = $svc.StartType.ToString()
    $delayed = 0
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName"
        $delayed = (Get-ItemProperty $regPath -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart
    } catch { $delayed = 0 }
    return [pscustomobject]@{
        start_type_sc      = Convert-StartTypeToSc $startType
        start_type_display = $startType
        status             = $svc.Status.ToString()
        delayed_autostart  = $delayed
    }
}

function Backup-RegistryKey($keyPath, $backupDir, $tag) {
    $regPath = $keyPath -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    $out = Join-Path $backupDir ("$tag.reg")
    reg export $regPath $out /y 2>$null | Out-Null
    return $out
}

function Invoke-Clean {
    if (-not (Is-Admin)) {
        Write-Host '错误: clean 模式需要管理员权限。请右键以管理员身份运行 PowerShell 再执行。' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $script:PendingFile)) {
        Write-Host '未找到 pending_actions.json, 请先运行 scan 模式生成清单。' -ForegroundColor Red
        exit 1
    }
    $pending = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    # null 防御: $pending.actions 为空/null 时不得产生 @($null) 元素 (管道展开陷阱)
    # v1.2 状态机: 只处理 pending(待办) 和 failed(可重试); success/skipped/manual_required 跳过
    $actions = @()
    if ($pending.actions) { $actions = @($pending.actions | Where-Object { $_ -and $_.status -in @('pending','failed') }) }
    $suspicious = @()
    if ($pending.suspicious) { $suspicious = @($pending.suspicious) }

    if ($actions.Count -eq 0) {
        Write-Host '待办动作已全部完成或为空。' -ForegroundColor Green
    } else {
        Write-Step '以下动作将被处理, 每个动作都会先备份:'
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $p = $actions[$i]
            Write-Host ('  [{0}] {1} | 动作: {2} | 命中: {3}' -f $i, $p.name_cn, $p.action, $p.hit_type) -ForegroundColor Yellow
            Write-Host ('      详情: {0}' -f $p.detail)
            Write-Host ('      原因: {0}' -f $p.reason_cn)
        }

        $sel = 'q'
        if ($YesToAll) { $sel = 'all' }
        else {
            Write-Host ''
            $sel = Read-Host '输入要处理的编号(逗号分隔), all=全部, q=退出'
        }
        if ($sel -eq 'q') { Write-Host '已取消。'; exit 0 }

        $indexes = @()
        if ($sel -eq 'all') { $indexes = 0..($actions.Count - 1) }
        else {
            foreach ($part in ($sel -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 0 -and $n -lt $actions.Count) { $indexes += $n }
            }
        }
        if ($indexes.Count -eq 0) { Write-Host '未选择有效条目, 已取消。'; exit 0 }

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupDir = Join-Path $script:BackupRoot $stamp
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $manifest = @()

        foreach ($idx in $indexes) {
            $p = $actions[$idx]
            $tag = ('{0}_{1}' -f $idx, ($p.id -replace '[^a-zA-Z0-9_-]', '_'))
            Write-Step ('处理: {0} ({1})' -f $p.name_cn, $p.action)

            # v1.2 强制规则: safe=false 即使被选中/YesToAll 也拒绝执行
            if (-not $p.safe) {
                Write-Host '  拒绝: safe=false 条目禁止自动执行, 只做人工调查。' -ForegroundColor Red
                $p.status = 'skipped'
                continue
            }

            switch ($p.action) {
                'disable_service' {
                    $srvName = $p.service_name
                    if ($srvName -and $srvName -match '^[A-Za-z0-9_.]+$') {
                        $info = Get-ServiceBackupInfo $srvName
                        if (-not $info) {
                            Write-Host "  服务不存在: $srvName" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                            continue
                        }
                        $bak = Backup-RegistryKey "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName" $backupDir $tag
                        Write-Host "  [sc] config $srvName start= disabled" -ForegroundColor DarkGray
                        sc.exe config $srvName start= disabled
                        Write-Host "  [sc] stop $srvName" -ForegroundColor DarkGray
                        sc.exe stop $srvName
                        # v1.2: 执行后验证 (重新读取真实状态, 不能"命令执行过=成功")
                        $after = Get-Service -Name $srvName -ErrorAction SilentlyContinue
                        if ($after -and $after.StartType -eq 'Disabled') {
                            $p.status = 'success'
                            $note = if ($after.Status -eq 'Running') { '已禁用但进程仍在运行(重启后消失)' } else { '已禁用并停止' }
                            Write-Host "  验证通过: StartType=Disabled, $note" -ForegroundColor Green
                            $manifest += [pscustomobject]@{
                                type='service'; name=$srvName; backup=$bak
                                start_type_sc=$info.start_type_sc; start_type_display=$info.start_type_display
                                status=$info.status; delayed_autostart=$info.delayed_autostart
                                verified=$true; note='restore: sc config <name> start= <start_type_sc>'
                            }
                        } else {
                            $p.status = 'failed'
                            $actual = if ($after) { $after.StartType.ToString() } else { '服务不存在' }
                            Write-Host "  验证失败: 当前 StartType=$actual (可能被自我保护拦截)" -ForegroundColor Red
                            $manifest += [pscustomobject]@{
                                type='service'; name=$srvName; backup=$bak
                                start_type_sc=$info.start_type_sc; start_type_display=$info.start_type_display
                                status=$info.status; delayed_autostart=$info.delayed_autostart
                                verified=$false; note='restore: sc config <name> start= <start_type_sc>'
                            }
                        }
                    } else {
                        Write-Host "  跳过: 服务名无效 ($srvName)" -ForegroundColor DarkYellow
                        $p.status = 'skipped'
                    }
                }
                'remove_autostart' {
                    $rp = $p.autostart_source
                    $nm = $p.autostart_name
                    if ($rp -and $nm) {
                        $key = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                        if ($key -and ($key.PSObject.Properties | Where-Object { $_.Name -eq $nm })) {
                            $bak = Backup-RegistryKey $rp $backupDir $tag
                            Remove-ItemProperty -Path $rp -Name $nm -ErrorAction SilentlyContinue
                            # v1.2: 执行后验证
                            $keyAfter = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                            $stillThere = $keyAfter -and ($keyAfter.PSObject.Properties | Where-Object { $_.Name -eq $nm })
                            if (-not $stillThere) {
                                $p.status = 'success'
                                Write-Host "  验证通过: 自启项已删除: $nm (备份: $bak)" -ForegroundColor Green
                                $manifest += [pscustomobject]@{ type='autostart'; key=$rp; name=$nm; backup=$bak; verified=$true; note='restore: reg import <backup>' }
                            } else {
                                $p.status = 'failed'
                                Write-Host "  验证失败: 自启项仍在 ($nm)" -ForegroundColor Red
                                $manifest += [pscustomobject]@{ type='autostart'; key=$rp; name=$nm; backup=$bak; verified=$false; note='restore: reg import <backup>' }
                            }
                        } else {
                            Write-Host "  跳过: 自启项已不存在 ($nm)" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                        }
                    }
                }
                'disable_task' {
                    $taskPath = $p.task_path
                    if ($taskPath) {
                        $taskName = $taskPath.Split('\')[-1]
                        $taskFolder = if ($taskPath.Length -gt $taskName.Length) { $taskPath.Substring(0, $taskPath.Length - $taskName.Length) } else { '\' }
                        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
                        if ($task) {
                            $xml = Export-ScheduledTask -TaskName $taskName -TaskPath $taskFolder
                            $bak = Join-Path $backupDir "$tag.xml"
                            $xml | Out-File $bak -Encoding utf8
                            Disable-ScheduledTask -TaskName $taskName -TaskPath $taskFolder | Out-Null
                            # v1.2: 执行后验证
                            $taskAfter = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
                            if (-not $taskAfter -or $taskAfter.State -eq 'Disabled') {
                                $p.status = 'success'
                                Write-Host "  验证通过: 已禁用计划任务: $taskPath (备份: $bak)" -ForegroundColor Green
                                $manifest += [pscustomobject]@{ type='task'; name=$taskPath; backup=$bak; verified=$true; note='restore: Register-ScheduledTask -Xml <backup> -TaskName <name> -TaskPath <path> -Force' }
                            } else {
                                $p.status = 'failed'
                                Write-Host "  验证失败: 任务状态=$($taskAfter.State)" -ForegroundColor Red
                                $manifest += [pscustomobject]@{ type='task'; name=$taskPath; backup=$bak; verified=$false; note='restore: Register-ScheduledTask -Xml <backup> -TaskName <name> -TaskPath <path> -Force' }
                            }
                        } else {
                            Write-Host "  跳过: 计划任务不存在 ($taskPath)" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                        }
                    }
                }
                'uninstall' {
                    Write-Host '  uninstall 动作需要人工确认, 请到 设置 -> 应用 -> 已安装的应用 手动卸载。' -ForegroundColor Yellow
                    $p.status = 'manual_required'
                }
                default {
                    Write-Host "  未知动作: $($p.action), 跳过" -ForegroundColor DarkYellow
                    $p.status = 'skipped'
                }
            }
        }

        # -InputObject 强制数组, 空 manifest 也写 []
        $jsonM = ConvertTo-Json -InputObject @($manifest) -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $backupDir 'manifest.json'), $jsonM, (New-Object System.Text.UTF8Encoding($true)))
        Write-Step "动作处理完成。备份目录: $backupDir"

        # 写回 status 状态机 (v1.2): 重建完整 payload, 用 -InputObject 防管道展开
        $suspArr2 = @()
        if ($pending.suspicious) { $suspArr2 = @($pending.suspicious) }
        $payload2 = [pscustomobject]@{
            generated  = $pending.generated
            actions    = @($pending.actions)
            suspicious = $suspArr2
        }
        $json2 = ConvertTo-Json -InputObject $payload2 -Depth 5
        [System.IO.File]::WriteAllText($script:PendingFile, $json2, (New-Object System.Text.UTF8Encoding($true)))
    }

    # ---- 可疑进程处理 (B4: 显式输入 PID, 不自动杀) ----
    if ($suspicious.Count -gt 0) {
        Write-Step '检测到可疑高占用进程 (路径可疑或无签名):'
        foreach ($s in $suspicious) {
            Write-Host ('  PID {0}  {1}  CPU={2}%  {3}' -f $s.PID, $s.Name, $s.'CPU%', $s.Reason) -ForegroundColor Yellow
        }
        if (-not $YesToAll) {
            $killSel = Read-Host '输入要结束的 PID(逗号分隔), 直接回车跳过'
            if ($killSel -match '\d') {
                $pids = @()
                foreach ($part in ($killSel -split ',')) {
                    $n = 0
                    if ([int]::TryParse($part.Trim(), [ref]$n)) { $pids += $n }
                }
                foreach ($pidNum in $pids) {
                    $proc = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
                    if ($proc) {
                        Write-Host "  结束进程: $($proc.ProcessName) (PID $pidNum) 路径: $($proc.Path)" -ForegroundColor DarkGray
                        Stop-Process -Id $pidNum -Force -ErrorAction SilentlyContinue
                        if (Get-Process -Id $pidNum -ErrorAction SilentlyContinue) {
                            Write-Host "  失败: 进程 $pidNum 仍在运行 (可能拒绝终止)" -ForegroundColor Red
                        } else {
                            Write-Host "  已结束 PID $pidNum" -ForegroundColor Green
                            # 记录到备份(提示可手动重启), 追加到最近一次备份的 manifest
                            $latest = Get-ChildItem $script:BackupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                            if ($latest) {
                                $mf = Join-Path $latest.FullName 'manifest.json'
                                $man = @()
                                if (Test-Path $mf) { $man = @(Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json) }
                                $man += [pscustomobject]@{ type='process'; name=$proc.ProcessName; pid=$pidNum; path=$proc.Path; note="restore: 如需恢复请手动启动 $($proc.Path)" }
                                $man | ConvertTo-Json -Depth 5 | Out-File $mf -Encoding utf8
                            }
                        }
                    } else {
                        Write-Host "  PID $pidNum 不存在, 跳过" -ForegroundColor DarkYellow
                    }
                }
            }
        } else {
            Write-Host '  (YesToAll 模式: 进程默认不杀, 需显式输入 PID)' -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "`n无可疑高占用进程。" -ForegroundColor Green
    }

    Write-Step '完成。建议重启一次让所有禁用生效。'
}

# ---------- 11. restore 模式 ----------
function Invoke-Restore {
    if (-not $BackupDir -or -not (Test-Path $BackupDir)) {
        Write-Host '错误: 需要有效的 -BackupDir 参数。例: cpu-cleaner.ps1 -Mode restore -BackupDir "D:\CPU后台整理工具\backups\20260809_120000"' -ForegroundColor Red
        Write-Host '可用备份: ' -ForegroundColor Yellow -NoNewline
        if (Test-Path $script:BackupRoot) { Get-ChildItem $script:BackupRoot -Directory | ForEach-Object { Write-Host $_.Name -NoNewline; Write-Host '  ' -NoNewline } }
        Write-Host ''
        exit 1
    }
    $manifestFile = Join-Path $BackupDir 'manifest.json'
    if (-not (Test-Path $manifestFile)) {
        Write-Host "备份目录中没有 manifest.json: $BackupDir" -ForegroundColor Red
        exit 1
    }
    if (-not (Is-Admin)) {
        Write-Host '错误: restore 模式需要管理员权限。' -ForegroundColor Red
        exit 1
    }
    $manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest -or @($manifest).Count -eq 0) {
        Write-Host "备份清单为空: $manifestFile (可能是损坏的备份)" -ForegroundColor Red
        exit 1
    }
    Write-Step "从备份恢复: $BackupDir"

    foreach ($m in $manifest) {
        switch ($m.type) {
            'service' {
                # v1.2: 启动类型映射修复 (Automatic→auto, Manual→demand, Disabled→disabled)
                # 兼容三种 manifest 格式: 新格式 start_type_sc / 旧格式 before(字符串枚举) / 更旧 before(数字枚举)
                $scVal = $null
                if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) {
                    $scVal = $m.start_type_sc
                } elseif ($m.before -match '^\d+$') {
                    $scVal = Convert-NumberToSc $m.before
                } elseif ($m.before) {
                    $scVal = Convert-StartTypeToSc $m.before
                } else {
                    $scVal = 'disabled'
                }
                Write-Host "  恢复服务 $($m.name): sc config start= $scVal" -ForegroundColor Yellow
                sc.exe config $m.name start= $scVal

                # 恢复 DelayedAutoStart (v1.2)
                if ($m.PSObject.Properties.Name -contains 'delayed_autostart') {
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($m.name)"
                    $delayed = if ($m.delayed_autostart -eq 1 -or $m.delayed_autostart -eq $true) { 1 } else { 0 }
                    try {
                        New-ItemProperty -Path $regPath -Name DelayedAutostart -PropertyType DWord -Value $delayed -Force -ErrorAction Stop | Out-Null
                        Write-Host "  恢复 DelayedAutoStart: $delayed" -ForegroundColor Green
                    } catch {
                        Write-Host "  无法写 DelayedAutoStart (可能无此键): $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }

                # 原运行状态提示 (v1.2: 默认不自动启动, 保守; 记录原状态供用户决策)
                $origStatus = if ($m.PSObject.Properties.Name -contains 'status') { $m.status } else { '未知' }
                $restartAfter = if ($m.PSObject.Properties.Name -contains 'restart_after_restore') { $m.restart_after_restore } else { $false }
                if ($origStatus -eq 'Running') {
                    if ($restartAfter) {
                        Write-Host "  原状态为 Running, 按记录重新启动服务..." -ForegroundColor DarkGray
                        sc.exe start $m.name
                    } else {
                        Write-Host "  提示: 该服务原为 Running, 如需立即启动: sc start $($m.name)" -ForegroundColor DarkYellow
                    }
                }
            }
            'autostart' {
                Write-Host "  恢复自启项(reg import): $($m.backup)" -ForegroundColor Yellow
                reg import $m.backup
            }
            'task' {
                Write-Host "  恢复计划任务: $($m.name)" -ForegroundColor Yellow
                $xml = Get-Content $m.backup -Raw -Encoding UTF8
                $taskName = $m.name.Split('\')[-1]
                $taskFolder = $m.name.Substring(0, $m.name.Length - $taskName.Length)
                Register-ScheduledTask -Xml $xml -TaskName $taskName -TaskPath $taskFolder -Force | Out-Null
            }
            'process' {
                Write-Host "  进程 $($m.name) 无法自动恢复, 如需恢复请手动启动: $($m.path)" -ForegroundColor Yellow
            }
        }
    }
    Write-Step '恢复完成。'
}

# ---------- 12. 特征库更新 (C10) ----------
function Update-Profiles {
    if (-not $script:ProfileUrl) {
        Write-Host '未配置特征库更新地址。请编辑 cpu-cleaner.ps1 顶部的 $script:ProfileUrl 变量。' -ForegroundColor Red
        exit 1
    }
    Write-Step "从 $script:ProfileUrl 下载最新特征库..."
    try {
        $tmp = Join-Path $script:Root 'bloatware-profiles.json.tmp'
        Invoke-WebRequest -Uri $script:ProfileUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30
        # 验证是合法 JSON 且含 profiles 字段
        $check = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($check.profiles) {
            $bak = Join-Path $script:Root ('bloatware-profiles.json.bak.' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item $script:ProfileFile $bak -Force
            Move-Item $tmp $script:ProfileFile -Force
            Write-Host "特征库已更新 (旧版备份: $bak)" -ForegroundColor Green
        } else {
            Write-Host '下载内容不是有效的特征库, 已放弃更新。' -ForegroundColor Red
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host ('更新失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

# ---------- 主流程 ----------
switch ($Mode) {
    'scan' {
        Write-Step '扫描系统 (只读, 不修改任何设置)...'
        $sys = Get-SystemInfo
        $procs = Get-TopProcesses 12
        $susp = Get-SuspiciousProcesses $procs
        $svcs = Get-ServicesInfo
        $autos = Get-AutoStart
        $tasks = Get-TasksInfo
        $hits = Match-Profiles -Services $svcs -AutoStarts $autos -Tasks $tasks -TopProcs $procs

        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious $susp -Services $svcs -AutoStarts $autos -Tasks $tasks -Hits $hits
        Write-Host $report

        Save-PendingActions $hits $susp

        if ($ReportPath) {
            # HTML 报告 (C9: 简单样式)
            $esc = { param($s) ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
            $sec1 = ''
            $sec1 += "<h2>1. 系统概况</h2><table><tr><th>电脑</th><td>$(& $esc $sys.Model)</td></tr><tr><th>CPU</th><td>$(& $esc $sys.CPU)</td></tr><tr><th>核心</th><td>$($sys.Cores) 核 / $($sys.Threads) 线程 / 内存 $($sys.RAM_GB) GB</td></tr><tr><th>当前负载</th><td><b>$($sys.CPU_Load)%</b></td></tr><tr><th>开机</th><td>$($sys.BootTime) (已运行 $($sys.Uptime))</td></tr></table>"

            $sec2 = "<h2>2. Top CPU 进程</h2><table><tr><th>PID</th><th>进程</th><th>CPU%</th><th>内存MB</th><th>路径</th></tr>"
            foreach ($p in $procs) { $sec2 += "<tr><td>$($p.PID)</td><td>$(& $esc $p.Name)</td><td>$($p.'CPU%')</td><td>$($p.MemMB)</td><td>$(& $esc $p.Path)</td></tr>" }
            $sec2 += '</table>'

            $sec3 = "<h2>3. 未知高占用进程</h2>"
            if ($susp.Count -eq 0) { $sec3 += '<p>无 - 高占用进程均正常</p>' }
            else {
                $sec3 += '<table><tr><th>PID</th><th>进程</th><th>CPU%</th><th>原因</th></tr>'
                foreach ($s in $susp) { $sec3 += "<tr><td>$($s.PID)</td><td>$(& $esc $s.Name)</td><td>$($s.'CPU%')</td><td>$(& $esc $s.Reason)</td></tr>" }
                $sec3 += '</table>'
            }

            $sec4 = "<h2>4. 开机自启动项</h2><table><tr><th>来源</th><th>名称</th><th>命令</th></tr>"
            foreach ($a in $autos) { $sec4 += "<tr><td>$(& $esc $a.Source)</td><td>$(& $esc $a.Name)</td><td>$(& $esc $a.Value)</td></tr>" }
            $sec4 += '</table>'

            $sec5 = "<h2>5. 特征库命中</h2>"
            if ($hits.Count -eq 0) { $sec5 += '<p>未命中特征库</p>' }
            else {
                $sec5 += '<table><tr><th>风险</th><th>厂商</th><th>名称</th><th>命中</th><th>建议</th><th>原因</th></tr>'
                foreach ($h in $hits) {
                    $rm = switch ($h.risk) { 'high' { '高' } 'medium' { '中' } default { '低' } }
                    $sec5 += "<tr><td>$rm</td><td>$($h.vendor)</td><td>$(& $esc $h.name_cn)</td><td>$($h.hit_type)</td><td>$($h.action)</td><td>$(& $esc $h.reason_cn)</td></tr>"
                }
                $sec5 += '</table>'
            }

            $notes = (Read-Utf8Json $script:ProfileFile).keep_notes_cn
            $sec6 = "<h2>6. 处理原则</h2><ul>"
            foreach ($n in $notes) { $sec6 += "<li>$(& $esc $n)</li>" }
            $sec6 += '</ul>'

            $html = @"
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<title>CPU 后台诊断报告</title>
<style>
body{font-family:'Microsoft YaHei',sans-serif;max-width:1100px;margin:20px auto;padding:0 20px;color:#222;background:#f7f7f7}
h1{color:#1a5276}h2{color:#1a5276;border-left:4px solid #1a5276;padding-left:8px;margin-top:28px}
table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th{background:#1a5276;color:#fff;padding:8px 10px;text-align:left;font-size:13px}
td{padding:6px 10px;border-bottom:1px solid #eee;font-size:13px;word-break:break-all}
tr:hover td{background:#eaf2f8}
.meta{color:#666;font-size:12px;margin-bottom:16px}
.high{color:#c0392b;font-weight:bold}.medium{color:#b9770e}
</style></head><body>
<h1>CPU 后台诊断报告</h1>
<div class="meta">生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; CPU 后台整理工具 v1.1</div>
$sec1$sec2$sec3$sec4$sec5$sec6
</body></html>
"@
            [System.IO.File]::WriteAllText($ReportPath, $html, [System.Text.Encoding]::UTF8)
            Write-Host "报告已保存: $ReportPath" -ForegroundColor Green
        }
    }
    'clean' { Invoke-Clean }
    'restore' { Invoke-Restore }
    'update' { Update-Profiles }
}
