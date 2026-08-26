# v1.3 单元测试: 特征库 Schema 2.0 校验 (Load-Profiles)
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Assert-Equal($name, $actual, $expected) {
    if ($actual -eq $expected) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name => $actual (期望 $expected)" -ForegroundColor Red }
}
function Assert-Match($name, $actual, $pattern) {
    if ([string]$actual -match $pattern) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name => 未匹配 $pattern" -ForegroundColor Red }
}
function Assert-NotMatch($name, $actual, $pattern) {
    if ([string]$actual -notmatch $pattern) { $script:pass++; Write-Host "  PASS: $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL: $name => 不应匹配 $pattern" -ForegroundColor Red }
}
function Get-ChangelogVersionBlock($text, $version) {
    $escapedVersion = [regex]::Escape([string]$version)
    $match = [regex]::Match([string]$text, "(?ms)^## \[$escapedVersion\][^\r\n]*\r?\n.*?(?=^## \[|\z)")
    if (-not $match.Success) { return '' }
    return $match.Value
}
function Test-GuiSafeResultContract($text) {
    $required = 'GUI[\s\S]{0,120}(只|仅)显示[\s\S]{0,160}严格验证[\s\S]{0,80}安全净化[\s\S]{0,100}`?result_reason`?[\s/、,，]+`?failure_stage`?'
    $unsafe = 'GUI[\s\S]{0,160}(同时|还会|并会)[\s\S]{0,80}(原始异常|原始路径|token|堆栈)'
    return ([string]$text -match $required) -and ([string]$text -notmatch $unsafe)
}
function Test-ChangelogNoUnsupportedCompletionClaim($text) {
    $unsupported = '(真实机器验收|真实验收)[^\r\n]{0,30}(?<!未)(通过|完成|成功)|(?<!未)(通过|完成|成功)[^\r\n]{0,30}(真实机器验收|真实验收)|(?<!未)已(发布|推送)|真实清理[^\r\n]{0,30}(?<!未)(成功|完成)|(?<!未)(成功|完成)[^\r\n]{0,30}真实清理'
    return [string]$text -notmatch $unsupported
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

# 12. v1.8.1 文档分别承担自己的用户、安全与历史契约，禁止跨文档拼接代答
$cleanerText = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$readmeText = Get-Content (Join-Path $projectRoot 'README.md') -Raw -Encoding UTF8
$securityText = Get-Content (Join-Path $projectRoot 'SECURITY.md') -Raw -Encoding UTF8
$changelogText = Get-Content (Join-Path $projectRoot 'CHANGELOG.md') -Raw -Encoding UTF8
$changelog181 = Get-ChangelogVersionBlock $changelogText '1.8.1'

Assert-Match '版本精确为 1.8.1' $cleanerText '(?m)^\$script:Version = ''1\.8\.1''$'
Assert-Match '脚本标题版本精确为 1.8.1' $cleanerText '(?m)^#  CPU 后台整理工具 v1\.8\.1 \(cpu-cleaner\.ps1\)'

# README：用户行为与可见结果
Assert-Match 'README 明确 HRWSCCtrl 使用 stop_service_process' $readmeText '`?HRWSCCtrl`?[\s\S]{0,180}`?manual_actions\.service=stop_service_process`?'
Assert-Match 'README 明确默认不选和二次确认' $readmeText 'HRWSCCtrl[\s\S]{0,240}默认不选[\s\S]{0,100}二次确认'
Assert-Match 'README 明确一次性不可恢复且 StartMode 不变' $readmeText 'stop_service_process[\s\S]{0,180}(一次性|非持久)[\s\S]{0,160}不可.{0,20}恢复包.{0,20}恢复[\s\S]{0,500}不修改 `?StartMode`?|不修改 `?StartMode`?[\s\S]{0,500}stop_service_process[\s\S]{0,180}(一次性|非持久)[\s\S]{0,160}不可.{0,20}恢复包.{0,20}恢复'
Assert-Match 'README 明确约 5 秒与正 replacement PID 失败' $readmeText '旧 PID[\s\S]{0,100}约 5 秒[\s\S]{0,160}任意正 replacement PID[\s\S]{0,120}`?failed/verification`?'
Assert-Equal 'README GUI 仅显示严格验证和净化后的安全字段' (Test-GuiSafeResultContract $readmeText) $true
Assert-Match 'README 明确 30 秒真实机器验收待完成' $readmeText '(还需要|仍待)[^\r\n]{0,40}30 秒真实机器验收'
Assert-NotMatch 'README 禁止 HRWSCCtrl 绑定 disable_service' $readmeText '(?i)HRWSCCtrl[^\r\n]{0,240}(manual_actions\.service=disable_service|通过[^\r\n]{0,80}disable_service|尝试禁用|禁用它)|disable_service[^\r\n]{0,160}HRWSCCtrl'

# SECURITY：信任边界、失败关闭与安全展示
Assert-Match 'SECURITY 明确六字段执行前复验' $securityText '执行前复验服务/路径/PID/进程名/进程路径/启动时间'
Assert-Match 'SECURITY 身份漂移失败关闭' $securityText '(任一|任何).{0,30}(变化|不一致)[^\r\n]{0,80}(拒绝|失败关闭|重新扫描)'
Assert-Match 'SECURITY replacement PID 失败关闭' $securityText '任意正 replacement PID[\s\S]{0,100}`?failed/verification`?'
Assert-Equal 'SECURITY GUI 仅显示严格验证和净化后的安全字段' (Test-GuiSafeResultContract $securityText) $true
Assert-Match 'SECURITY 自动测试不等同真实验收' $securityText '自动测试不等同真实机器验收'

# CHANGELOG：只审查 1.8.1，旧版本历史措辞不参与发布契约
Assert-Match 'CHANGELOG 1.8.1 区块存在' $changelog181 '(?m)^## \[1\.8\.1\]'
Assert-Match 'CHANGELOG 1.8.1 记录真实故障和修复' $changelog181 '\*\*真实故障\*\*[\s\S]{0,500}\*\*最小修复\*\*'
Assert-Match 'CHANGELOG 1.8.1 记录 restart 检测和结果字段' $changelog181 '\*\*重启检测\*\*[\s\S]{0,500}`?result_reason`?[\s/、,，]+`?failure_stage`?'
Assert-Match 'CHANGELOG 1.8.1 记录持久动作安全恢复边界' $changelog181 '`?disable_service`?[\s/、,，]+`?remove_autostart`?[\s/、,，]+`?disable_task`?[\s\S]{0,160}(备份.{0,30}恢复|可恢复)'
Assert-Match 'CHANGELOG 1.8.1 明确真实操作未执行且验收待人工' $changelog181 '没有执行真实清理或 UAC[\s\S]{0,300}30 秒真实机器验收仍待人工执行'
Assert-Match 'CHANGELOG 1.8.1 明确未发布未推送未验收' $changelog181 '不宣称已经验收、发布或推送'
Assert-Equal 'CHANGELOG 1.8.1 禁止无否定上下文的完成声称' (Test-ChangelogNoUnsupportedCompletionClaim $changelog181) $true

# 反例必须失败，证明安全 GUI 与未验收契约不是只检查关键词存在
$unsafeGuiFixture = 'GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时显示原始异常、路径、token、堆栈。'
Assert-Equal 'GUI 安全字段契约拒绝原始异常泄漏反例' (Test-GuiSafeResultContract $unsafeGuiFixture) $false
$unsupportedReleaseFixture = "## [1.8.1] - 2026-08-26`n真实机器验收完成，已发布并已推送；真实清理成功。"
Assert-Equal 'CHANGELOG 契约拒绝完成发布反例' (Test-ChangelogNoUnsupportedCompletionClaim $unsupportedReleaseFixture) $false
$reverseUnsupportedReleaseFixture = '已完成真实机器验收。'
Assert-Equal 'CHANGELOG 契约拒绝前置完成语序反例' (Test-ChangelogNoUnsupportedCompletionClaim $reverseUnsupportedReleaseFixture) $false
$negativeReleaseFixture = '真实机器验收仍待人工执行，未发布、未推送，不宣称已经验收。'
Assert-Equal 'CHANGELOG 契约允许明确否定的发布验收措辞' (Test-ChangelogNoUnsupportedCompletionClaim $negativeReleaseFixture) $true

Write-Host "`n结果: $pass 通过, $fail 失败" -ForegroundColor Cyan
if ($fail -gt 0) { throw 'SCHEMA TESTS FAILED' } else { Write-Host 'ALL SCHEMA TESTS PASSED' -ForegroundColor Green }
