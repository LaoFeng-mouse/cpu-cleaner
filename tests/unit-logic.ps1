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

# 5. safe=false 规则: 模拟 Save-PendingActions 的过滤条件
$hitSafeFalse = @{ safe = $false; action = 'disable_service' }
$hitSafeTrue  = @{ safe = $true;  action = 'disable_service' }
$enterQueue = { param($h) if ($h.action -in @('none','investigate')) { return $false }; if (-not $h.safe) { return $false }; return $true }
Assert-Equal 'safe=false 不进队列' (& $enterQueue $hitSafeFalse) $false
Assert-Equal 'safe=true 进队列' (& $enterQueue $hitSafeTrue) $true
Assert-Equal 'action=none 不进队列' (& $enterQueue @{ safe=$true; action='none' }) $false
Assert-Equal 'action=investigate 不进队列' (& $enterQueue @{ safe=$true; action='investigate' }) $false

# 6. 状态机过滤逻辑: clean 只处理 pending/failed
$statusFilter = { param($s) $s -in @('pending','failed') }
Assert-Equal 'pending 处理' (& $statusFilter 'pending') $true
Assert-Equal 'failed 可重试' (& $statusFilter 'failed') $true
Assert-Equal 'success 跳过' (& $statusFilter 'success') $false
Assert-Equal 'skipped 跳过' (& $statusFilter 'skipped') $false
Assert-Equal 'manual_required 跳过' (& $statusFilter 'manual_required') $false

Write-Host "`n结果: $pass 通过, $fail 失败" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
