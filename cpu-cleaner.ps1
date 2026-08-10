# ============================================================
#  CPU 后台整理工具 v1.7.0 (cpu-cleaner.ps1) — 多维检测与风险评分
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
    [switch]$YesToAll,
    # v1.5.5: GUI 勾选子集清单路径 (只处理勾选条目)。
    # 注意参数名不能是 $PendingFile: param 变量与 $script:PendingFile 同名同变量,
    # 顶部默认赋值会覆盖参数值导致丢失, 故命名为 $PendingFileArg
    [string]$PendingFileArg = '',
    [string]$PendingSha256Arg = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
$script:PendingFile = Join-Path $script:Root 'pending_actions.json'
$script:PendingSha256 = $PendingSha256Arg
$script:RequirePendingSha256 = $false
$script:BackupRoot = Join-Path $script:Root 'backups'
# v1.5.2: 版本号全局唯一 (文本报告/HTML 页脚统一引用, 不再手改多处)
$script:Version = '1.7.0'
# 特征库更新地址(可选): 填入指向 bloatware-profiles.json 的 URL 后可用 -Mode update
$script:ProfileUrl = ''
# v1.5.1 供应链安全: 特征库 SHA256 校验文件地址 (与 ProfileUrl 配套发布, 可选但强烈建议)
$script:ProfileSha256Url = ''

# ---------- 工具函数 ----------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


# ---------- v1.7.0 模块化: 按域拆分到 src/Core/ (dot-source 保持 $script: 作用域共享) ----------
foreach ($f in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
    . (Join-Path $script:Root ('src\Core\' + $f + '.ps1'))
}

# ---------- 主流程 ----------
switch ($Mode) {
    'scan' {
        Write-Step '读取系统信息...';       $sys = Get-SystemInfo
        Write-Step '检查高占用进程...';     $procs = Get-TopProcesses 12
        $susp = Get-SuspiciousProcesses $procs
        Write-Step '检查系统服务...';       $svcs = Get-ServicesInfo
        Write-Step '检查启动项...';         $autos = Get-AutoStart
        Write-Step '检查计划任务...';       $tasks = Get-TasksInfo
        Write-Step '匹配安全规则...';       $hits = Match-Profiles -Services $svcs -AutoStarts $autos -Tasks $tasks -TopProcs $procs
        $autoStartNames = Get-AutoStartProcessNames $autos

        Write-Step '生成扫描报告...'
        $report = Write-ScanReport -SysInfo $sys -TopProcs $procs -Suspicious $susp -Services $svcs -AutoStarts $autos -Tasks $tasks -Hits $hits -AutoStartNames $autoStartNames
        Write-Host $report

        Save-PendingActions $hits $susp

        if ($ReportPath) {
            # HTML 报告 (v1.5.2: 统一到 Write-HtmlReport, 与文本报告同源)
            $html = Write-HtmlReport -SysInfo $sys -TopProcs $procs -Suspicious $susp -AutoStarts $autos -Tasks $tasks -Hits $hits -AutoStartNames $autoStartNames
            [System.IO.File]::WriteAllText($ReportPath, $html, [System.Text.Encoding]::UTF8)
            Write-Host "报告已保存: $ReportPath" -ForegroundColor Green
        }
    }
    'clean' {
        # v1.5.5: GUI 勾选子集 — -PendingFileArg 指向临时清单 (只处理勾选条目, 授权验证照跑)
        if ($PendingFileArg) {
            $script:PendingFile = $PendingFileArg
            $script:RequirePendingSha256 = $true
        }
        Invoke-Clean
    }
    'restore' { Invoke-Restore }
    'update' { Update-Profiles }
}
