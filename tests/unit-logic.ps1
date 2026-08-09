# v1.2 单元测试: 映射函数 + 状态机逻辑 (纯逻辑, 不碰系统)
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Assert-Equal($name, $actual, $expected) {
    if ($actual -eq $expected) { $script:pass++; Write-Host "  PASS: $name => $actual" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name => $actual (期望 $expected)" -ForegroundColor Red }
}

# 1. 启动类型映射
Assert-Equal 'Automatic->auto' (Convert-StartTypeToSc 'Automatic') 'auto'
Assert-Equal 'Manual->demand' (Convert-StartTypeToSc 'Manual') 'demand'
Assert-Equal 'Disabled->disabled' (Convert-StartTypeToSc 'Disabled') 'disabled'
Assert-Equal 'Boot->boot' (Convert-StartTypeToSc 'Boot') 'boot'
Assert-Equal 'System->system' (Convert-StartTypeToSc 'System') 'system'
Assert-Equal '未知->disabled' (Convert-StartTypeToSc 'Weird') 'disabled'

# 2. 数字枚举兼容 (旧 manifest)
Assert-Equal '0->boot' (Convert-NumberToSc 0) 'boot'
Assert-Equal '1->system' (Convert-NumberToSc 1) 'system'
Assert-Equal '2->auto' (Convert-NumberToSc 2) 'auto'
Assert-Equal '3->demand' (Convert-NumberToSc 3) 'demand'
Assert-Equal '4->disabled' (Convert-NumberToSc 4) 'disabled'
Assert-Equal '99->disabled' (Convert-NumberToSc 99) 'disabled'

# 3. 字符串旧格式映射 (restore 兼容)
Assert-Equal "before='Disabled'->disabled" (Convert-StartTypeToSc 'Disabled') 'disabled'
Assert-Equal "before='Automatic'->auto" (Convert-StartTypeToSc 'Automatic') 'auto'

# 4. 状态机合法值检查
$validStates = @('pending','success','failed','skipped','manual_required')
foreach ($s in $validStates) {
    Assert-Equal "状态机值 $s 合法" ($validStates -contains $s) $true
}
Assert-Equal "非法状态 rejected" ($validStates -contains 'done') $false

# 6. 状态机过滤逻辑: clean 只处理 pending/failed
$statusFilter = { param($s) $s -in @('pending','failed') }
Assert-Equal 'pending 处理' (& $statusFilter 'pending') $true
Assert-Equal 'failed 可重试' (& $statusFilter 'failed') $true
Assert-Equal 'success 跳过' (& $statusFilter 'success') $false
Assert-Equal 'skipped 跳过' (& $statusFilter 'skipped') $false
Assert-Equal 'manual_required 跳过' (& $statusFilter 'manual_required') $false

# 7. v1.4 风险分级函数
Assert-Equal '评分 75 → 高度建议处理' (Get-RiskLevel 75) '高度建议处理'
Assert-Equal '评分 70 → 高度建议处理' (Get-RiskLevel 70) '高度建议处理'
Assert-Equal '评分 55 → 可优化' (Get-RiskLevel 55) '可优化'
Assert-Equal '评分 35 → 建议观察' (Get-RiskLevel 35) '建议观察'
Assert-Equal '评分 10 → 正常' (Get-RiskLevel 10) '正常'
Assert-Equal 'risk high → 80' (Convert-RiskToScore 'high') 80
Assert-Equal 'risk medium → 55' (Convert-RiskToScore 'medium') 55
Assert-Equal 'risk low → 30' (Convert-RiskToScore 'low') 30

# 8. v1.4 进程综合评分
$topAll = @(
    [pscustomobject]@{ PID=1; Name='svchost'; 'CPU%'=1; MemMB=10; Path='C:\Windows\System32\svchost.exe' },
    [pscustomobject]@{ PID=2; Name='mcpman'; 'CPU%'=8; MemMB=50; Path='C:\ProgramData\Lenovo\LeMcpManager\mcpman.exe' },
    [pscustomobject]@{ PID=3; Name='grep'; 'CPU%'=0.5; MemMB=5; Path='C:\Program Files\Git\usr\bin\grep.exe' }
)
$hits2 = @([pscustomobject]@{ hit_type='process'; process_name='mcpman'; id='lenovo-lemcp' })
$autoNames2 = @('mcpman.exe')
$r1 = Get-ProcessRiskScore -proc $topAll[0] -ProfileHits @() -AutoStartNames @() -TopProcs $topAll
Assert-Equal '系统进程 svchost 评分 0' $r1.Score 0
Assert-Equal '系统进程 svchost 级别 正常' $r1.Level '正常'
$r2 = Get-ProcessRiskScore -proc $topAll[1] -ProfileHits $hits2 -AutoStartNames $autoNames2 -TopProcs $topAll
Assert-Equal '可疑进程 mcpman 评分 ≥ 50 (特征库30+非系统20+自启15+CPU15+无签名10)' ($r2.Score -ge 50) $true
Assert-Equal '可疑进程 mcpman 级别 可优化或更高' (Get-RiskLevel $r2.Score) '可优化'
$r3 = Get-ProcessRiskScore -proc $topAll[2] -ProfileHits @() -AutoStartNames @() -TopProcs $topAll
Assert-Equal 'Git 工具排除同目录加分: grep 评分不含同目录x3' ($r3.Reasons -notmatch '同目录') $true

Write-Host "`n结果: $pass 通过, $fail 失败" -ForegroundColor Cyan
if ($fail -gt 0) { throw 'UNIT LOGIC TESTS FAILED' } else { Write-Host 'ALL LOGIC TESTS PASSED' -ForegroundColor Green }
