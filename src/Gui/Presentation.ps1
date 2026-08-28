$script:GuiStateNames = @('idle','scanning','results','review','executing','completed','error')
$script:GuiTransitions = @{
    idle      = @('scanning','error')
    scanning  = @('results','error')
    results   = @('review','scanning','idle','error')
    review    = @('executing','results','idle','error')
    executing = @('completed','error')
    completed = @('scanning','review','idle','error')
    error     = @('scanning','review','idle')
}
function Get-GuiStateNames {
    return @($script:GuiStateNames)
}

function Test-GuiStateTransition {
    param([string]$From, [string]$To)
    if ($From -notin $script:GuiStateNames -or $To -notin $script:GuiStateNames) { return $false }
    return $To -in @($script:GuiTransitions[$From])
}

function Get-GuiStateDefinition {
    param([Parameter(Mandatory=$true)][ValidateSet('idle','scanning','results','review','executing','completed','error')][string]$Name)
    $definitions = @{
        idle      = [pscustomobject]@{ Panel='IdlePanel';      ActiveStage=1; Busy=$false; PrimaryKey='BtnStartScan' }
        scanning  = [pscustomobject]@{ Panel='ScanningPanel';  ActiveStage=2; Busy=$true;  PrimaryKey='' }
        results   = [pscustomobject]@{ Panel='ResultsPanel';   ActiveStage=3; Busy=$false; PrimaryKey='BtnOpenReview' }
        review    = [pscustomobject]@{ Panel='ReviewPanel';    ActiveStage=3; Busy=$false; PrimaryKey='BtnExecute' }
        executing = [pscustomobject]@{ Panel='ExecutingPanel'; ActiveStage=3; Busy=$true;  PrimaryKey='' }
        completed = [pscustomobject]@{ Panel='CompletedPanel'; ActiveStage=4; Busy=$false; PrimaryKey='BtnRescan' }
        error     = [pscustomobject]@{ Panel='ErrorPanel';     ActiveStage=0; Busy=$false; PrimaryKey='BtnRetry' }
    }
    return $definitions[$Name]
}

function Get-GuiItemSummary {
    param($Items)
    $all = @()
    if ($null -ne $Items) { $all = @($Items) }
    return [pscustomobject]@{
        executable  = @($all | Where-Object { $_.CanExecute }).Count
        observation = @($all | Where-Object { -not $_.CanExecute }).Count
        total       = $all.Count
    }
}

function Get-GuiReviewPresentation {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('actions','resolved','observations')][string]$Branch,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$ExecutionClass,
        [Parameter(Mandatory=$true)][string]$Necessity,
        [Parameter(Mandatory=$true)][string]$ImpactCn,
        [Parameter(Mandatory=$true)][string]$CleanupReasonCn,
        [string]$CurrentState = ''
    )
    $groupKey = switch ($Branch) {
        'actions' {
            if ($ExecutionClass -ceq 'automatic_safe') { 'automatic' } else { 'manual' }
        }
        'resolved' { 'resolved' }
        default { 'observation' }
    }
    $groupLabel = switch ($groupKey) {
        'automatic'   { '建议清理' }
        'manual'      { '可选清理' }
        'resolved'    { '已处理' }
        default       { '仅观察' }
    }
    $statusLabel = if ($groupKey -eq 'resolved') { '已处理' } elseif ($groupKey -eq 'observation') { '仅观察' } elseif ($groupKey -eq 'manual') { '需确认' } else { '可执行' }
    $necessityText = switch ($Necessity) {
        'recommended'   { '建议处理' }
        'optional'      { '按需处理' }
        'informational' { '仅供参考' }
        default         { $Necessity }
    }
    $necessityLabel = '必要性：{0}' -f $necessityText
    return [pscustomobject]@{
        GroupKey           = $groupKey
        GroupLabel         = $groupLabel
        CanExecute         = ($groupKey -in @('automatic','manual'))
        IsChecked          = ($groupKey -eq 'automatic')
        NeedsConfirmation  = ($groupKey -eq 'manual')
        StatusLabel        = $statusLabel
        StatusForeground   = switch ($groupKey) {
            'automatic'   { '#FF3E6F55' }
            'manual'      { '#FFA05A00' }
            'resolved'    { '#FF2F7D44' }
            default       { '#FF6E675D' }
        }
        NecessityLabel     = $necessityLabel
        AutomationName    = '{0}；{1}；{2}；{3}' -f $Name, $groupLabel, $necessityLabel, $statusLabel
        ImpactText         = '影响：{0}' -f $ImpactCn
        CleanupReasonText  = '清理原因：{0}' -f $CleanupReasonCn
        CurrentStateLabel  = if ($groupKey -eq 'resolved') { '当前状态：{0}' -f $CurrentState } else { '' }
    }
}

function Get-GuiReviewCounts {
    param($Items)
    $all = @()
    if ($null -ne $Items) { $all = @($Items) }
    return [pscustomobject]@{
        automatic   = @($all | Where-Object { $_.GroupKey -ceq 'automatic' }).Count
        manual      = @($all | Where-Object { $_.GroupKey -ceq 'manual' }).Count
        resolved    = @($all | Where-Object { $_.GroupKey -ceq 'resolved' }).Count
        observation = @($all | Where-Object { $_.GroupKey -ceq 'observation' }).Count
    }
}

function Format-GuiReviewCountsText {
    param([Parameter(Mandatory=$true)]$Counts)
    return '建议清理 {0} 项 · 可选清理 {1} 项 · 已处理 {2} 项 · 仅观察 {3} 项' -f $Counts.automatic, $Counts.manual, $Counts.resolved, $Counts.observation
}

function Get-GuiScanHealthPresentation {
    param(
        $ScanHealth = $null,
        [string[]]$Warnings = @(),
        [ValidateSet('zh','en')][string]$Language = 'zh'
    )
    $degraded = $true
    if ($null -ne $ScanHealth) {
        $degraded = $false
        foreach ($category in @('system_info','services','tasks')) {
            if ($ScanHealth.PSObject.Properties.Name -notcontains $category -or [string]$ScanHealth.$category -cne 'complete') {
                $degraded = $true
                break
            }
        }
    }
    $effectiveWarnings = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($degraded -and $effectiveWarnings.Count -eq 0) {
        $effectiveWarnings = @($(if ($Language -eq 'zh') {
            '计划任务和完整服务信息未检查，本次结果不能判断电脑是否干净。'
        } else {
            'Scheduled tasks and complete service information were not checked; this scan cannot declare the PC clean.'
        }))
    }
    return [pscustomobject]@{
        Degraded = $degraded
        CanDeclareClean = -not $degraded
        StatusKey = if ($degraded) { 'ResultStatusDegraded' } else { 'ResultStatusEmpty' }
        EmptyHeadlineKey = if ($degraded) { 'ResultHeadlineDegraded' } else { 'ResultHeadlineEmpty' }
        Warnings = @($effectiveWarnings)
    }
}

function Format-GuiMatcherDetail {
    param($Raw)
    if (-not $Raw) { return '' }
    return @(
        '目标类型: {0}' -f $Raw.hit_type
        '动作: {0}' -f $Raw.action
        '命中字段: {0}' -f $Raw.matched_field
        '命中类型: {0}' -f $Raw.matched_type
        '命中模式: {0}' -f $Raw.matched_pattern
    ) -join [Environment]::NewLine
}

function Get-GuiSafeStableTargetFallback {
    param($Item)
    foreach ($propertyName in @('target','matched_pattern','id')) {
        $property = $Item.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $property.Value -isnot [string]) { continue }
        $value = $property.Value.Trim()
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 200) { continue }
        $hasControl = $false
        foreach ($character in $value.ToCharArray()) {
            if ([char]::IsControl($character)) { $hasControl = $true; break }
        }
        if ($hasControl -or $value -match '[A-Za-z]:[\\/]' -or $value -match '\\\\' -or
            $value -match '(?i)\b(?:bearer|token|secret|password)\b\s*[:= ]\s*\S+' -or
            $value -match '(?i)System\.Management\.Automation|ScriptStackTrace|StackTrace') { continue }
        return $value
    }
    return '已验证目标'
}

function Get-GuiExecutionTargetLabel {
    param($Item)
    $hitType = [string]$Item.hit_type
    $action = [string]$Item.action
    if ($hitType -cin @('process','service_process') -or $action -ceq 'stop_service_process') {
        $processName = [string]$Item.process_name
        $processId = $Item.process_id
        if (-not [string]::IsNullOrWhiteSpace($processName) -and
            ($processId -is [int32] -or $processId -is [int64]) -and [int64]$processId -gt 0) {
            return ('{0}（PID {1}）' -f $processName.Trim(), [int64]$processId)
        }
    }
    switch ($hitType) {
        'service' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Item.service_name)) { return ([string]$Item.service_name).Trim() }
        }
        'task' {
            if (-not [string]::IsNullOrWhiteSpace([string]$Item.task_path)) { return ([string]$Item.task_path).Trim() }
        }
        'autostart' {
            $parts = @([string]$Item.autostart_source, [string]$Item.autostart_name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
            if ($parts.Count -gt 0) { return ($parts -join ' / ') }
        }
    }
    return Get-GuiSafeStableTargetFallback -Item $Item
}

function ConvertTo-GuiExecutionRows {
    param($Items)
    foreach ($item in @($Items)) {
        $status = [string]$item.status
        $label = switch ($status) {
            'success' { '成功' }
            'failed' { '失败' }
            'skipped' { '已跳过' }
            'manual_required' { '需要手动处理' }
            'running' { '执行中' }
            default { '等待执行' }
        }
        $failureStage = if ($status -ceq 'failed') { [string]$item.failure_stage } else { '' }
        $failureStageLabel = switch ($failureStage) {
            'authorization' { '失败阶段：权限授权' }
            'backup' { '失败阶段：安全备份' }
            'mutation' { '失败阶段：系统修改' }
            'verification' { '失败阶段：结果复核' }
            'result_persistence' { '失败阶段：结果保存' }
            default { '' }
        }
        $reason = if ($status -cin @('success','failed','skipped','manual_required')) {
            [string]$item.result_reason
        } else {
            [string]$item.reason_cn
        }
        [pscustomobject]@{
            Name              = $item.name_cn
            TargetLabel       = Get-GuiExecutionTargetLabel -Item $item
            Action            = $item.action
            State             = $status
            StateLabel        = $label
            Reason            = $reason
            FailureStage      = $failureStage
            FailureStageLabel = $failureStageLabel
            IsFailure         = ($status -ceq 'failed')
            Raw               = $item
        }
    }
}
