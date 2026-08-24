# v1.3 单元测试: 特征库 Schema 2.0 校验 (Load-Profiles)
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Assert-Equal($name, $actual, $expected) {
    if ($actual -eq $expected) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name => $actual (期望 $expected)" -ForegroundColor Red }
}

# 测试 Load-Profiles 对给定 JSON 的加载结果
function Test-Load($name, $jsonContent, $expectOk) {
    $tmp = Join-Path $env:TEMP ("profile_test_" + [guid]::NewGuid().ToString('N') + ".json")
    [System.IO.File]::WriteAllText($tmp, $jsonContent, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $p = Load-Profiles -Path $tmp
        if ($expectOk) { $script:pass++; Write-Host "  PASS: $name (加载成功)" -ForegroundColor Green }
        else { $script:fail++; Write-Host "  FAIL: $name (期望拒绝却加载成功)" -ForegroundColor Red }
    } catch {
        if ($expectOk) { $script:fail++; Write-Host "  FAIL: $name (期望成功却拒绝: $($_.Exception.Message))" -ForegroundColor Red }
        else { $script:pass++; Write-Host "  PASS: $name (正确拒绝: $($_.Exception.Message.Split("`n")[0]))" -ForegroundColor Green }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

$validRule = '{
  "id": "test-rule", "vendor": "Test", "name_cn": "测试规则", "risk": "high", "safe": true,
  "reason_cn": "测试", 
  "detect": { "services": ["TestService"], "processes": [], "autostarts": [], "tasks": [] },
  "actions": { "service": "disable_service" }
}'

# 1. 合法 v2 加载成功
Test-Load '合法 v2 规则' ('{"schema_version": 2, "profiles": [' + $validRule + '], "keep_notes_cn": []}') $true

# 2. id 重复 → 拒绝
Test-Load 'id 重复' ('{"schema_version": 2, "profiles": [' + $validRule + ',' + $validRule + ']}') $false

# 3. risk 非法 → 拒绝
Test-Load 'risk 非法' ('{"schema_version": 2, "profiles": [' + ($validRule -replace '"high"', '"extreme"') + ']}') $false

# 4. action 非法 → 拒绝
Test-Load 'action 非法' ('{"schema_version": 2, "profiles": [' + ($validRule -replace 'disable_service', 'format_disk') + ']}') $false

# 5. detect 全空 → 拒绝
Test-Load 'detect 全空' ('{"schema_version": 2, "profiles": [' + ($validRule -replace '"services": \["TestService"\], "processes": \[\]', '"services": [], "processes": []') + ']}') $false

# 6. safe=false + 危险 action → 拒绝
Test-Load 'safe=false 配危险动作' ('{"schema_version": 2, "profiles": [' + ($validRule -replace '"safe": true', '"safe": false') + ']}') $false

# 7. schema_version 过高 → 拒绝
Test-Load 'schema_version=99 过高' ('{"schema_version": 99, "profiles": [' + $validRule + ']}') $false

# 8. schema_version=1 过低 → 拒绝
Test-Load 'schema_version=1 过低' ('{"schema_version": 1, "profiles": [' + $validRule + ']}') $false

# 9. 旧格式 v1 (无 schema_version) 自动转换 → 成功
Test-Load 'v1 旧格式自动转换' '{"profiles": [{"id":"old-rule","vendor":"Old","name":"Old Rule","name_cn":"旧规则","type":"service","match":["OldService"],"risk":"medium","action":"disable_service","safe":true,"reason_cn":"旧"}]}' $true

# 10. v1 转换后字段正确
$tmp2 = Join-Path $env:TEMP ("profile_test_" + [guid]::NewGuid().ToString('N') + ".json")
[System.IO.File]::WriteAllText($tmp2, '{"profiles": [{"id":"old-rule","vendor":"Old","name":"Old Rule","name_cn":"旧规则","type":"service","match":["OldService"],"risk":"medium","action":"disable_service","safe":true,"reason_cn":"旧"}]}', (New-Object System.Text.UTF8Encoding($false)))
$converted = Load-Profiles -Path $tmp2
Remove-Item $tmp2 -ErrorAction SilentlyContinue
Assert-Equal 'v1 转换: schema_version=3' $converted.schema_version 3
Assert-Equal 'v1 转换: detect.services[0].match=OldService' @($converted.profiles[0].detect.services)[0].match 'OldService'
Assert-Equal 'v1 转换: actions.service=investigate(降级)' $converted.profiles[0].actions.service 'investigate'

# 11. 生产 HRWSCCtrl 规则必须使用一次性、仅手动的服务进程停止合同
$productionProfiles = Load-Profiles -Path (Join-Path $projectRoot 'bloatware-profiles.json')
$hrwscctrl = @($productionProfiles.profiles | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
Assert-Equal 'HRWSCCtrl 规则存在' ($null -ne $hrwscctrl) $true
Assert-Equal 'HRWSCCtrl safe=false' $hrwscctrl.safe $false
Assert-Equal 'HRWSCCtrl actions.service=none' $hrwscctrl.actions.service 'none'
Assert-Equal 'HRWSCCtrl actions.process=none' $hrwscctrl.actions.process 'none'
Assert-Equal 'HRWSCCtrl manual service=stop_service_process' $hrwscctrl.manual_actions.service 'stop_service_process'
Assert-Equal 'HRWSCCtrl manual_impact' $hrwscctrl.cleanup_policy.execution_class 'manual_impact'
Assert-Equal 'HRWSCCtrl default_selected=false' $hrwscctrl.cleanup_policy.default_selected $false
Assert-Equal 'HRWSCCtrl requires_confirmation=true' $hrwscctrl.cleanup_policy.requires_confirmation $true
Assert-Equal 'HRWSCCtrl exact matcher first' @($hrwscctrl.detect.services)[0].type 'exact'
Assert-Equal 'HRWSCCtrl contains fallback second' @($hrwscctrl.detect.services)[1].type 'contains'

$manualStopRule = '{
  "id":"manual-stop","vendor":"T","name_cn":"手动结束服务进程","risk":"low","safe":false,
  "reason_cn":"仅手动处理","evidence":{"tested":true},
  "detect":{"services":[{"match":"Svc","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},
  "actions":{"service":"none"},"manual_actions":{"service":"stop_service_process"},
  "cleanup_policy":{"execution_class":"manual_impact","necessity":"optional","default_selected":false,"requires_confirmation":true,"impact_cn":"只结束当前实例","cleanup_reason_cn":"减少当前后台"}
}'
Test-Load '合法 stop_service_process 手动合同' ('{"schema_version":3,"profiles":[' + $manualStopRule + ']}') $true
Test-Load 'stop_service_process 拒绝 actions.service' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"service":"none"},"manual_actions":\{"service":"stop_service_process"\}', '"service":"stop_service_process"},"manual_actions":{"service":"none"}') + ']}') $false
Test-Load 'stop_service_process 拒绝 automatic_safe' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"execution_class":"manual_impact"', '"execution_class":"automatic_safe"') + ']}') $false
Test-Load 'stop_service_process 拒绝 tested=false' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"tested":true', '"tested":false') + ']}') $false
Test-Load 'stop_service_process 拒绝 default_selected=true' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"default_selected":false', '"default_selected":true') + ']}') $false
Test-Load 'stop_service_process 拒绝 requires_confirmation=false' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"requires_confirmation":true', '"requires_confirmation":false') + ']}') $false

Write-Host "`n结果: $pass 通过, $fail 失败" -ForegroundColor Cyan
if ($fail -gt 0) { throw 'SCHEMA TESTS FAILED' } else { Write-Host 'ALL SCHEMA TESTS PASSED' -ForegroundColor Green }
