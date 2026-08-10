$script:GuiStateNames = @('idle','scanning','results','review','executing','completed','error')
$script:GuiTransitions = @{
    idle      = @('scanning')
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
        results   = [pscustomobject]@{ Panel='ResultsPanel';   ActiveStage=2; Busy=$false; PrimaryKey='BtnOpenReview' }
        review    = [pscustomobject]@{ Panel='ReviewPanel';    ActiveStage=3; Busy=$false; PrimaryKey='BtnExecute' }
        executing = [pscustomobject]@{ Panel='ExecutingPanel'; ActiveStage=3; Busy=$true;  PrimaryKey='' }
        completed = [pscustomobject]@{ Panel='CompletedPanel'; ActiveStage=4; Busy=$false; PrimaryKey='BtnRescan' }
        error     = [pscustomobject]@{ Panel='ErrorPanel';     ActiveStage=0; Busy=$false; PrimaryKey='BtnRetry' }
    }
    return $definitions[$Name]
}

function Get-GuiItemSummary {
    param($Items)
    $all = @($Items)
    return [pscustomobject]@{
        executable  = @($all | Where-Object { $_.CanExecute }).Count
        observation = @($all | Where-Object { -not $_.CanExecute }).Count
        total       = $all.Count
    }
}

function Format-GuiMatcherDetail {
    param($Raw)
    if (-not $Raw) { return '' }
    return ('目标类型: {0}`r`n动作: {1}`r`n命中字段: {2}`r`n命中类型: {3}`r`n命中模式: {4}' -f
        $Raw.hit_type, $Raw.action, $Raw.matched_field, $Raw.matched_type, $Raw.matched_pattern)
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
