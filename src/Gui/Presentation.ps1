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
    $necessityLabel = '必要性：{0}' -f $Necessity
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

function ConvertTo-GuiExecutionRows {
    param($Items)
    foreach ($item in @($Items)) {
        $label = switch ([string]$item.status) {
            'success' { '成功' }
            'failed' { '失败' }
            'skipped' { '已跳过' }
            'manual_required' { '需要手动处理' }
            'running' { '执行中' }
            default { '等待执行' }
        }
        [pscustomobject]@{
            Name       = $item.name_cn
            Action     = $item.action
            State      = $item.status
            StateLabel = $label
            Reason     = $item.reason_cn
            IsFailure  = ([string]$item.status -eq 'failed')
            Raw        = $item
        }
    }
}
