# 报告输出 (v1.7.0 拆分): 文本报告 + HTML 报告
# ---------- 8. 报告输出 ----------
function Write-ScanReport {
    param($SysInfo, $TopProcs, $Suspicious, $Services, $AutoStarts, $Tasks, $Hits, $AutoStartNames, $ScanHealth = $script:ScanHealth, $ScanWarnings = $script:ScanWarnings)

    $lines = @()
    $degraded = Test-ScanHealthDegraded $ScanHealth
    $lines += '=' * 60
    $lines += ('  CPU 后台整理工具 - 诊断报告 v{0}' -f $script:Version)
    $lines += '  生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $lines += '=' * 60
    if ($degraded) {
        $lines += '  !! 扫描信息不完整：部分分类使用兼容采集，不能据此判断机器干净。'
        foreach ($warning in @($ScanWarnings)) { $lines += ('     - {0}' -f $warning) }
    }
    $lines += ''
    $lines += '【1. 系统概况】'
    $lines += ('  电脑: {0}  {1}' -f $SysInfo.Computer, $SysInfo.Model)
    $lines += ('  CPU : {0}' -f $SysInfo.CPU)
    $ramText = if ($SysInfo.RAM_GB -is [ValueType] -and [double]$SysInfo.RAM_GB -ge 0) { '{0} GB' -f $SysInfo.RAM_GB } else { [string]$SysInfo.RAM_GB }
    $loadText = if ($SysInfo.CPU_Load -is [ValueType] -and [double]$SysInfo.CPU_Load -ge 0) { '{0}%' -f $SysInfo.CPU_Load } else { [string]$SysInfo.CPU_Load }
    $lines += ('  核心: {0} 核 / {1} 线程, 内存 {2}' -f $SysInfo.Cores, $SysInfo.Threads, $ramText)
    $lines += ('  当前 CPU 负载: {0}' -f $loadText)
    $lines += ('  开机时间: {0}  (已运行 {1})' -f $SysInfo.BootTime, $SysInfo.Uptime)
    $lines += ''

    # v1.4: 对 Top CPU 进程逐一评分
    $procScores = @{}
    foreach ($p in $TopProcs) {
        $procScores[$p.PID] = Get-ProcessRiskScore -proc $p -ProfileHits $Hits -AutoStartNames $AutoStartNames -TopProcs $TopProcs
    }

    $lines += '【2. 当前占用 CPU 最高的进程 (v1.5.7: 多次采样 — 平均/峰值/持续占用/子进程)】'
    $lines += ('  {0,-6} {1,-20} {2,7} {3,7} {4,7} {5,5} {6,6} {7,-12} {8}' -f 'PID','进程名','平均%','峰值%','持续','子进程','风险分','级别','评分依据')
    foreach ($p in $TopProcs) {
        $s = $procScores[$p.PID]
        $lines += ('  {0,-6} {1,-20} {2,7} {3,7} {4,7} {5,5} {6,6} {7,-12} {8}' -f $p.PID, $p.Name, $p.'CPU%', $p.CPUPeak, ("{0}/{1}" -f $p.SamplesHigh, $p.Samples), $p.ChildCount, $s.Score, $s.Level, $s.Reasons)
    }
    $lines += '  (持续 = 采样中 CPU≥5% 的次数/总采样数; 持续占用识别"一直占着不放"的后台)'
    $lines += ''

    # v1.4: 风险分级汇总
    $lines += '【3. 风险分级汇总】'
    $summary = @{ '正常' = 0; '建议观察' = 0; '可优化' = 0; '高度建议处理' = 0 }
    foreach ($p in $TopProcs) { $summary[$procScores[$p.PID].Level]++ }
    foreach ($k in '正常','建议观察','可优化','高度建议处理') {
        $lines += ('  {0,-10} {1} 个' -f $k, $summary[$k])
    }
    $lines += '  (评分说明: +30特征库 +20非系统目录 +15开机自启 +15高CPU +10无签名/同目录多进程; -40微软签名 -30System32 -25驱动)'
    $lines += ''

    $lines += '【4. 未知高占用进程 (路径可疑或无签名, 建议人工调查)】'
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

    $lines += '【5. 开机自启动项】'
    if ($AutoStarts.Count -eq 0) { $lines += '  (无)' }
    foreach ($a in $AutoStarts) {
        $lines += ('  [{0}] {1} => {2}' -f $a.Source, $a.Name, $a.Value)
    }
    $lines += ''

    $lines += '【6. 登录/开机触发的计划任务】'
    $loginTasks = @($Tasks | Where-Object { $_.LoginTrigger })
    if ($loginTasks.Count -eq 0) { $lines += '  (无)' }
    foreach ($t in $loginTasks) {
        $lines += ('  {0}{1} | {2}' -f $t.TaskPath, $t.TaskName, $t.State)
    }
    $lines += ''

    $lines += '【7. 特征库命中 (预装全家桶/可疑后台)】'
    if ($Hits.Count -eq 0) {
        $lines += if ($degraded) { '  (当前未命中特征库，但扫描信息不完整，不能判断机器干净)' } else { '  (未命中特征库, 这台机器比较干净)' }
    } else {
        foreach ($h in $Hits) {
            $riskMark = switch ($h.risk) { 'high' { '!!' } 'medium' { '! ' } default { '  ' } }
            $nameSuffix = if ($h.name) { " ($($h.name))" } else { '' }
            $lines += ('  {0} [{1}] {2}{3}  [风险 {4}]' -f $riskMark, $h.vendor, $h.name_cn, $nameSuffix, (Convert-RiskToScore $h.risk))
            $lines += ('      命中: {0}  |  {1}' -f $h.hit_type, $h.detail)
            $lines += ('      建议: {0}  |  安全: {1}' -f $h.action, $(if ($h.safe) { '是' } else { '否-谨慎' }))
            # v1.3: evidence 显示
            if ($h.evidence -and $h.evidence.tested) {
                $models = @($h.evidence.tested_models) -join ','
                $lines += ('      实测: 是 ({0} 台, {1}, {2})' -f $h.evidence.tested_count, $models, $h.evidence.last_verified)
            } elseif ($h.evidence) {
                $lines += '      实测: 否 (参考规则, 谨慎对待)'
            }
            $lines += ('      原因: {0}' -f $h.reason_cn)
        }
    }
    $lines += ''

    $lines += '【8. 手动启动却正在运行的服务 (可能被其他组件拉起, 禁用不一定立即停止)】'
    $trig = @($Services | Where-Object { $_.TriggerHint })
    if ($trig.Count -eq 0) {
        $lines += '  (无)'
    } else {
        foreach ($t in $trig) {
            $lines += ('  {0} | {1}' -f $t.Name, $t.DisplayName)
        }
    }
    $lines += ''

    $lines += '【9. 处理原则 (别乱动)】'
    $notes = (Load-Profiles).keep_notes_cn
    foreach ($n in $notes) { $lines += ('  - ' + $n) }
    $lines += ''
    $lines += ('待处理清单已保存: {0}' -f $script:PendingFile)
    $lines += '确认无误后, 用管理员身份运行: cpu-cleaner.ps1 -Mode clean'
    $lines += ''

    return ($lines -join "`r`n")
}

# ---------- 8b. HTML 报告 (v1.5.2: 与文本报告对齐 — Top CPU 含风险评分/依据, 新增风险分级汇总/计划任务/evidence) ----------
function Write-HtmlReport {
    param($SysInfo, $TopProcs, $Suspicious, $AutoStarts, $Tasks, $Hits, $AutoStartNames, $ScanHealth = $script:ScanHealth, $ScanWarnings = $script:ScanWarnings)

    $esc = { param($s) ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') }
    $degraded = Test-ScanHealthDegraded $ScanHealth
    $ramText = if ($SysInfo.RAM_GB -is [ValueType] -and [double]$SysInfo.RAM_GB -ge 0) { '{0} GB' -f $SysInfo.RAM_GB } else { [string]$SysInfo.RAM_GB }
    $loadText = if ($SysInfo.CPU_Load -is [ValueType] -and [double]$SysInfo.CPU_Load -ge 0) { '{0}%' -f $SysInfo.CPU_Load } else { [string]$SysInfo.CPU_Load }
    $healthBanner = ''
    if ($degraded) {
        $healthBanner = '<div class="warning"><strong>扫描信息不完整：</strong>部分分类使用兼容采集，不能据此判断机器干净。<ul>'
        foreach ($warning in @($ScanWarnings)) { $healthBanner += '<li>' + (& $esc $warning) + '</li>' }
        $healthBanner += '</ul></div>'
    }

    $sec1 = "<h2>1. 系统概况</h2><table><tr><th>电脑</th><td>$(& $esc $SysInfo.Model)</td></tr><tr><th>CPU</th><td>$(& $esc $SysInfo.CPU)</td></tr><tr><th>核心</th><td>$($SysInfo.Cores) 核 / $($SysInfo.Threads) 线程 / 内存 $ramText</td></tr><tr><th>当前负载</th><td><b>$loadText</b></td></tr><tr><th>开机</th><td>$($SysInfo.BootTime) (已运行 $($SysInfo.Uptime))</td></tr></table>"

    # v1.4 风险评分 (与文本报告同源)
    $procScores = @{}
    foreach ($p in $TopProcs) {
        $procScores[$p.PID] = Get-ProcessRiskScore -proc $p -ProfileHits $Hits -AutoStartNames $AutoStartNames -TopProcs $TopProcs
    }

    $sec2 = '<h2>2. Top CPU 进程 (v1.5.7 多次采样)</h2><table><tr><th>PID</th><th>进程</th><th>平均%</th><th>峰值%</th><th>持续</th><th>子进程</th><th>内存MB</th><th>风险分</th><th>级别</th><th>评分依据</th></tr>'
    foreach ($p in $TopProcs) {
        $s = $procScores[$p.PID]
        $lvlClass = switch ($s.Level) { '高度建议处理' { 'high' } '可优化' { 'medium' } default { '' } }
        $sec2 += "<tr><td>$($p.PID)</td><td>$(& $esc $p.Name)</td><td>$($p.'CPU%')</td><td>$($p.CPUPeak)</td><td>$($p.SamplesHigh)/$($p.Samples)</td><td>$($p.ChildCount)</td><td>$($p.MemMB)</td><td>$($s.Score)</td><td class=`"$lvlClass`">$(& $esc $s.Level)</td><td>$(& $esc $s.Reasons)</td></tr>"
    }
    $sec2 += '</table>'

    $sec3 = '<h2>3. 风险分级汇总</h2><table><tr><th>级别</th><th>数量</th></tr>'
    $summary = @{ '正常' = 0; '建议观察' = 0; '可优化' = 0; '高度建议处理' = 0 }
    foreach ($p in $TopProcs) { $summary[$procScores[$p.PID].Level]++ }
    foreach ($k in '正常','建议观察','可优化','高度建议处理') {
        $sec3 += "<tr><td>$k</td><td>$($summary[$k])</td></tr>"
    }
    $sec3 += '</table><p class="note">(评分说明: +30特征库 +20非系统目录 +15开机自启 +15高CPU +10无签名/同目录多进程; -40微软签名 -30System32 -25驱动)</p>'

    $sec4 = '<h2>4. 未知高占用进程</h2>'
    if ($Suspicious.Count -eq 0) { $sec4 += '<p>无 - 高占用进程均正常</p>' }
    else {
        $sec4 += '<table><tr><th>PID</th><th>进程</th><th>CPU%</th><th>原因</th></tr>'
        foreach ($s in $Suspicious) { $sec4 += "<tr><td>$($s.PID)</td><td>$(& $esc $s.Name)</td><td>$($s.'CPU%')</td><td>$(& $esc $s.Reason)</td></tr>" }
        $sec4 += '</table>'
    }

    $sec5 = '<h2>5. 开机自启动项</h2><table><tr><th>来源</th><th>名称</th><th>命令</th></tr>'
    foreach ($a in $AutoStarts) { $sec5 += "<tr><td>$(& $esc $a.Source)</td><td>$(& $esc $a.Name)</td><td>$(& $esc $a.Value)</td></tr>" }
    $sec5 += '</table>'

    $sec6 = '<h2>6. 登录/开机触发的计划任务</h2>'
    $loginTasks = @($Tasks | Where-Object { $_.LoginTrigger })
    if ($loginTasks.Count -eq 0) { $sec6 += '<p>无</p>' }
    else {
        $sec6 += '<table><tr><th>路径</th><th>名称</th><th>状态</th></tr>'
        foreach ($t in $loginTasks) { $sec6 += "<tr><td>$(& $esc $t.TaskPath)</td><td>$(& $esc $t.TaskName)</td><td>$($t.State)</td></tr>" }
        $sec6 += '</table>'
    }

    $sec7 = '<h2>7. 特征库命中 (预装全家桶/可疑后台)</h2>'
    if ($Hits.Count -eq 0) { $sec7 += $(if ($degraded) { '<p>当前未命中特征库，但扫描信息不完整，不能判断机器干净。</p>' } else { '<p>未命中特征库</p>' }) }
    else {
        $sec7 += '<table><tr><th>风险</th><th>厂商</th><th>名称</th><th>命中</th><th>建议</th><th>实测</th><th>原因</th></tr>'
        foreach ($h in $Hits) {
            $rm = switch ($h.risk) { 'high' { '高' } 'medium' { '中' } default { '低' } }
            $ev = if ($h.evidence -and $h.evidence.tested) { ('是 ({0} 台)' -f $h.evidence.tested_count) } elseif ($h.evidence) { '否 (参考规则)' } else { '—' }
            $sec7 += "<tr><td>$rm</td><td>$($h.vendor)</td><td>$(& $esc $h.name_cn)</td><td>$($h.hit_type)</td><td>$($h.action)</td><td>$ev</td><td>$(& $esc $h.reason_cn)</td></tr>"
        }
        $sec7 += '</table>'
    }

    $notes = (Load-Profiles).keep_notes_cn
    $sec8 = '<h2>8. 处理原则</h2><ul>'
    foreach ($n in $notes) { $sec8 += "<li>$(& $esc $n)</li>" }
    $sec8 += '</ul>'

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
.note{color:#666;font-size:12px}
.warning{background:#fff4db;border:1px solid #e0a52b;padding:12px 16px;margin:16px 0;color:#6b4700}
.high{color:#c0392b;font-weight:bold}.medium{color:#b9770e}
</style></head><body>
<h1>CPU 后台诊断报告</h1>
<div class="meta">生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; CPU 后台整理工具 v$($script:Version)</div>
$healthBanner$sec1$sec2$sec3$sec4$sec5$sec6$sec7$sec8
</body></html>
"@
    return $html
}

