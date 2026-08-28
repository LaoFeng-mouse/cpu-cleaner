# ============================================================
#  CPU 后台整理工具 v1.8.1 (cpu-cleaner.ps1) — 多维检测与风险评分
#  适用: Windows 10/11, PowerShell 5.1+
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan -ReportPath D:\报告.html
#    (管理员) powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode clean
#    (管理员) powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode restore -BackupDir D:\CPU后台整理工具\backups\20260809_120000
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode stop_process -PendingFileArg <subset.json> -PendingSha256Arg <sha256>
#    powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode update    (需先配置 ProfileUrl)
#
#  安全设计:
#    - scan 完全只读
#    - clean 必须先 scan, 逐条确认后才执行; 结束进程使用独立哈希绑定清单并重验完整进程身份
#    - 持久化系统变更自动备份到 backups\，restore 一键恢复；一次性结束进程不属于可恢复变更
# ============================================================

param(
    [ValidateSet('scan','scan_inventory','clean','restore','update','stop_process')]
    [string]$Mode = 'scan',
    [string]$InventoryNonce = '',
    [switch]$AllowLimited,
    [string]$ReportPath = '',
    [string]$BackupDir = '',
    [switch]$YesToAll,
    # v1.5.5: GUI 勾选子集清单路径 (只处理勾选条目)。
    # 注意参数名不能是 $PendingFile: param 变量与 $script:PendingFile 同名同变量,
    # 顶部默认赋值会覆盖参数值导致丢失, 故命名为 $PendingFileArg
    [string]$PendingFileArg = '',
    [string]$PendingSha256Arg = '',
    [object]$ConfirmedImpactSha256Arg = $null
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
$script:PendingFile = Join-Path $script:Root 'pending_actions.json'
$script:PendingSha256 = $PendingSha256Arg
$script:RequirePendingSha256 = $false
$script:ConfirmedImpactSha256 = $null
$script:BackupRoot = Join-Path $script:Root 'backups'
# v1.5.2: 版本号全局唯一 (文本报告/HTML 页脚统一引用, 不再手改多处)
$script:Version = '1.8.1'
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
foreach ($f in @('Utils','ProtectedServiceHandoff','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager','InventoryManager')) {
    . (Join-Path $script:Root ('src\Core\' + $f + '.ps1'))
}

# ---------- 主流程 ----------
try {
    if ($PSBoundParameters.ContainsKey('AllowLimited') -and $Mode -cne 'scan') {
        throw 'AllowLimited is valid only with Mode scan.'
    }
    if ($PSBoundParameters.ContainsKey('InventoryNonce') -and $Mode -cnotin @('scan','scan_inventory')) {
        throw 'InventoryNonce is valid only with Mode scan or internal scan_inventory.'
    }
    if ($AllowLimited -and $PSBoundParameters.ContainsKey('InventoryNonce')) {
        throw 'InventoryNonce and AllowLimited are mutually exclusive.'
    }
    if ($PSBoundParameters.ContainsKey('InventoryNonce') -and -not (Test-InventoryNonce $InventoryNonce)) {
        throw 'Invalid inventory nonce.'
    }
    $impactArgumentWasProvided = $PSBoundParameters.ContainsKey('ConfirmedImpactSha256Arg')
    if ($impactArgumentWasProvided) {
        $script:ConfirmedImpactSha256 = Get-NormalizedConfirmedImpactSha256 -Value $ConfirmedImpactSha256Arg -Mode $Mode -WasProvided $true
    }
} catch {
    Write-Error ('Invalid arguments: ' + $_.Exception.Message)
    exit 1
}

switch ($Mode) {
    'scan_inventory' {
        try {
            $unrelatedInventoryArguments = @($PSBoundParameters.Keys | Where-Object { $_ -cnotin @('Mode','InventoryNonce') })
            if ($unrelatedInventoryArguments.Count -gt 0) {
                throw ('scan_inventory accepts only InventoryNonce; rejected: ' + ($unrelatedInventoryArguments -join ', '))
            }
            $null = Invoke-ScanInventory -Nonce $InventoryNonce
            exit 0
        } catch {
            Write-Error ('scan_inventory failed: ' + $_.Exception.Message)
            exit 1
        }
    }
    'scan' {
        try {
            $null = Invoke-ScanMode -InventoryNonce $InventoryNonce -AllowLimited:$AllowLimited -ReportPath $ReportPath
            exit 0
        } catch {
            Write-Error ('scan failed: ' + $_.Exception.Message)
            exit 1
        }
    }
    'clean' {
        # v1.5.5: GUI 勾选子集 — -PendingFileArg 指向临时清单 (只处理勾选条目, 授权验证照跑)
        if ($PendingFileArg) {
            $script:PendingFile = $PendingFileArg
            $script:RequirePendingSha256 = $true
        }
        $cleanExitCode = Invoke-Clean
        exit ([int]$cleanExitCode)
    }
    'restore' { Invoke-Restore }
    'stop_process' {
        $result = Invoke-StopProcessPending -Path $PendingFileArg -ExpectedSha256 $PendingSha256Arg
        foreach ($row in @($result.Results)) {
            Write-Host ("PID {0} {1}: {2}" -f $row.PID, $row.status, $row.result_reason)
        }
        exit ([int]$result.ExitCode)
    }
    'update' { Update-Profiles }
}
