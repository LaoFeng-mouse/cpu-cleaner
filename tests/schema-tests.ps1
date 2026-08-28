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
function Get-ReadmeCurrentReleaseContract($text) {
    $sections = @()
    $lines = @([string]$text -split '\r?\n')
    $itemLines = @()
    $pendingBlankLines = @()
    $itemIndent = -1

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($itemIndent -lt 0) {
            $startMatch = [regex]::Match($line, '^(\s*)-\s+v1\.8\.1（(?:待发布|未发布)')
            if ($startMatch.Success) {
                $itemIndent = $startMatch.Groups[1].Value.Length
                $itemLines = @($line)
                $pendingBlankLines = @()
            }
            continue
        }

        if ($line -match '^\s*$') {
            $pendingBlankLines += $line
            continue
        }

        $headingMatch = [regex]::Match($line, '^(\s*)#{1,6}\s+')
        $listMatch = [regex]::Match($line, '^(\s*)[-*+]\s+')
        $indentMatch = [regex]::Match($line, '^(\s*)')
        $endsItem = ($headingMatch.Success -and
                $headingMatch.Groups[1].Value.Length -le $itemIndent) -or
            ($listMatch.Success -and
                $listMatch.Groups[1].Value.Length -le $itemIndent) -or
            ($indentMatch.Groups[1].Value.Length -le $itemIndent)

        if ($endsItem) {
            $sections += ($itemLines -join "`n")
            $itemIndent = -1
            $itemLines = @()
            $pendingBlankLines = @()
            continue
        }

        if ($pendingBlankLines.Count -gt 0) {
            $itemLines += $pendingBlankLines
            $pendingBlankLines = @()
        }
        $itemLines += $line
    }
    if ($itemIndent -ge 0) {
        $sections += ($itemLines -join "`n")
    }

    foreach ($paragraph in @([regex]::Split([string]$text, '(?:\r?\n){2,}'))) {
        if ($paragraph -match '自动测试' -and
            $paragraph -match 'HRWSCCtrl' -and
            $paragraph -match '30 秒真实机器验收') {
            $sections += [string]$paragraph
        }
    }
    return $sections -join "`n`n"
}
function Test-GuiSafeResultContract($text) {
    $requiredFound = $false
    $previousWasContract = $false
    $leakTerms = '(?:额外字段|调试详情|原始异常(?:路径)?|token|堆栈|临时文件绝对路径|未经(?:严格)?验证(?:的)?(?:结果)?(?:字段|路径)?|未经(?:安全)?净化(?:的)?结果(?:字段|路径)?)'
    foreach ($sentence in @([string]$text -split '[。！？!?\r\n]+')) {
        $normalized = [regex]::Replace([string]$sentence, '[\s，,；;。：:、/`]+', '')
        if (-not $normalized) { continue }

        $isContract = $normalized -match 'GUI' -and
            $normalized -match 'result_reason' -and
            $normalized -match 'failure_stage'
        if ($isContract -and
            $normalized -match 'GUI(?:只|仅)显示.*严格验证.*安全净化.*result_reason.*failure_stage') {
            $requiredFound = $true
        }

        if ($normalized -match 'GUI不(?:会)?(?:显示|展示).*(?:未经(?:严格)?验证|未经(?:安全)?净化)') {
            $previousWasContract = $false
            continue
        }
        $extraDisplay = $normalized -match '(?:同时|另外|还会|并会|也会)(?:显示|展示)'
        $directLeakDisplay = $normalized -match "(?:显示|展示).*$leakTerms"
        $isGuiResultSentence = $isContract -or $previousWasContract -or $normalized -match 'GUI'
        if ($isGuiResultSentence -and $normalized -match $leakTerms -and
            ($extraDisplay -or $directLeakDisplay)) {
            return $false
        }
        $previousWasContract = $isContract
    }
    return $requiredFound
}
function Test-NoUnsupportedCompletionClaim($text) {
    $positiveSignals = '(?:已经|现已|已|正式|对外|完成|成功|通过)'
    $negativeSignals = '(?:尚未|没有|未能|不宣称|不代表|不等同|不能替代|仍待人工|仍待|等待|待人工|未)'
    $claimSubjects = @(
        '(?:正式发布|发布)',
        '推送',
        '(?:真实机器验收|真实验收|真实UAC验收|UAC验收|真实UAC|30秒(?:真实机器|实机)?验收)',
        '真实清理'
    )

    foreach ($clause in @([string]$text -split '[\r\n。！？；;.!?]+')) {
        $normalized = [regex]::Replace([string]$clause, '[\s，,：:、/`()（）\[\]\*#_-]+', '')
        if (-not $normalized) { continue }

        # “不宣称”可以语法上同时约束明确列出的多个 subject；除此以外，
        # 每个否定词只删除它直接修饰的同一 subject，不能跨过另一个 claim。
        $coordinatedNegative = '不宣称(?:已经|现已|已)?(?:真实机器验收|真实验收|验收|发布|推送)(?:(?:或)?(?:真实机器验收|真实验收|验收|发布|推送))+'
        $remaining = [regex]::Replace($normalized, $coordinatedNegative, '')

        foreach ($subject in $claimSubjects) {
            $negativeBefore = "(?:目标版本.{0,12})?$negativeSignals(?:已经|现已|已|正式|对外|完成|成功|通过|执行){0,2}$subject(?:完成|成功|通过|执行)?"
            $negativeAfter = "$subject$negativeSignals(?:完成|成功|通过|执行)?"
            $remaining = [regex]::Replace($remaining, $negativeBefore, '')
            $remaining = [regex]::Replace($remaining, $negativeAfter, '')
        }

        foreach ($subject in $claimSubjects) {
            if ($remaining -match "$positiveSignals.{0,16}$subject|$subject.{0,16}$positiveSignals") {
                return $false
            }
        }
    }
    return $true
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

# 11. 生产 HRWSCCtrl 规则声明官方卸载意图，并由 ProfileEngine 按可信 PPL 证据分流
$productionProfiles = Load-Profiles -Path (Join-Path $projectRoot 'bloatware-profiles.json')
$hrwscctrl = @($productionProfiles.profiles | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
Assert-Equal 'HRWSCCtrl 规则存在' ($null -ne $hrwscctrl) $true
Assert-Equal 'HRWSCCtrl safe=false' $hrwscctrl.safe $false
Assert-Equal 'HRWSCCtrl actions.service=none' $hrwscctrl.actions.service 'none'
Assert-Equal 'HRWSCCtrl actions.process=none' $hrwscctrl.actions.process 'none'
Assert-Equal 'HRWSCCtrl manual service=open_official_uninstaller' $hrwscctrl.manual_actions.service 'open_official_uninstaller'
Assert-Equal 'HRWSCCtrl manual_impact' $hrwscctrl.cleanup_policy.execution_class 'manual_impact'
Assert-Equal 'HRWSCCtrl default_selected=false' $hrwscctrl.cleanup_policy.default_selected $false
Assert-Equal 'HRWSCCtrl requires_confirmation=true' $hrwscctrl.cleanup_policy.requires_confirmation $true
Assert-Equal 'HRWSCCtrl execution.allow_auto=false' $hrwscctrl.execution.allow_auto $false
Assert-Equal 'HRWSCCtrl execution.allow_auto 为 Boolean' ($hrwscctrl.execution.allow_auto -is [bool]) $true
Assert-Equal 'HRWSCCtrl manual-only review_note' $hrwscctrl.execution.review_note '仅允许用户确认后的官方卸载入口；不属于自动安全清理'
Assert-Equal 'HRWSCCtrl exact matcher first' @($hrwscctrl.detect.services)[0].type 'exact'
Assert-Equal 'HRWSCCtrl contains fallback second' @($hrwscctrl.detect.services)[1].type 'contains'

$manualStopRule = '{
  "id":"manual-stop","vendor":"T","name_cn":"手动结束服务进程","risk":"low","safe":false,
  "reason_cn":"仅手动处理","evidence":{"tested":true},
  "detect":{"services":[{"match":"Svc","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},
  "actions":{"service":"none"},"manual_actions":{"service":"stop_service_runtime"},
  "cleanup_policy":{"execution_class":"manual_impact","necessity":"optional","default_selected":false,"requires_confirmation":true,"impact_cn":"只结束当前实例","cleanup_reason_cn":"减少当前后台"}
}'
Test-Load '合法 stop_service_runtime 手动合同' ('{"schema_version":3,"profiles":[' + $manualStopRule + ']}') $true
Test-Load 'stop_service_runtime 拒绝 actions.service' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"service":"none"},"manual_actions":\{"service":"stop_service_runtime"\}', '"service":"stop_service_runtime"},"manual_actions":{"service":"none"}') + ']}') $false
Test-Load 'stop_service_runtime 拒绝 automatic_safe' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"execution_class":"manual_impact"', '"execution_class":"automatic_safe"') + ']}') $false
Test-Load 'stop_service_runtime 拒绝 tested=false' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"tested":true', '"tested":false') + ']}') $false
Test-Load 'stop_service_runtime 拒绝 default_selected=true' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"default_selected":false', '"default_selected":true') + ']}') $false
Test-Load 'stop_service_runtime 拒绝 requires_confirmation=false' ('{"schema_version":3,"profiles":[' + ($manualStopRule -replace '"requires_confirmation":true', '"requires_confirmation":false') + ']}') $false

$officialRule = $manualStopRule -replace 'stop_service_runtime', 'open_official_uninstaller'
Test-Load '合法 open_official_uninstaller 手动合同' ('{"schema_version":3,"profiles":[' + $officialRule + ']}') $true
Test-Load 'open_official_uninstaller 拒绝 actions.service' ('{"schema_version":3,"profiles":[' + ($officialRule -replace '"service":"none"},"manual_actions":\{"service":"open_official_uninstaller"\}', '"service":"open_official_uninstaller"},"manual_actions":{"service":"none"}') + ']}') $false
Test-Load 'open_official_uninstaller 拒绝 automatic_safe' ('{"schema_version":3,"profiles":[' + ($officialRule -replace '"execution_class":"manual_impact"', '"execution_class":"automatic_safe"') + ']}') $false
Test-Load 'open_official_uninstaller 拒绝 tested=false' ('{"schema_version":3,"profiles":[' + ($officialRule -replace '"tested":true', '"tested":false') + ']}') $false
Test-Load 'open_official_uninstaller 拒绝 necessity 非 optional' ('{"schema_version":3,"profiles":[' + ($officialRule -replace '"necessity":"optional"', '"necessity":"required"') + ']}') $false
Test-Load 'open_official_uninstaller 拒绝 process manual key' ('{"schema_version":3,"profiles":[' + ($officialRule -replace '"manual_actions":\{"service":"open_official_uninstaller"\}', '"manual_actions":{"process":"open_official_uninstaller"}') + ']}') $false

# 12. v1.8.1 文档分别承担自己的用户、安全与历史契约，禁止跨文档拼接代答
$cleanerText = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$readmeText = Get-Content (Join-Path $projectRoot 'README.md') -Raw -Encoding UTF8
$securityText = Get-Content (Join-Path $projectRoot 'SECURITY.md') -Raw -Encoding UTF8
$changelogText = Get-Content (Join-Path $projectRoot 'CHANGELOG.md') -Raw -Encoding UTF8
$identityPlanText = Get-Content (Join-Path $projectRoot 'docs\superpowers\plans\2026-08-26-privileged-service-process-identity-handoff.md') -Raw -Encoding UTF8
$changelogTarget181 = Get-ChangelogVersionBlock $changelogText 'Unreleased'

Assert-Match '版本精确为 1.8.1' $cleanerText '(?m)^\$script:Version = ''1\.8\.1''$'
Assert-Match '脚本标题版本精确为 1.8.1' $cleanerText '(?m)^#  CPU 后台整理工具 v1\.8\.1 \(cpu-cleaner\.ps1\)'

# README：用户行为与可见结果
Assert-Match 'README 顶部区分持久恢复与一次性不可恢复' $readmeText '(?m)^一键扫描[^\r\n]{0,180}持久化变更[^\r\n]{0,80}(自动备份|备份)[^\r\n]{0,40}可恢复[^\r\n]{0,80}一次性结束进程[^\r\n]{0,40}不可恢复'
Assert-Match 'README 明确 HRWSCCtrl 使用 stop_service_runtime' $readmeText '`?HRWSCCtrl`?[\s\S]{0,180}`?manual_actions\.service=stop_service_runtime`?'
Assert-Match 'README 明确默认不选和二次确认' $readmeText 'HRWSCCtrl[\s\S]{0,240}默认不选[\s\S]{0,100}二次确认'
Assert-Match 'README 明确一次性不可恢复且 StartMode 不变' $readmeText 'stop_service_runtime[\s\S]{0,180}(一次性|非持久)[\s\S]{0,160}不可.{0,20}恢复包.{0,20}恢复[\s\S]{0,500}不修改 `?StartMode`?|不修改 `?StartMode`?[\s\S]{0,500}stop_service_runtime[\s\S]{0,180}(一次性|非持久)[\s\S]{0,160}不可.{0,20}恢复包.{0,20}恢复'
Assert-Match 'README 明确约 5 秒与任意正服务 PID 失败' $readmeText '停止后[\s\S]{0,40}约 5 秒[\s\S]{0,160}任意正 PID[\s\S]{0,120}`?failed/verification`?'
Assert-Equal 'README GUI 仅显示严格验证和净化后的安全字段' (Test-GuiSafeResultContract $readmeText) $true
Assert-Match 'README 明确 30 秒真实机器验收待完成' $readmeText '(还需要|仍待)[^\r\n]{0,40}30 秒真实机器验收|30 秒真实机器验收[^\r\n]{0,40}仍待'
Assert-Match 'README 说明受保护 inventory v2 完整身份才可选' $readmeText 'inventory_schema_version:?\s*2[\s\S]{0,300}complete[\s\S]{0,180}HRWSCCtrl[\s\S]{0,180}(可选|勾选)'
Assert-Match 'README 说明 not_running 只观察并重新扫描' $readmeText 'not_running[\s\S]{0,160}(只观察|不可执行)[\s\S]{0,120}重新扫描'
Assert-Match 'README 说明 unavailable 只观察并重新扫描' $readmeText 'unavailable[\s\S]{0,160}(只观察|不可执行)[\s\S]{0,120}重新扫描'
Assert-NotMatch 'README 禁止 HRWSCCtrl 绑定 disable_service' $readmeText '(?i)HRWSCCtrl[^\r\n]{0,240}(manual_actions\.service=disable_service|通过[^\r\n]{0,80}disable_service|尝试禁用|禁用它)|disable_service[^\r\n]{0,160}HRWSCCtrl'
Assert-Match 'README 版本记录包含 v1.8.1 未发布与待验收' $readmeText '(?m)^- .*v1\.8\.1（(?:待发布|未发布)[^\r\n]*HRWSCCtrl[^\r\n]*30 秒[^\r\n]*(?:待人工|待验收|仍待)'
$readmeCurrent181 = Get-ReadmeCurrentReleaseContract $readmeText
Assert-Match 'README 当前区域包含 v1.8.1 待发布记录' $readmeCurrent181 '(?m)^- v1\.8\.1（待发布）'
Assert-NotMatch 'README 当前区域排除 v1.8.0 历史记录' $readmeCurrent181 '(?m)^- .*v1\.8\.0'
Assert-Equal 'README 当前区域禁止无否定上下文的完成声称' (Test-NoUnsupportedCompletionClaim $readmeCurrent181) $true

# SECURITY：信任边界、失败关闭与安全展示
Assert-Match 'SECURITY 明确六字段执行前复验' $securityText '执行前复验服务/路径/PID/进程名/进程路径/启动时间'
Assert-Match 'SECURITY 身份漂移失败关闭' $securityText '任何身份漂移[^\r\n]{0,120}`?skipped`?[^\r\n]{0,180}重新扫描'
Assert-Match 'SECURITY 服务重新出现正 PID 失败关闭' $securityText '出现任意正 PID[\s\S]{0,100}`?failed/verification`?'
Assert-Match 'SECURITY inventory v2 拒绝旧版未来版且不迁移' $securityText 'inventory_schema_version:?\s*2[\s\S]{0,220}(v1|旧版)[\s\S]{0,100}(未来|future|v3)[\s\S]{0,180}(重新扫描|fresh scan)[\s\S]{0,100}(不自动迁移|不静默迁移)'
Assert-Match 'SECURITY complete 使用真实受保护清单字段名' $securityText '(?m)^14\. \*\*服务进程身份状态机\*\*：[^\r\n]*`complete`[^\r\n]{0,180}(稳定运行 PID|运行中的稳定 PID)[^\r\n]{0,180}`ProcessName`[^\r\n]{0,100}`ProcessPath`[^\r\n]{0,100}`ProcessStartTimeUtc`'
Assert-NotMatch 'SECURITY complete 禁止不存在的 collector 字段名' $securityText '(?m)^14\. \*\*服务进程身份状态机\*\*：[^\r\n]*`process_started_utc`'
Assert-NotMatch 'SECURITY complete 不依赖 matcher 授权' $securityText '(?m)^14\. \*\*服务进程身份状态机\*\*：[^\r\n]*(?:`?service_name`?|`?exact`?)'
Assert-Match 'SECURITY not_running unavailable 仅观察不可执行' $securityText 'not_running[\s\S]{0,180}unavailable[\s\S]{0,220}(只观察|观察项)[\s\S]{0,120}(不可执行|不能执行)[\s\S]{0,120}重新扫描'
Assert-Match 'SECURITY 只读采集双服务快照和单记录隔离' $securityText '(只读|read-only)[\s\S]{0,260}(两次|两个|双)服务快照[\s\S]{0,260}(唯一进程身份|唯一身份)[\s\S]{0,300}(单条|每条|逐条)[\s\S]{0,140}(净化|sanitized)[\s\S]{0,120}unavailable[\s\S]{0,180}(其他记录|兄弟记录|同级记录)'
Assert-Match 'SECURITY marker 仅在可信包验证后附加且不序列化' $securityText 'ProcessIdentitySource[\s\S]{0,220}(可信包|受保护包|inventory 包)[\s\S]{0,120}(验证通过|验证成功|完成验证)[\s\S]{0,260}(不序列化|不得序列化)[\s\S]{0,120}(pending|执行子集|subset)'
Assert-Match 'SECURITY marker 执行动作失败关闭' $securityText 'ProcessIdentitySource[\s\S]{0,500}(带有|携带|含有).{0,40}(reviewed action|已复核动作|执行动作)[\s\S]{0,120}(失败关闭|拒绝执行)'
Assert-Match 'SECURITY 普通扫描消费可信证据与双快照' $securityText '(普通扫描|normal scan)[\s\S]{0,260}(不再需要|无需)[\s\S]{0,160}Win32_Process[\s\S]{0,80}ExecutablePath[\s\S]{0,300}(可信证据|受信证据)[\s\S]{0,160}(两次|两个|双)服务快照'
Assert-Match 'SECURITY 只有 exact service_name 授权服务进程停止' $securityText 'stop_service_runtime[\s\S]{0,260}exact[\s\S]{0,100}service_name[\s\S]{0,280}(显示名|display.?name)[\s\S]{0,180}(contains|regex)[\s\S]{0,180}(不授权|不能授权|不得授权)'
Assert-Match 'SECURITY 漂移为 skipped 且 failure_stage 为空' $securityText '(漂移|变化|不一致)[\s\S]{0,200}status.?=.?`?skipped`?[\s\S]{0,140}failure_stage[\s\S]{0,80}(空|empty)[\s\S]{0,220}result_reason[\s\S]{0,120}(重新扫描|rescan)'
Assert-Match 'SECURITY failure_stage 仅供 failed 终态' $securityText 'failure_stage[\s\S]{0,120}(仅|只).{0,40}(status.?=.?`?failed`?|failed 终态)'
Assert-Equal 'SECURITY GUI 仅显示严格验证和净化后的安全字段' (Test-GuiSafeResultContract $securityText) $true
Assert-Match 'SECURITY 自动测试不等同真实验收' $securityText '自动测试不等同真实机器验收'
Assert-Match 'SECURITY 重启及真实 0 5 30 秒验收与批准仍未完成' $securityText '(重启|restart)[\s\S]{0,120}0 秒[\s/、,，]+5 秒[\s/、,，]+30 秒[\s\S]{0,180}(尚未完成|仍未完成|待完成)[\s\S]{0,180}(用户批准|用户确认|人工批准)'
Assert-Match 'SECURITY v1.8.1 未发布未推送未实机清理验证' $securityText 'v1\.8\.1[\s\S]{0,160}未发布[\s/、,，]+未推送[\s/、,，]+(未通过真实清理验证|未验证真实清理|未完成真实清理验证)'
Assert-Equal 'SECURITY 禁止无否定上下文的完成声称' (Test-NoUnsupportedCompletionClaim $securityText) $true

# CHANGELOG：只审查 Unreleased 中目标 1.8.1，旧版本历史措辞不参与发布契约
Assert-Match 'CHANGELOG Unreleased 目标版本为 1.8.1 未发布' $changelogTarget181 '(?m)^## \[Unreleased\][\s\S]{0,160}目标版本[：:]?\s*1\.8\.1[^\r\n]{0,30}未发布'
Assert-NotMatch 'CHANGELOG 不得存在正式 1.8.1 标题' $changelogText '(?m)^## \[1\.8\.1\](?:\s*-\s*\d{4}-\d{2}-\d{2})?\s*$'
Assert-Match 'CHANGELOG 目标 1.8.1 记录真实故障和精确服务运行态修复' $changelogTarget181 '\*\*真实故障\*\*[\s\S]{0,500}\*\*精确服务运行态停止\*\*'
Assert-Match 'CHANGELOG 目标 1.8.1 记录 restart 检测和结果字段' $changelogTarget181 '\*\*重启检测\*\*[\s\S]{0,500}`?result_reason`?[\s/、,，]+`?failure_stage`?'
Assert-Match 'CHANGELOG 目标 1.8.1 记录持久动作安全恢复边界' $changelogTarget181 '`?disable_service`?[\s/、,，]+`?remove_autostart`?[\s/、,，]+`?disable_task`?[\s\S]{0,160}(备份.{0,30}恢复|可恢复)'
Assert-Match 'CHANGELOG 目标 1.8.1 记录 v2 身份交接' $changelogTarget181 'inventory_schema_version:?\s*2[\s\S]{0,260}(服务进程身份|process identity)[\s\S]{0,220}(重新扫描|拒绝 v1|v1.{0,30}拒绝)'
Assert-Match 'CHANGELOG 目标 1.8.1 记录 marker 失败关闭边界' $changelogTarget181 'ProcessIdentitySource[\s\S]{0,260}(不序列化|不得序列化)[\s\S]{0,180}(失败关闭|拒绝执行)'
Assert-Match 'CHANGELOG 目标 1.8.1 明确真实操作未执行且验收待人工' $changelogTarget181 '没有执行真实清理或 UAC[\s\S]{0,300}30 秒真实机器验收仍待人工执行'
Assert-Match 'CHANGELOG 目标 1.8.1 明确未发布未推送未验收' $changelogTarget181 '不宣称已经验收、发布或推送'
Assert-Equal 'CHANGELOG 目标 1.8.1 禁止无否定上下文的完成声称' (Test-NoUnsupportedCompletionClaim $changelogTarget181) $true

# 实施计划勘误：保持严格终态 schema，skipped 不占用 failed 专属 failure_stage
Assert-Match 'Task 4 身份漂移断言 skipped 且 failure_stage 为空' $identityPlanText '\$result\.status \| Should -BeExactly ''skipped''[\s\S]{0,120}\$result\.failure_stage \| Should -BeExactly ''''[\s\S]{0,160}\$result\.result_reason \| Should -Match ''[^'']*(授权|重新扫描|身份)[^'']*'''
Assert-NotMatch 'Task 4 不再把 skipped 漂移写成 authorization failure_stage' $identityPlanText '\$result\.status \| Should -BeExactly ''skipped''[\s\S]{0,120}\$result\.failure_stage \| Should -BeExactly ''authorization'''
Assert-Match 'Task 4 记录实施中发现严格终态 schema 勘误' $identityPlanText '(实施过程中|实现过程中).{0,40}(发现|识别).{0,80}(严格终态 schema|严格的终态 schema)'

# 反例必须失败，证明安全 GUI 与未验收契约不是只检查关键词存在
$unsafeGuiFixture = 'GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时显示原始异常、路径、token、堆栈。'
Assert-Equal 'GUI 安全字段契约拒绝原始异常泄漏反例' (Test-GuiSafeResultContract $unsafeGuiFixture) $false
$unsupportedReleaseFixture = "## [1.8.1] - 2026-08-26`n真实机器验收完成，已发布并已推送；真实清理成功。"
Assert-Equal 'CHANGELOG 契约拒绝完成发布反例' (Test-NoUnsupportedCompletionClaim $unsupportedReleaseFixture) $false
$reverseUnsupportedReleaseFixture = '已完成真实机器验收。'
Assert-Equal 'CHANGELOG 契约拒绝前置完成语序反例' (Test-NoUnsupportedCompletionClaim $reverseUnsupportedReleaseFixture) $false
$negativeReleaseFixture = '真实机器验收仍待人工执行，未发布、未推送，不宣称已经验收。'
Assert-Equal 'CHANGELOG 契约允许明确否定的发布验收措辞' (Test-NoUnsupportedCompletionClaim $negativeReleaseFixture) $true
$readmeScopeFixture = "- v1.8.1（待发布）：当前目标仍待发布。`n- v1.8.0（历史）：v1.8.0已正式发布。"
$readmeScopeResult = Get-ReadmeCurrentReleaseContract $readmeScopeFixture
Assert-Match 'README 范围夹具包含当前 v1.8.1' $readmeScopeResult 'v1\.8\.1'
Assert-NotMatch 'README 范围夹具排除历史 v1.8.0' $readmeScopeResult 'v1\.8\.0'
Assert-Equal 'README 历史正式发布不影响当前区域' (Test-NoUnsupportedCompletionClaim $readmeScopeResult) $true
$readmeUnsafeContinuationFixture = @"
- v1.8.1（待发布）：当前目标仍待发布。

  版本现已正式对外发布。
- v1.8.0（历史）：v1.8.0已正式发布。
"@
$readmeUnsafeContinuationResult = Get-ReadmeCurrentReleaseContract $readmeUnsafeContinuationFixture
Assert-Match 'README 当前条目提取恶意缩进续行' $readmeUnsafeContinuationResult '版本现已正式对外发布'
Assert-NotMatch 'README 恶意续行夹具排除 v1.8.0' $readmeUnsafeContinuationResult 'v1\.8\.0'
Assert-Equal 'README 当前条目拒绝续行发布声称' (Test-NoUnsupportedCompletionClaim $readmeUnsafeContinuationResult) $false
$readmeSafeContinuationFixture = @"
- v1.8.1（未发布）：当前目标仍待发布。

  30 秒验收仍待人工执行。
- v1.8.0（历史）：v1.8.0已正式发布。
"@
$readmeSafeContinuationResult = Get-ReadmeCurrentReleaseContract $readmeSafeContinuationFixture
Assert-Match 'README 当前条目提取合法缩进续行' $readmeSafeContinuationResult '30 秒验收仍待人工执行'
Assert-NotMatch 'README 合法续行夹具排除 v1.8.0' $readmeSafeContinuationResult 'v1\.8\.0'
Assert-Equal 'README 当前条目允许续行待人工声明' (Test-NoUnsupportedCompletionClaim $readmeSafeContinuationResult) $true

$changelogContractCases = @(
    @{ name='拒绝发布完成被未推送掩盖'; text='发布完成、未推送。'; expected=$false },
    @{ name='拒绝发布已经完成被未推送掩盖'; text='发布已经完成、未推送。'; expected=$false },
    @{ name='拒绝未发布掩盖已推送矛盾'; text='v1.8.1 未发布、已推送、未完成真实清理验证。'; expected=$false },
    @{ name='拒绝待验收掩盖真实清理成功'; text='真实机器验收仍待人工，但真实清理成功。'; expected=$false },
    @{ name='拒绝已发布'; text='已发布。'; expected=$false },
    @{ name='拒绝已经发布'; text='已经发布。'; expected=$false },
    @{ name='拒绝已推送'; text='已推送。'; expected=$false },
    @{ name='拒绝已经推送'; text='已经推送。'; expected=$false },
    @{ name='拒绝真实验收完成'; text='真实验收完成。'; expected=$false },
    @{ name='拒绝真实验收通过'; text='真实验收通过。'; expected=$false },
    @{ name='拒绝真实验收成功'; text='真实验收成功。'; expected=$false },
    @{ name='拒绝已经完成真实机器验收'; text='已经完成真实机器验收。'; expected=$false },
    # 保留旧跨行输入；换行现在是条款边界，不再把两条拼成完成声明。
    @{ name='允许跨行独立条款不拼接'; text="真实机器验收`n完成。"; expected=$true },
    @{ name='拒绝冒号真实机器验收完成'; text='真实机器验收：完成。'; expected=$false },
    @{ name='拒绝冒号已经发布'; text='已经：发布。'; expected=$false },
    @{ name='拒绝冒号已经推送'; text='已经：推送。'; expected=$false },
    @{ name='拒绝正式发布'; text='正式发布。'; expected=$false },
    @{ name='拒绝发布完成'; text='发布完成。'; expected=$false },
    @{ name='拒绝推送完成'; text='推送完成。'; expected=$false },
    @{ name='拒绝真实 UAC 验收完成'; text='真实 UAC 验收完成。'; expected=$false },
    @{ name='拒绝 30 秒验收完成'; text='30 秒验收完成。'; expected=$false },
    @{ name='拒绝完成正式发布'; text='完成正式发布。'; expected=$false },
    @{ name='拒绝完成推送'; text='完成推送。'; expected=$false },
    @{ name='拒绝真实清理正式完成'; text='真实清理正式完成。'; expected=$false },
    @{ name='拒绝成功通过 30 秒实机验收'; text='成功通过 30 秒实机验收。'; expected=$false },
    @{ name='拒绝带修饰词的正式对外发布'; text='版本现已正式对外发布。'; expected=$false },
    @{ name='拒绝带修饰词的 30 秒验收通过'; text='30 秒实机验收已经顺利通过。'; expected=$false },
    @{ name='拒绝真实清理完成'; text='真实清理完成。'; expected=$false },
    @{ name='拒绝真实清理成功'; text='真实清理成功。'; expected=$false },
    @{ name='允许未发布'; text='未发布。'; expected=$true },
    @{ name='允许尚未发布'; text='尚未发布。'; expected=$true },
    @{ name='允许没有发布'; text='没有发布。'; expected=$true },
    @{ name='允许未能发布'; text='未能发布。'; expected=$true },
    @{ name='允许不宣称已经发布'; text='不宣称已经发布。'; expected=$true },
    @{ name='允许未推送'; text='未推送。'; expected=$true },
    @{ name='允许尚未推送'; text='尚未推送。'; expected=$true },
    @{ name='允许没有推送'; text='没有推送。'; expected=$true },
    @{ name='允许未能推送'; text='未能推送。'; expected=$true },
    @{ name='允许不宣称已经推送'; text='不宣称已经推送。'; expected=$true },
    @{ name='允许未完成真实机器验收'; text='未完成真实机器验收。'; expected=$true },
    @{ name='允许没有完成真实机器验收'; text='没有完成真实机器验收。'; expected=$true },
    @{ name='允许未能完成真实机器验收'; text='未能完成真实机器验收。'; expected=$true },
    @{ name='允许尚未完成真实机器验收'; text='尚未完成真实机器验收。'; expected=$true },
    @{ name='允许真实机器验收仍待人工'; text='真实机器验收仍待人工执行。'; expected=$true },
    @{ name='允许不宣称真实验收完成'; text='不宣称真实验收完成。'; expected=$true },
    @{ name='允许不宣称已经验收'; text='不宣称已经验收。'; expected=$true },
    @{ name='允许完整联合否定声明'; text='不宣称已经验收、发布或推送。'; expected=$true },
    @{ name='允许没有执行真实清理'; text='没有执行真实清理。'; expected=$true },
    @{ name='允许目标版本未发布'; text='目标版本：1.8.1（未发布）。'; expected=$true },
    @{ name='允许尚未正式发布'; text='尚未正式发布。'; expected=$true },
    @{ name='允许真实 UAC 验收仍待人工'; text='真实 UAC 验收仍待人工执行。'; expected=$true },
    @{ name='允许 30 秒实机验收尚未完成'; text='30 秒实机验收尚未完成。'; expected=$true },
    @{ name='允许不宣称发布完成'; text='不宣称发布完成。'; expected=$true },
    @{ name='允许没有完成真实清理'; text='没有完成真实清理。'; expected=$true },
    @{ name='允许跨句等待发布与文档完成'; text='等待发布。完成文档整理。'; expected=$true },
    @{ name='允许当前目标仍待发布'; text='当前目标仍待发布。'; expected=$true }
)
foreach ($case in $changelogContractCases) {
    Assert-Equal ("CHANGELOG 表驱动: " + $case.name) (Test-NoUnsupportedCompletionClaim $case.text) $case.expected
}

$guiContractCases = @(
    @{ name='允许严格验证净化后的安全字段'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage。'; expected=$true },
    @{ name='拒绝同时显示未经验证字段'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时显示未经验证的结果字段。'; expected=$false },
    @{ name='拒绝还会显示调试详情'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，还会显示调试详情。'; expected=$false },
    @{ name='拒绝未经净化结果'; text='GUI 显示未经净化的结果。'; expected=$false },
    @{ name='拒绝原始异常路径 token 堆栈'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时显示原始异常、路径、token、堆栈。'; expected=$false },
    @{ name='拒绝也会显示额外字段'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，也会显示额外字段。'; expected=$false },
    @{ name='拒绝同文档跨行额外字段'; text="GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage。`n还会显示调试详情。"; expected=$false },
    @{ name='拒绝带逗号的同时显示额外字段'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时，显示额外字段。'; expected=$false },
    @{ name='拒绝另外展示调试详情'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，另外展示调试详情。'; expected=$false },
    @{ name='允许否定泄漏和独立扫描进度'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage。GUI 不显示未经验证字段。GUI 还会显示扫描进度。'; expected=$true },
    @{ name='允许显示备份路径'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage。GUI 还会显示备份路径。'; expected=$true },
    @{ name='拒绝原始异常路径'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，同时显示原始异常路径。'; expected=$false },
    @{ name='拒绝未经净化结果路径'; text='GUI 仅显示经过严格验证和安全净化的 result_reason / failure_stage，另外展示未经净化的结果路径。'; expected=$false }
)
foreach ($case in $guiContractCases) {
    Assert-Equal ("GUI 表驱动: " + $case.name) (Test-GuiSafeResultContract $case.text) $case.expected
}

Write-Host "`n结果: $pass 通过, $fail 失败" -ForegroundColor Cyan
if ($fail -gt 0) { throw 'SCHEMA TESTS FAILED' } else { Write-Host 'ALL SCHEMA TESTS PASSED' -ForegroundColor Green }
