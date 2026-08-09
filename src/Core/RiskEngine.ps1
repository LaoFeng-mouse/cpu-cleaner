# 风险评分 (v1.7.0 拆分): 多维评分体系
# ---------- 3.5 v1.4: 风险评分体系 (多维判断, 不只看关键词) ----------
function Get-RiskLevel($score) {
    if ($score -ge 70) { return '高度建议处理' }
    if ($score -ge 50) { return '可优化' }
    if ($score -ge 30) { return '建议观察' }
    return '正常'
}

function Convert-RiskToScore($risk) {
    switch ($risk) { 'high' { return 80 } 'medium' { return 55 } default { return 30 } }
}

# 对单个进程综合评分: 进程名+路径+签名+自启+CPU+特征库 多维判断
function Get-ProcessRiskScore {
    param($proc, $ProfileHits, $AutoStartNames, $TopProcs)
    $score = 0
    $reasons = @()

    # +30 已知特征库命中
    $hit = @($ProfileHits | Where-Object { $_.hit_type -eq 'process' -and $_.process_name -eq $proc.Name }) | Select-Object -First 1
    if ($hit) { $score += 30; $reasons += '已知特征库命中' }

    # +20 非系统目录
    if ($proc.Path -and $proc.Path -notmatch '^C:\\Windows\\') { $score += 20; $reasons += '非系统目录' }

    # +15 开机自启 (v1.5.1: 双方标准化后比较)
    if ($AutoStartNames -contains (Normalize-ProcessName $proc.Name)) { $score += 15; $reasons += '开机自启' }

    # +15 高 CPU (平均采样 >5%; v1.5.7: 'CPU%' 已是多次采样平均)
    if ($proc.'CPU%' -gt 5) { $score += 15; $reasons += "CPU$($proc.'CPU%')%" }

    # v1.5.7: +10 持续占用 — 一半以上采样 CPU≥5% (updater.exe 持续后台发疯型, 平均可能不高但一直占)
    if ($proc.SamplesHigh -and $proc.Samples -and ($proc.SamplesHigh / $proc.Samples) -ge 0.5) {
        $score += 10; $reasons += "持续占用$($proc.SamplesHigh)/$($proc.Samples)"
    }

    # 签名 (v1.5.1 P1: Microsoft 分支必须同时满足 Status -eq Valid, 防止"主题像微软但签名无效"吃到 -40)
    if ($proc.Path) {
        try {
            $sig = Get-AuthenticodeSignature $proc.Path -ErrorAction SilentlyContinue
            if ($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'Microsoft') {
                $score -= 40; $reasons += 'Microsoft签名'
            } elseif ($sig -and $sig.Status -ne 'Valid') {
                $score += 10; $reasons += '无有效签名'
            }
        } catch {}
    } else { $score += 10; $reasons += '无路径(服务或已退出)' }

    # -30 System32 / -25 驱动组件
    if ($proc.Path -and $proc.Path -match '\\Windows\\System32\\') { $score -= 30; $reasons += 'System32' }
    if ($proc.Path -and $proc.Path -match 'DriverStore|\\drivers\\') { $score -= 25; $reasons += '驱动组件' }

    # +10 同目录多进程 (≥3 个同目录进程, 疑似全家桶; 排除 Git/msys 工具目录)
    if ($proc.Path) {
        $dir = Split-Path $proc.Path -Parent
        if ($dir -notmatch 'Program Files\\Git|\\usr\\bin') {
            $sameDir = @($TopProcs | Where-Object { $_.Path -and (Split-Path $_.Path -Parent) -eq $dir })
            if ($sameDir.Count -ge 3) { $score += 10; $reasons += "同目录x$($sameDir.Count)" }
        }
    }

    if ($score -lt 0) { $score = 0 }
    return [pscustomobject]@{ Score = $score; Level = (Get-RiskLevel $score); Reasons = ($reasons -join ',') }
}

# 从自启列表提取进程名集合 (v1.5.1: 统一标准化为无扩展名小写, 用于评分 +15 开机自启)
function Get-AutoStartProcessNames($AutoStarts) {
    $names = @()
    foreach ($a in $AutoStarts) {
        $v = $a.Value -replace '"', ''
        if ($v -match '([^\s"\\/]+\.exe)') { $names += Normalize-ProcessName $matches[1] }
        $names += Normalize-ProcessName $a.Name
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

