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

    It 'stop_service_process 仅以 tested manual_impact service 动作加载' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $policy = [pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例；不可恢复；服务可能重新拉起'
            cleanup_reason_cn = '不使用联想电脑管家时减少当前常驻后台'
        }
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy $policy -ManualActions ([pscustomobject]@{ service = 'stop_service_process' })
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        try {
            $loaded = (Load-Profiles -Path $tmp).profiles[0]
            Get-ManualActionFor $loaded 'service' | Should -BeExactly 'stop_service_process'
            $decision = Get-HitExecutionDecision $loaded 'service' ([pscustomobject]@{ matched_type = 'exact' })
            $decision.Action | Should -BeExactly 'stop_service_process'
            $decision.ExecutionClass | Should -BeExactly 'manual_impact'
            $decision.DefaultSelected | Should -BeFalse
            $decision.RequiresConfirmation | Should -BeTrue
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'actions.service=stop_service_process 被拒绝为非手动声明' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        })
        $profile.actions.service = 'stop_service_process'
        $profile.manual_actions.service = 'none'
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        try { { Load-Profiles -Path $tmp } | Should -Throw '*stop_service_process 只允许 manual_actions.service*' }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'stop_service_process 拒绝非 service manual key 和 automatic_safe 形状' -TestCases @(
        @{ label = 'process-key'; key = 'process'; executionClass = 'manual_impact'; expected = '*stop_service_process 只允许 manual_actions.service*' }
        @{ label = 'automatic-safe'; key = 'service'; executionClass = 'automatic_safe'; expected = '*危险 manual_actions 必须使用 manual_impact*' }
    ) {
        param($label, $key, $executionClass, $expected)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $manual = [pscustomobject]@{}
        $manual | Add-Member -NotePropertyName $key -NotePropertyValue 'stop_service_process'
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = $executionClass; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }) -ManualActions $manual
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        try { { Load-Profiles -Path $tmp } | Should -Throw $expected }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'stop_service_process 拒绝不完整的 manual_impact 安全形状: <label>' -TestCases @(
        @{ label = 'untested'; tested = $false; defaultSelected = $false; requiresConfirmation = $true; expected = '*manual_impact 要求 evidence.tested=true*' }
        @{ label = 'default-selected'; tested = $true; defaultSelected = $true; requiresConfirmation = $true; expected = '*manual_impact 要求 default_selected=false*' }
        @{ label = 'no-confirmation'; tested = $true; defaultSelected = $false; requiresConfirmation = $false; expected = '*manual_impact 要求 requires_confirmation=true*' }
    ) {
        param($label, $tested, $defaultSelected, $requiresConfirmation, $expected)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $defaultSelected; requires_confirmation = $requiresConfirmation
            impact_cn = '影响'; cleanup_reason_cn = '原因'
        }) -ManualActions ([pscustomobject]@{ service = 'stop_service_process' }) -Evidence ([pscustomobject]@{ tested = $tested })
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        try { { Load-Profiles -Path $tmp } | Should -Throw $expected }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'stop_service_process 只由 service exact 实际 matcher 授权' -TestCases @(
        @{ matcher = 'exact'; expectedAction = 'stop_service_process'; expectedClass = 'manual_impact' }
        @{ matcher = 'path'; expectedAction = 'investigate'; expectedClass = 'observation' }
        @{ matcher = 'contains'; expectedAction = 'investigate'; expectedClass = 'observation' }
        @{ matcher = 'regex'; expectedAction = 'investigate'; expectedClass = 'observation' }
    ) {
        param($matcher, $expectedAction, $expectedClass)
        $profile = & $script:NewDecisionTestProfile -Safe $false -Action 'none' -ManualAction 'stop_service_process' -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例'; cleanup_reason_cn = '减少当前后台'
        })

        $decision = Get-HitExecutionDecision $profile 'service' ([pscustomobject]@{ matched_type = $matcher })

        $decision.Action | Should -BeExactly $expectedAction
        $decision.ExecutionClass | Should -BeExactly $expectedClass
    }

    It 'stop_service_process 即使 exact 命中也不授权非 service hitType' {
        $profile = & $script:NewDecisionTestProfile -Safe $false -Action 'none' -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例'; cleanup_reason_cn = '减少当前后台'
        })
        $profile | Add-Member -NotePropertyName manual_actions -NotePropertyValue ([pscustomobject]@{ process = 'stop_service_process' })

        $decision = Get-HitExecutionDecision $profile 'process' ([pscustomobject]@{ matched_type = 'exact' })

        $decision.Action | Should -BeExactly 'investigate'
        $decision.ExecutionClass | Should -BeExactly 'observation'
    }

    It '完整且一致的服务进程快照生成 stop_service_process 五字段执行身份' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $binary = Join-Path $TestDrive 'wsctrl11.exe'
        [System.IO.File]::WriteAllBytes($binary, [byte[]](1))
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例'; cleanup_reason_cn = '减少当前后台'
        }) -ManualActions ([pscustomobject]@{ service = 'stop_service_process' })
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        $script:ProfileFile = $tmp
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') {
                return [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=4321; PathName=('"' + $binary + '" -service') }
            }
            [pscustomobject]@{
                ProcessId = 4321; Name = 'wsctrl11.exe'; ExecutablePath = $binary
                CreationDate = [datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03.4567890', [DateTimeKind]::Utc)
            }
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }
        try {
            $hits = @(Match-Profiles -Services @([pscustomobject]@{
                Name = 'HRWSCCtrl'; DisplayName = 'Lenovo Security Center'; State = 'Running'; StartMode = 'Manual'
                PathName = ('"' + $binary + '" -service'); ProcessId = 4321
            }) -AutoStarts @() -Tasks @() -TopProcs @())

            $hits.Count | Should -Be 1
            $hits[0].action | Should -BeExactly 'stop_service_process'
            $hits[0].service_binary_path | Should -BeExactly $binary
            $hits[0].process_id | Should -Be 4321
            $hits[0].process_name | Should -BeExactly 'wsctrl11.exe'
            $hits[0].process_path | Should -BeExactly $binary
            $hits[0].process_start_time_utc | Should -Match '^2026-08-24T01:02:03\.4567890Z$'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It 'stop_service_process 身份不完整或不一致时降级并给出具体观察原因: <label>' -TestCases @(
        @{ label = 'non-positive-pid'; processId = 0; binaryExists = $true; processMode = 'valid' }
        @{ label = 'missing-binary'; processId = 4321; binaryExists = $false; processMode = 'valid' }
        @{ label = 'missing-process'; processId = 4321; binaryExists = $true; processMode = 'missing' }
        @{ label = 'multiple-processes'; processId = 4321; binaryExists = $true; processMode = 'multiple' }
        @{ label = 'process-pid-mismatch'; processId = 4321; binaryExists = $true; processMode = 'pid-mismatch' }
        @{ label = 'name-mismatch'; processId = 4321; binaryExists = $true; processMode = 'name-mismatch' }
        @{ label = 'path-mismatch'; processId = 4321; binaryExists = $true; processMode = 'path-mismatch' }
        @{ label = 'missing-start'; processId = 4321; binaryExists = $true; processMode = 'missing-start' }
    ) {
        param($label, $processId, $binaryExists, $processMode)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $binary = Join-Path $TestDrive ($label + '-wsctrl11.exe')
        $otherBinary = Join-Path $TestDrive ($label + '-other.exe')
        if ($binaryExists) { [System.IO.File]::WriteAllBytes($binary, [byte[]](1)) }
        [System.IO.File]::WriteAllBytes($otherBinary, [byte[]](2))
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例'; cleanup_reason_cn = '减少当前后台'
        }) -ManualActions ([pscustomobject]@{ service = 'stop_service_process' })
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        $script:ProfileFile = $tmp
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') {
                return [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=4321; PathName=('"' + $binary + '" -service') }
            }
            if ($processMode -ceq 'missing') { return @() }
            $record = [pscustomobject]@{
                ProcessId = if ($processMode -ceq 'pid-mismatch') { 9876 } else { 4321 }
                Name = if ($processMode -ceq 'name-mismatch') { 'other.exe' } else { [System.IO.Path]::GetFileName($binary) }
                ExecutablePath = if ($processMode -ceq 'path-mismatch') { $otherBinary } else { $binary }
                CreationDate = if ($processMode -ceq 'missing-start') { $null } else { [datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03', [DateTimeKind]::Utc) }
            }
            if ($processMode -ceq 'multiple') { return @($record, $record.PSObject.Copy()) }
            return $record
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }
        try {
            $hits = @(Match-Profiles -Services @([pscustomobject]@{
                Name = 'HRWSCCtrl'; DisplayName = 'Lenovo Security Center'; State = 'Running'; StartMode = 'Manual'
                PathName = ('"' + $binary + '" -service'); ProcessId = $processId
            }) -AutoStarts @() -Tasks @() -TopProcs @())

            $hits.Count | Should -Be 1
            $hits[0].action | Should -BeExactly 'investigate'
            $hits[0].execution_class | Should -BeExactly 'observation'
            $hits[0].default_selected | Should -BeFalse
            [string]::IsNullOrWhiteSpace([string]$hits[0].obs_reason) | Should -BeFalse
            $hits[0].obs_reason | Should -Match '身份|PID|路径|进程|启动时间'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '服务进程身份在进程读取前后发生 <drift> 漂移时降级为 observation' -TestCases @(
        @{ drift = 'PID' }
        @{ drift = 'PathName' }
        @{ drift = 'State' }
    ) {
        param($drift)
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $binary = Join-Path $TestDrive ("drift-$drift-wsctrl11.exe")
        $otherBinary = Join-Path $TestDrive ("drift-$drift-other.exe")
        [System.IO.File]::WriteAllBytes($binary, [byte[]](1))
        [System.IO.File]::WriteAllBytes($otherBinary, [byte[]](2))
        $profile = & $script:NewPolicyTestProfile -CleanupPolicy ([pscustomobject]@{
            execution_class = 'manual_impact'; necessity = 'optional'
            default_selected = $false; requires_confirmation = $true
            impact_cn = '只结束当前实例'; cleanup_reason_cn = '减少当前后台'
        }) -ManualActions ([pscustomobject]@{ service = 'stop_service_process' })
        & $script:WritePolicyTestLibrary -Path $tmp -Profile $profile
        $script:ProfileFile = $tmp
        $script:serviceReadCount = 0
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') {
                $script:serviceReadCount++
                $snapshot = [ordered]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=4321; PathName=('"' + $binary + '" -service') }
                if ($script:serviceReadCount -eq 2) {
                    if ($drift -ceq 'PID') { $snapshot.ProcessId = 9876 }
                    if ($drift -ceq 'PathName') { $snapshot.PathName = ('"' + $otherBinary + '" -service') }
                    if ($drift -ceq 'State') { $snapshot.State = 'Stopped' }
                }
                return [pscustomobject]$snapshot
            }
            return [pscustomobject]@{
                ProcessId=4321; Name=[System.IO.Path]::GetFileName($binary); ExecutablePath=$binary
                CreationDate=[datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03', [DateTimeKind]::Utc)
            }
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }
        try {
            $hit = @(Match-Profiles -Services @([pscustomobject]@{
                Name='HRWSCCtrl'; DisplayName='Lenovo Security Center'; State='Running'; StartMode='Manual'
                PathName=('"' + $binary + '" -service'); ProcessId=4321
            }) -AutoStarts @() -Tasks @() -TopProcs @())[0]

            $script:serviceReadCount | Should -Be 2
            $hit.action | Should -BeExactly 'investigate'
            $hit.execution_class | Should -BeExactly 'observation'
            $hit.obs_reason | Should -Match '服务|PID|路径|状态|快照'
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }

    It '扫描服务对象与首次当前服务读取的 <drift> 不一致时返回 null' -TestCases @(
        @{ drift='Name' }
        @{ drift='State' }
        @{ drift='PID' }
        @{ drift='PathName' }
    ) {
        param($drift)
        $binary = Join-Path $TestDrive ("original-$drift-wsctrl11.exe")
        $other = Join-Path $TestDrive ("original-$drift-other.exe")
        [System.IO.File]::WriteAllBytes($binary, [byte[]](1))
        [System.IO.File]::WriteAllBytes($other, [byte[]](2))
        $current = [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=[int]4321; PathName=('"' + $binary + '" -service') }
        $original = $current.PSObject.Copy()
        if ($drift -ceq 'Name') { $original.Name = 'hrwscctrl' }
        if ($drift -ceq 'State') { $original.State = 'Stopped' }
        if ($drift -ceq 'PID') { $original.ProcessId = [int]9876 }
        if ($drift -ceq 'PathName') { $original.PathName = ('"' + $other + '" -service') }
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') { return $current.PSObject.Copy() }
            throw 'process lookup must not occur when original and current service differ'
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }

        $reason = ''
        $identity = Get-ServiceProcessExecutionIdentity -Service $original -FailureReason ([ref]$reason)

        $identity | Should -BeNullOrEmpty
        [string]::IsNullOrWhiteSpace($reason) | Should -BeFalse
    }

    It 'UTC 启动时间采用明确语义并拒绝模糊或非法值: <label>' -TestCases @(
        @{ label='utc-datetime'; value=[datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03.4567890',[DateTimeKind]::Utc); expected='2026-08-24T01:02:03.4567890Z' }
        @{ label='offset-normalized'; value=[datetimeoffset]::Parse('2026-08-24T09:02:03.4567890+08:00'); expected='2026-08-24T01:02:03.4567890Z' }
        @{ label='unspecified'; value=[datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03',[DateTimeKind]::Unspecified); expected=$null }
        @{ label='local'; value=[datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03',[DateTimeKind]::Local); expected=$null }
        @{ label='malformed'; value='2026-08-24T01:02:03Z'; expected=$null }
        @{ label='pre-1970'; value=[datetime]::SpecifyKind([datetime]'1969-12-31T23:59:59',[DateTimeKind]::Utc); expected=$null }
        @{ label='null'; value=$null; expected=$null }
        @{ label='non-date'; value=12345; expected=$null }
    ) {
        param($label, $value, $expected)
        ConvertTo-ServiceProcessStartTimeUtc $value | Should -BeExactly $expected
    }

    It '服务 PathName/PID/进程身份矩阵严格失败关闭: <label>' -TestCases @(
        @{ label='quoted-spaces'; pathMode='quoted'; pidMode='valid'; processMode='valid'; expectSuccess=$true }
        @{ label='unquoted-ambiguous'; pathMode='unquoted'; pidMode='valid'; processMode='valid'; expectSuccess=$false }
        @{ label='relative-path'; pathMode='relative'; pidMode='valid'; processMode='valid'; expectSuccess=$false }
        @{ label='environment-path'; pathMode='environment'; pidMode='valid'; processMode='valid'; expectSuccess=$false }
        @{ label='pid-string'; pathMode='quoted'; pidMode='string'; processMode='valid'; expectSuccess=$false }
        @{ label='pid-negative'; pathMode='quoted'; pidMode='negative'; processMode='valid'; expectSuccess=$false }
        @{ label='pid-range'; pathMode='quoted'; pidMode='range'; processMode='valid'; expectSuccess=$false }
        @{ label='multiple-processes'; pathMode='quoted'; pidMode='valid'; processMode='multiple'; expectSuccess=$false }
        @{ label='case-equivalent'; pathMode='quoted'; pidMode='valid'; processMode='case'; expectSuccess=$true }
        @{ label='canonical-mismatch'; pathMode='quoted'; pidMode='valid'; processMode='mismatch'; expectSuccess=$false }
    ) {
        param($label, $pathMode, $pidMode, $processMode, $expectSuccess)
        $dir = Join-Path $TestDrive 'Program Files\Lenovo Security'
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        $binary = Join-Path $dir 'wsctrl11.exe'
        $otherDir = Join-Path $TestDrive 'Other'
        [System.IO.Directory]::CreateDirectory($otherDir) | Out-Null
        $other = Join-Path $otherDir 'wsctrl11.exe'
        [System.IO.File]::WriteAllBytes($binary, [byte[]](1))
        [System.IO.File]::WriteAllBytes($other, [byte[]](2))
        $pathName = switch ($pathMode) {
            'quoted' { '"' + $binary + '" -service' }
            'unquoted' { $binary + ' -service' }
            'relative' { '.\wsctrl11.exe -service' }
            'environment' { '%ProgramFiles%\Lenovo Security\wsctrl11.exe -service' }
        }
        $pidValue = switch ($pidMode) {
            'valid' { [int]4321 }
            'string' { '4321' }
            'negative' { [int]-1 }
            'range' { [int64]2147483648 }
        }
        $original = [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=$pidValue; PathName=$pathName }
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') { return $original.PSObject.Copy() }
            $record = [pscustomobject]@{
                ProcessId=4321; Name='wsctrl11.exe'
                ExecutablePath=if ($processMode -ceq 'case') { $binary.ToUpperInvariant() } elseif ($processMode -ceq 'mismatch') { Join-Path $dir '..\..\Other\wsctrl11.exe' } else { $binary }
                CreationDate=[datetime]::SpecifyKind([datetime]'2026-08-24T01:02:03',[DateTimeKind]::Utc)
            }
            if ($processMode -ceq 'multiple') { return @($record, $record.PSObject.Copy()) }
            return $record
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }

        $reason = ''
        $identity = Get-ServiceProcessExecutionIdentity -Service $original -FailureReason ([ref]$reason)

        ($null -ne $identity) | Should -Be $expectSuccess
        if ($expectSuccess) {
            $identity.process_id | Should -Be 4321
        } else {
            [string]::IsNullOrWhiteSpace($reason) | Should -BeFalse
        }
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
