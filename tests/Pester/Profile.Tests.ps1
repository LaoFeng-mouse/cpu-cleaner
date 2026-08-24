# Pester 测试: 特征库加载与校验 (Pester 5 固定版本 5.9.0)
Describe 'Profile 加载' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
        $script:ProfileFile = Join-Path $projectRoot 'bloatware-profiles.json'
        $script:NewPolicyTestProfile = {
            param(
                $CleanupPolicy,
                $ManualActions = ([pscustomobject]@{ service = 'disable_service' }),
                $Evidence = ([pscustomobject]@{ tested = $true })
            )
            [pscustomobject]@{
                id = 'policy-test'; vendor = 'Lenovo'; name_cn = '联想策略测试'
                risk = 'low'; safe = $false; reason_cn = 'r'; evidence = $Evidence
                detect = [pscustomobject]@{
                    services = @([pscustomobject]@{ match = 'HRWSCCtrl'; type = 'exact' })
                    processes = @(); autostarts = @(); tasks = @()
                }
                actions = [pscustomobject]@{ service = 'none' }
                manual_actions = $ManualActions
                cleanup_policy = $CleanupPolicy
            }
        }
        $script:WritePolicyTestLibrary = {
            param([string]$Path, $Profile)
            $library = [pscustomobject]@{ schema_version = 3; profiles = @($Profile) }
            [System.IO.File]::WriteAllText($Path, ($library | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        }
        $script:WriteRawContainerProfile = {
            param([string]$Path, [string]$ContainerName, [string]$RawValue)
            $suffix = if ($ContainerName) { ',"' + $ContainerName + '":' + $RawValue } else { '' }
            $json = '{"schema_version":3,"profiles":[{"id":"container-test","vendor":"T","name_cn":"测试","risk":"low","safe":false,"reason_cn":"r","evidence":{"tested":true},"detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"none"}' + $suffix + '}]}'
            [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
        $script:NewDecisionTestProfile = {
            param(
                [bool]$Safe = $true,
                [string]$Action = 'disable_service',
                [string]$ManualAction = 'none',
                $CleanupPolicy = $null,
                [bool]$Tested = $true,
                [string]$ReasonCn = '减少不必要的常驻后台'
            )
            $profile = [pscustomobject]@{
                id = 'decision-test'; vendor = 'Test'; name_cn = '执行决策测试'
                risk = 'low'; safe = $Safe; reason_cn = $ReasonCn
                evidence = [pscustomobject]@{ tested = $Tested }
                actions = [pscustomobject]@{ service = $Action }
                execution = [pscustomobject]@{ allow_auto = $true }
            }
            if ($ManualAction -cne 'none') {
                $profile | Add-Member -NotePropertyName manual_actions -NotePropertyValue ([pscustomobject]@{ service = $ManualAction })
            }
            if ($null -ne $CleanupPolicy) {
                $profile | Add-Member -NotePropertyName cleanup_policy -NotePropertyValue $CleanupPolicy
            }
            return $profile
        }
    }

    It '合法 v2 特征库加载成功' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":["S1"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        # v1.6.0: 加载后统一为 v3
        $p.schema_version | Should -Be 3
    }
    It '空 profile 不报错' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        @($p.profiles).Count | Should -Be 0
    }
    It '错误 JSON 安全退出(throw)' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"dup","risk":"high"}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'id 重复被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $rule = '{"id":"dup","vendor":"T","name_cn":"x","risk":"high","safe":true,"reason_cn":"r","detect":{"services":["S"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[' + $rule + ',' + $rule + ']}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'safe=false 配危险动作被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":false,"reason_cn":"r","detect":{"services":["S1"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'v1 旧格式自动转换' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"profiles":[{"id":"old","vendor":"O","name":"Old","name_cn":"旧","type":"service","match":["OldSvc"],"risk":"medium","action":"disable_service","safe":true,"reason_cn":"r"}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        # v1.6.0: 加载后统一为 v3
        $p.schema_version | Should -Be 3
        @($p.profiles[0].detect.services)[0].match | Should -Be 'OldSvc'
    }

    It '合法 v3 manual_impact 策略加载并按严格形状标准化' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policyInput = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '可能影响联想电脑管家的安全状态、主动防护和通知'
            cleanup_reason_cn = '不使用联想电脑管家时可减少常驻后台'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policyInput)
        try {
            $profile = (Load-Profiles -Path $tmp).profiles[0]
            $policy = Get-CleanupPolicy $profile

            Get-ManualActionFor $profile 'missing' | Should -BeExactly 'none'
            Get-ManualActionFor $profile 'service' | Should -BeExactly 'disable_service'
            @($policy.PSObject.Properties.Name) | Should -Be @(
                'execution_class', 'necessity', 'default_selected', 'requires_confirmation',
                'impact_cn', 'cleanup_reason_cn'
            )
            $policy.execution_class | Should -BeExactly 'manual_impact'
            $policy.necessity | Should -BeExactly 'optional'
            $policy.default_selected | Should -BeFalse
            $policy.requires_confirmation | Should -BeTrue
            $policy.impact_cn | Should -BeExactly '可能影响联想电脑管家的安全状态、主动防护和通知'
            $policy.cleanup_reason_cn | Should -BeExactly '不使用联想电脑管家时可减少常驻后台'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '缺少 manual_actions 时 Get-ManualActionFor 返回 none' {
        $profile = [pscustomobject]@{ actions = [pscustomobject]@{ service = 'disable_service' } }
        Get-ManualActionFor $profile 'service' | Should -BeExactly 'none'
    }

    It '缺少 manual_actions 和 cleanup_policy 容器时仍允许加载' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        & $script:WriteRawContainerProfile -Path $tmp -ContainerName '' -RawValue ''
        try {
            @((Load-Profiles -Path $tmp).profiles).Count | Should -Be 1
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '<container> 显式 <label> 容器被拒绝' -TestCases @(
        @{ container = 'manual_actions'; label = 'null'; raw = 'null' }
        @{ container = 'manual_actions'; label = 'empty-array'; raw = '[]' }
        @{ container = 'manual_actions'; label = 'string'; raw = '"invalid"' }
        @{ container = 'manual_actions'; label = 'number'; raw = '1' }
        @{ container = 'cleanup_policy'; label = 'null'; raw = 'null' }
        @{ container = 'cleanup_policy'; label = 'empty-array'; raw = '[]' }
        @{ container = 'cleanup_policy'; label = 'string'; raw = '"invalid"' }
        @{ container = 'cleanup_policy'; label = 'number'; raw = '1' }
    ) {
        param($container, $label, $raw)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        & $script:WriteRawContainerProfile -Path $tmp -ContainerName $container -RawValue $raw
        try {
            { Load-Profiles -Path $tmp } | Should -Throw "*$container 必须是对象*"
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '危险 manual action 大小写不规范时被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $rawPolicy = '{"service":"Disable_Service"},"cleanup_policy":{"execution_class":"manual_impact","necessity":"optional","default_selected":false,"requires_confirmation":true,"impact_cn":"影响","cleanup_reason_cn":"原因"}'
        & $script:WriteRawContainerProfile -Path $tmp -ContainerName 'manual_actions' -RawValue $rawPolicy
        try {
            { Load-Profiles -Path $tmp } | Should -Throw '*manual_actions.service 非法*'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'cleanup_policy 的空白 <field> 被拒绝' -TestCases @(
        @{ field = 'impact_cn' }
        @{ field = 'cleanup_reason_cn' }
    ) {
        param($field)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        $policy.$field = '   '
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw "*cleanup_policy.$field 必须是非空字符串*" }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'cleanup_policy 的 <field> 非布尔值被拒绝' -TestCases @(
        @{ field = 'default_selected' }
        @{ field = 'requires_confirmation' }
    ) {
        param($field)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        $policy.$field = 'false'
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw "*cleanup_policy.$field 必须是布尔值*" }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '危险 manual_actions 没有 manual_impact execution_class 被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'automatic_safe'; necessity = 'optional'
            default_selected = $true; requires_confirmation = $false
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw '*危险 manual_actions 必须使用 manual_impact*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'manual_impact 的 requires_confirmation=false 被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $false
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw '*manual_impact 要求 requires_confirmation=true*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'manual_impact 的 default_selected=true 被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $true; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw '*manual_impact 要求 default_selected=false*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'cleanup_policy execution_class 只允许 automatic_safe 和 manual_impact' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy)
        try { { Load-Profiles -Path $tmp } | Should -Throw '*cleanup_policy.execution_class 非法*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'manual_impact 要求 tested evidence 和危险 manual action' -TestCases @(
        @{ label = 'untested'; evidence = ([pscustomobject]@{ tested = $false }); manual = ([pscustomobject]@{ service = 'disable_service' }); expected = '*manual_impact 要求 evidence.tested=true*' }
        @{ label = 'no-danger'; evidence = ([pscustomobject]@{ tested = $true }); manual = ([pscustomobject]@{ service = 'investigate' }); expected = '*manual_impact 要求危险 manual_actions*' }
    ) {
        param($label, $evidence, $manual, $expected)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile (& $script:NewPolicyTestProfile -CleanupPolicy $policy -ManualActions $manual -Evidence $evidence)
        try { { Load-Profiles -Path $tmp } | Should -Throw $expected }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'safe tested exact 危险 normal action 返回 automatic_safe 完整决策' {
        $policy = [pscustomobject]@{
            execution_class = 'automatic_safe'; necessity = 'unnecessary'
            default_selected = $true; requires_confirmation = $false
            impact_cn = '不影响 Windows 核心功能'; cleanup_reason_cn = '关闭 OEM 通知后台'
        }
        $profile = & $script:NewDecisionTestProfile -CleanupPolicy $policy

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = 'exact' })

        @($decision.PSObject.Properties.Name) | Should -Be @(
            'Action', 'ExecutionClass', 'Necessity', 'DefaultSelected',
            'RequiresConfirmation', 'ImpactCn', 'CleanupReasonCn'
        )
        $decision.Action | Should -BeExactly 'disable_service'
        $decision.ExecutionClass | Should -BeExactly 'automatic_safe'
        $decision.Necessity | Should -BeExactly 'unnecessary'
        $decision.DefaultSelected | Should -BeTrue
        $decision.RequiresConfirmation | Should -BeFalse
        $decision.ImpactCn | Should -BeExactly '不影响 Windows 核心功能'
        $decision.CleanupReasonCn | Should -BeExactly '关闭 OEM 通知后台'
    }

    It '旧 safe tested exact 自动规则没有 cleanup_policy 时保留动作和保守默认值' {
        $profile = & $script:NewDecisionTestProfile -ReasonCn '实测后建议关闭此后台项'

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = 'path' })

        $decision.Action | Should -BeExactly 'disable_service'
        $decision.ExecutionClass | Should -BeExactly 'automatic_safe'
        $decision.Necessity | Should -BeExactly 'recommended'
        $decision.DefaultSelected | Should -BeTrue
        $decision.RequiresConfirmation | Should -BeFalse
        $decision.ImpactCn | Should -BeExactly '实测后建议关闭此后台项'
        $decision.CleanupReasonCn | Should -BeExactly '实测后建议关闭此后台项'
    }

    It 'safe false tested exact 且有合规危险 manual action 返回 manual_impact' {
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '可能影响 OEM 主动防护'; cleanup_reason_cn = '不用 OEM 管家时可减少后台'
        }
        $profile = & $script:NewDecisionTestProfile -Safe $false -Action 'none' -ManualAction 'disable_service' -CleanupPolicy $policy

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = 'exact' })

        $decision.Action | Should -BeExactly 'disable_service'
        $decision.ExecutionClass | Should -BeExactly 'manual_impact'
        $decision.Necessity | Should -BeExactly 'optional'
        $decision.DefaultSelected | Should -BeFalse
        $decision.RequiresConfirmation | Should -BeTrue
        $decision.ImpactCn | Should -BeExactly '可能影响 OEM 主动防护'
        $decision.CleanupReasonCn | Should -BeExactly '不用 OEM 管家时可减少后台'
    }

    It 'manual_impact 规则实际只由 <matcher> 命中时降级为 observation' -TestCases @(
        @{ matcher = 'contains' }
        @{ matcher = 'regex' }
    ) {
        param($matcher)
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '可能影响 OEM 功能'; cleanup_reason_cn = '减少后台'
        }
        $profile = & $script:NewDecisionTestProfile -Safe $false -Action 'none' -ManualAction 'disable_service' -CleanupPolicy $policy

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = $matcher })

        $decision.Action | Should -BeExactly 'investigate'
        $decision.ExecutionClass | Should -BeExactly 'observation'
        $decision.DefaultSelected | Should -BeFalse
    }

    It 'execution allow_auto 不能绕过未实测证据' {
        $profile = & $script:NewDecisionTestProfile -Tested $false

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = 'exact' })

        $decision.Action | Should -BeExactly 'investigate'
        $decision.ExecutionClass | Should -BeExactly 'observation'
    }

    It '声明 none 的规则缺少窄证据时仍返回明确 observation 决策: <label>' -TestCases @(
        @{ label = 'contains'; evidence = ([pscustomobject]@{ matched_type = 'contains' }) }
        @{ label = 'regex'; evidence = ([pscustomobject]@{ matched_type = 'regex' }) }
        @{ label = 'missing'; evidence = $null }
    ) {
        param($label, $evidence)
        $profile = & $script:NewDecisionTestProfile -Action 'none'

        $decision = Get-HitExecutionDecision $profile 'service' $evidence

        $decision.Action | Should -BeExactly 'investigate'
        $decision.ExecutionClass | Should -BeExactly 'observation'
    }

    It '旧 automatic profile 缺少或留空 reason_cn 时返回明确保守中文文案' {
        $missingReason = & $script:NewDecisionTestProfile
        $missingReason.PSObject.Properties.Remove('reason_cn')
        $blankReason = & $script:NewDecisionTestProfile -ReasonCn '   '

        foreach ($profile in @($missingReason, $blankReason)) {
            $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = 'exact' })

            $decision.ExecutionClass | Should -BeExactly 'automatic_safe'
            $decision.ImpactCn | Should -BeExactly '具体功能影响未说明，处理前请确认目标用途'
            $decision.CleanupReasonCn | Should -BeExactly '该项目已实测可处理，但规则未提供具体清理原因'
            [string]::IsNullOrWhiteSpace($decision.ImpactCn) | Should -BeFalse
            [string]::IsNullOrWhiteSpace($decision.CleanupReasonCn) | Should -BeFalse
        }
    }

    It '同一 hit type 同时声明危险 normal 和 manual action 时拒绝 profile' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '可能影响 OEM 功能'; cleanup_reason_cn = '减少后台'
        }
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy $policy
        $profile.safe = $true
        $profile.actions.service = 'disable_service'
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        try { { Load-Profiles -Path $tmp } | Should -Throw '*actions.service 和 manual_actions.service 不能同时声明危险动作*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'Match-Profiles 选择 exact 胜过 contains 并复制决策和真实 matcher provenance' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $profile = [pscustomobject]@{
            id = 'strongest-match'; vendor = 'OEM'; name_cn = '最强匹配测试'
            risk = 'low'; safe = $true; reason_cn = '建议关闭 OEM 通知'
            evidence = [pscustomobject]@{ tested = $true }
            detect = [pscustomobject]@{
                services = @(
                    [pscustomobject]@{ match = 'OEM'; type = 'contains' }
                    [pscustomobject]@{ match = 'OEMService'; type = 'exact' }
                )
                processes = @(); autostarts = @(); tasks = @()
            }
            actions = [pscustomobject]@{ service = 'disable_service' }
            cleanup_policy = [pscustomobject]@{
                execution_class = 'automatic_safe'; necessity = 'recommended'
                default_selected = $true; requires_confirmation = $false
                impact_cn = '仅影响 OEM 通知'; cleanup_reason_cn = '减少 OEM 通知后台'
            }
        }
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        $script:ProfileFile = $tmp
        try {
            $hits = @(Match-Profiles -Services @([pscustomobject]@{
                Name = 'OEMService'; DisplayName = 'OEM Service'; State = 'Running'; StartMode = 'Auto'
            }) -AutoStarts @() -Tasks @() -TopProcs @())

            $hits.Count | Should -Be 1
            $hits[0].action | Should -BeExactly 'disable_service'
            $hits[0].execution_class | Should -BeExactly 'automatic_safe'
            $hits[0].necessity | Should -BeExactly 'recommended'
            $hits[0].default_selected | Should -BeTrue
            $hits[0].requires_confirmation | Should -BeFalse
            $hits[0].impact_cn | Should -BeExactly '仅影响 OEM 通知'
            $hits[0].cleanup_reason_cn | Should -BeExactly '减少 OEM 通知后台'
            $hits[0].matched_pattern | Should -BeExactly 'OEMService'
            $hits[0].matched_type | Should -BeExactly 'exact'
            $hits[0].matched_field | Should -BeExactly 'service_name'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
}
