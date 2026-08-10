# ============================================================
#  鼠鼠cleaner - 图形界面 (gui-cleaner.ps1)
#  需要: Windows 10/11 + PowerShell 5.1 (自带 WPF)
#  用法: 双击 鼠鼠cleaner.bat 或 powershell -File gui-cleaner.ps1
# ============================================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Lang = 'zh'   # zh / en
# v1.5.3: 测试模式 (SHUSHU_CLEANER_TEST=1) — 跳过单实例检查与窗口显示, 供 CI 无窗口验证 (Pester)
$script:TestMode = ($env:SHUSHU_CLEANER_TEST -eq '1')

# ---------- 单实例: 只能开一个窗口 (测试模式跳过) ----------
$existing = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -match '鼠鼠cleaner' }
if ($existing -and -not $script:TestMode) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show('鼠鼠cleaner 已经在运行了，请到已打开的窗口操作。', '鼠鼠cleaner', 'OK', 'Warning') | Out-Null
    exit 0
}

# ---------- 中英文文案 ----------
$script:I18N = @{
    'zh' = @{
        AppName='鼠鼠cleaner'; SubTitle='扫描 · 清理 · 恢复 —— 全程自动备份，后悔可还原'; Hint0='图形界面只是壳，核心逻辑与命令行版一致'
        TabScan='🐹 1. 扫描（只读）'; TabPending='📋 2. 处理建议'; TabExec='⚙️ 3. 执行（管理员）'; TabResult='✅ 4. 结果与恢复'
        BtnScan='开始扫描'; ScanHint='扫描只查看、不改任何设置，随便点'; Scanning='正在扫描，请稍候…'
        ScanPhaseInitial='正在检查服务、启动项、计划任务和进程'; ScanPhaseSystemInfo='读取系统信息'; ScanPhaseProcesses='检查高占用进程'; ScanPhaseServices='检查系统服务'; ScanPhaseAutoStart='检查启动项'; ScanPhaseTasks='检查计划任务'; ScanPhaseRules='匹配安全规则'; ScanPhaseReport='生成扫描报告'
        ScanResultSummary='{0} 项可以安全处理，{1} 项建议观察'; ScanErrorSummary='扫描失败：{0}'; ScanNoMutation='扫描阶段未修改任何系统设置。'; ScanStatusStart='启动'; ScanStatusOutput='输出读取'; ScanStatusResults='结果处理'
        BtnLoad='读取待处理清单'; PendingHint='按风险/实测展示，勾选要处理的项目（未实测=仅观察，默认不勾选）'; PendingNone='没有待处理项目——请先到【1. 扫描】页扫描（或已全部处理完）'; PendingCount='共 {0} 项待处理。勾选后到【3. 执行】页处理。'
        SelectAll='全选'; ClearAll='清空'
        ExecInfo1='在【2. 处理建议】页勾选要处理的项目，到这里一键执行。'; ExecInfo2='每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。'
        BtnExec='处理已勾选项目（需要管理员）'; ExecEmpty='请先勾选要处理的项目（【2. 处理建议】页勾选）。'; ExecStart='将处理 {0} 项。已请求管理员权限，请在弹窗点【是】…'; ExecDone='处理窗口已结束。到【4. 结果】页查看（建议重启电脑让改动完全生效）。'
        ExecFailed='执行失败: ExitCode={0}（可能被取消或出错）'; ExecDoneSum='执行完成: success {0} / failed {1} / skipped {2}'
        BtnResult='查看最近处理结果'; BtnRestore='恢复最近一次处理'; ResultHint='恢复会弹管理员窗口，选最新备份还原'
        NoBackup='还没有备份记录（还没处理过）。'; RestoreOk='已恢复 {0}。详见管理员窗口。'; RestoreNone='还没有备份，无需恢复。'; RestoreErr='恢复出错或被取消: {0}'; RestorePartial='恢复完成，但部分条目验证失败（详见管理员窗口）。'
        State_idle_Title='鼠鼠开始幻想'; State_idle_Sub='先做只读扫描，不会修改系统。'
        State_scanning_Title='正在看清现实'; State_scanning_Sub='只展示真实阶段，不伪造完成百分比。'
        State_results_Title='扫描结论'; State_results_Sub='可处理项与观察项分开显示，目前尚未修改系统。'
        State_review_Title='确认处理边界'; State_review_Sub='只有安全、已测试且窄匹配命中的项目可以选择。'
        State_executing_Title='鼠鼠正在谨慎整理'; State_executing_Sub='每项都会重新验证、备份并记录结果。'
        State_completed_Title='幻想落地'; State_completed_Sub='结果按成功、失败和跳过逐项展示。'
        State_error_Title='鼠鼠的幻想被打断了'; State_error_Sub='查看真实原因后可以安全重试。'
        LangLabel='EN'
    }
    'en' = @{
        AppName='Shushu Cleaner'; SubTitle='Scan · Clean · Restore — auto backup, undo anytime'; Hint0='GUI is a shell; core logic is identical to CLI'
        TabScan='🐹 1. Scan (read-only)'; TabPending='📋 2. Recommendations'; TabExec='⚙️ 3. Execute (admin)'; TabResult='✅ 4. Result & Restore'
        BtnScan='Start Scan'; ScanHint='Scan only reads, changes nothing'; Scanning='Scanning, please wait…'
        ScanPhaseInitial='Checking services, startup items, scheduled tasks, and processes'; ScanPhaseSystemInfo='Reading system information'; ScanPhaseProcesses='Checking high-usage processes'; ScanPhaseServices='Checking system services'; ScanPhaseAutoStart='Checking startup items'; ScanPhaseTasks='Checking scheduled tasks'; ScanPhaseRules='Matching safety rules'; ScanPhaseReport='Generating scan report'
        ScanResultSummary='{0} safe item(s), {1} observation(s)'; ScanErrorSummary='Scan failed: {0}'; ScanNoMutation='The scan did not change any system settings.'; ScanStatusStart='startup'; ScanStatusOutput='output read'; ScanStatusResults='result processing'
        BtnLoad='Load Pending Items'; PendingHint='Risk & evidence shown; check items to process (unverified = observe only, unchecked)'; PendingNone='No pending items — run Scan first (or all done)'; PendingCount='{0} item(s) pending. Check items, then go to tab 3.'
        SelectAll='Select All'; ClearAll='Clear'
        ExecInfo1='Check items in tab 2, then process them here.'; ExecInfo2='Every action is backed up and verified. UAC popup: click YES.'
        BtnExec='Process Checked Items (admin)'; ExecEmpty='Check items first (tab 2).'; ExecStart='Processing {0} item(s). UAC requested, click YES…'; ExecDone='Processing done. See tab 4 (restart PC recommended).'
        ExecFailed='Execution failed: ExitCode={0} (cancelled or error)'; ExecDoneSum='Done: success {0} / failed {1} / skipped {2}'
        BtnResult='Show Latest Result'; BtnRestore='Restore Last Changes'; ResultHint='Restore opens admin window, picks newest backup'
        NoBackup='No backup yet (nothing processed).'; RestoreOk='Restored {0}. See admin window.'; RestoreNone='No backup, nothing to restore.'; RestoreErr='Restore failed/cancelled: {0}'; RestorePartial='Restore finished, but some items failed verification (see admin window).'
        State_idle_Title='The fantasy begins'; State_idle_Sub='Start with a read-only scan. No system settings will change.'
        State_scanning_Title='Looking at reality'; State_scanning_Sub='Showing real scan phases without a fabricated percentage.'
        State_results_Title='Scan result'; State_results_Sub='Safe actions and observations are separated. Nothing has changed yet.'
        State_review_Title='Review the safety boundary'; State_review_Sub='Only tested items produced by narrow matches can be selected.'
        State_executing_Title='Cleaning carefully'; State_executing_Sub='Every item is revalidated, backed up, and recorded.'
        State_completed_Title='Fantasy delivered'; State_completed_Sub='Success, failure, and skipped results are shown item by item.'
        State_error_Title='The fantasy was interrupted'; State_error_Sub='Read the real cause, then retry safely.'
        LangLabel='中文'
    }
}

function Get-Text($key) {
    $languageMap = $script:I18N[$script:Lang]
    if (-not $languageMap -or -not $languageMap.ContainsKey($key) -or $null -eq $languageMap[$key]) {
        throw "Missing localized text: $script:Lang/$key"
    }
    return $languageMap[$key]
}

function Update-GuiStateText {
    param(
        [string]$StateName = $script:GuiState,
        $TitleControl = $null,
        $SubtitleControl = $null,
        [AllowNull()][string]$TitleText = $null,
        [AllowNull()][string]$SubtitleText = $null
    )
    if ($null -eq $TitleControl) { $TitleControl = $window.FindName('StateTitle') }
    if ($null -eq $SubtitleControl) { $SubtitleControl = $window.FindName('StateSubtitle') }
    if ($null -eq $TitleControl) { throw 'GUI control missing: StateTitle' }
    if ($null -eq $SubtitleControl) { throw 'GUI control missing: StateSubtitle' }
    if ($null -eq $TitleText) { $TitleText = Get-Text ('State_{0}_Title' -f $StateName) }
    if ($null -eq $SubtitleText) { $SubtitleText = Get-Text ('State_{0}_Sub' -f $StateName) }
    $TitleControl.Text = $TitleText
    $SubtitleControl.Text = $SubtitleText
}

function Apply-Language {
    $t = $script:I18N[$script:Lang]
    $w = $window
    $w.Title = $t['AppName']
    $w.FindName('TitleMain').Text = $t['AppName']
    $w.FindName('BtnLang').Content = $t['LangLabel']
    Update-GuiStateText
}

# ---------- 鼠鼠风格 XAML ----------
. (Join-Path $script:Root 'src\Gui\Presentation.ps1')
$xamlPath = Join-Path $script:Root 'src\Gui\MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) { throw "GUI layout missing: $xamlPath" }
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 鼠鼠页面形象图: 用绝对路径 (Image Source 相对路径按工作目录解析, 不可靠)
$script:ImgMap = [ordered]@{
    ImgStage1 = 'assets/rat_scan.jpg'
    ImgStage2 = 'assets/rat_pending.jpg'
    ImgStage3 = 'assets/rat_exec.jpg'
    ImgStage4 = 'assets/rat_result.jpg'
}
foreach ($imgName in $script:ImgMap.Keys) {
    $imgCtrl = $window.FindName($imgName)
    if ($imgCtrl) {
        $imgFile = Join-Path $script:Root $script:ImgMap[$imgName]
        if (Test-Path $imgFile) {
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.UriSource = ([uri]$imgFile); $bi.CacheOption = 'OnLoad'; $bi.EndInit()
            $imgCtrl.Source = $bi
        }
    }
}

$script:GuiState = 'idle'
$script:GuiActiveStage = 1
$script:StatePanels = @('IdlePanel','ScanningPanel','ResultsPanel','ReviewPanel','ExecutingPanel','CompletedPanel','ErrorPanel')

function Set-GuiState {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('idle','scanning','results','review','executing','completed','error')][string]$Name,
        [switch]$Force
    )
    if (-not $Force -and -not (Test-GuiStateTransition $script:GuiState $Name)) {
        throw "非法界面状态转换: $script:GuiState -> $Name"
    }
    $definition = Get-GuiStateDefinition $Name

    $panels = [ordered]@{}
    foreach ($panelName in $script:StatePanels) {
        $panel = $window.FindName($panelName)
        if ($null -eq $panel) { throw "GUI control missing: $panelName" }
        if (-not $panel.PSObject.Properties['Visibility']) { throw "GUI control invalid: $panelName.Visibility" }
        $panels[$panelName] = $panel
    }

    $cards = [ordered]@{}
    for ($stage = 1; $stage -le 4; $stage++) {
        $cardName = "StageCard$stage"
        $card = $window.FindName($cardName)
        if ($null -eq $card) { throw "GUI control missing: $cardName" }
        foreach ($propertyName in @('Opacity','BorderBrush','BorderThickness')) {
            if (-not $card.PSObject.Properties[$propertyName]) { throw "GUI control invalid: $cardName.$propertyName" }
        }
        $cards[$cardName] = $card
    }

    $titleControl = $window.FindName('StateTitle')
    $subtitleControl = $window.FindName('StateSubtitle')
    if ($null -eq $titleControl) { throw 'GUI control missing: StateTitle' }
    if ($null -eq $subtitleControl) { throw 'GUI control missing: StateSubtitle' }
    if (-not $titleControl.PSObject.Properties['Text']) { throw 'GUI control invalid: StateTitle.Text' }
    if (-not $subtitleControl.PSObject.Properties['Text']) { throw 'GUI control invalid: StateSubtitle.Text' }

    $titleText = Get-Text ('State_{0}_Title' -f $Name)
    $subtitleText = Get-Text ('State_{0}_Sub' -f $Name)
    $activeStage = if ($definition.ActiveStage -eq 0) { $script:GuiActiveStage } else { $definition.ActiveStage }

    $previousState = $script:GuiState
    $previousActiveStage = $script:GuiActiveStage
    $previousPanels = [ordered]@{}
    foreach ($panelName in $script:StatePanels) { $previousPanels[$panelName] = $panels[$panelName].Visibility }
    $previousCards = [ordered]@{}
    for ($stage = 1; $stage -le 4; $stage++) {
        $cardName = "StageCard$stage"
        $previousCards[$cardName] = [pscustomobject]@{
            Opacity = $cards[$cardName].Opacity
            BorderBrush = $cards[$cardName].BorderBrush
            BorderThickness = $cards[$cardName].BorderThickness
        }
    }
    $previousTitle = $titleControl.Text
    $previousSubtitle = $subtitleControl.Text

    try {
        foreach ($panelName in $script:StatePanels) {
            $panels[$panelName].Visibility = if ($panelName -eq $definition.Panel) { 'Visible' } else { 'Collapsed' }
        }
        for ($stage = 1; $stage -le 4; $stage++) {
            $card = $cards["StageCard$stage"]
            $card.Opacity = if ($stage -le $activeStage) { 1.0 } else { 0.46 }
            $card.BorderBrush = if ($stage -eq $activeStage) { '#FFD21F' } else { '#D8CBAA' }
            $card.BorderThickness = if ($stage -eq $activeStage) { 3 } else { 1 }
        }
        Update-GuiStateText -StateName $Name -TitleControl $titleControl -SubtitleControl $subtitleControl -TitleText $titleText -SubtitleText $subtitleText
        $script:GuiState = $Name
        $script:GuiActiveStage = $activeStage
    } catch {
        $originalError = $_
        foreach ($panelName in $script:StatePanels) {
            try { $panels[$panelName].Visibility = $previousPanels[$panelName] } catch {}
        }
        for ($stage = 1; $stage -le 4; $stage++) {
            $cardName = "StageCard$stage"
            try { $cards[$cardName].Opacity = $previousCards[$cardName].Opacity } catch {}
            try { $cards[$cardName].BorderBrush = $previousCards[$cardName].BorderBrush } catch {}
            try { $cards[$cardName].BorderThickness = $previousCards[$cardName].BorderThickness } catch {}
        }
        try { $titleControl.Text = $previousTitle } catch {}
        try { $subtitleControl.Text = $previousSubtitle } catch {}
        $script:GuiState = $previousState
        $script:GuiActiveStage = $previousActiveStage
        throw $originalError
    }
}

function Get-PendingItems {
    param([string]$Path = '')
    $pf = if ($Path) { $Path } else { Join-Path $script:Root 'pending_actions.json' }
    if (-not (Test-Path $pf)) { return @() }
    $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $p.actions) { return @() }
    return @($p.actions)
}

function Get-PendingIdentityKey($Item) {
    $identity = [ordered]@{
        id                   = $Item.id
        hit_type             = $Item.hit_type
        action               = $Item.action
        service_name         = $Item.service_name
        service_display_name = $Item.service_display_name
        autostart_source     = $Item.autostart_source
        autostart_name       = $Item.autostart_name
        autostart_value      = $Item.autostart_value
        task_name            = $Item.task_name
        task_path            = $Item.task_path
        process_name         = $Item.process_name
        process_id           = $Item.process_id
        process_path         = $Item.process_path
        matched_pattern      = $Item.matched_pattern
        matched_type         = $Item.matched_type
        matched_field        = $Item.matched_field
    }
    return ConvertTo-Json -InputObject $identity -Compress -Depth 4
}

function Copy-PendingActionForSubset($RawAction) {
    $properties = [ordered]@{}
    foreach ($property in $RawAction.PSObject.Properties) {
        $properties[$property.Name] = $property.Value
    }
    $properties['status'] = 'pending'
    return [pscustomobject]$properties
}

function Get-GuiPendingSchemaVersion($Pending) {
    $schemaProperty = $null
    if ($null -ne $Pending) {
        foreach ($property in $Pending.PSObject.Properties) {
            if ([string]::Equals($property.Name, 'pending_schema_version', [System.StringComparison]::Ordinal)) {
                $schemaProperty = $property
                break
            }
        }
    }
    if ($null -eq $schemaProperty -or
        ($schemaProperty.Value -isnot [int32] -and $schemaProperty.Value -isnot [int64]) -or
        -not ([int64]2).Equals([int64]$schemaProperty.Value)) {
        throw 'pending 清单版本旧或不兼容。请重新运行 scan 生成新清单。'
    }
    return $schemaProperty.Value
}

function New-PendingSubsetPayload {
    param($Checked, $SourcePending)
    $pendingVersion = Get-GuiPendingSchemaVersion $SourcePending
    $actions = @()
    foreach ($checkedItem in @($Checked)) {
        if ($checkedItem -and $checkedItem._raw) {
            $actions += Copy-PendingActionForSubset $checkedItem._raw
        }
    }
    $observations = @()
    if ($SourcePending -and $SourcePending.observations) { $observations = @($SourcePending.observations) }
    $suspicious = @()
    if ($SourcePending -and $SourcePending.suspicious) { $suspicious = @($SourcePending.suspicious) }
    $properties = [ordered]@{
        pending_schema_version = $pendingVersion
        generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions = @($actions)
        observations = @($observations)
        suspicious = @($suspicious)
    }
    foreach ($property in $SourcePending.PSObject.Properties) {
        if ($property.Name -notin @('pending_schema_version','generated','actions','observations','suspicious')) {
            $properties[$property.Name] = $property.Value
        }
    }
    return [pscustomobject]$properties
}

function ConvertTo-GuiPendingJson {
    param($InputObject)
    return ConvertTo-Json -InputObject $InputObject -Depth 100
}

# v1.5.5: 动作中文标签 (勾选视图展示)
function Get-ActionLabel($a) {
    switch ($a) {
        'disable_service'  { return '禁用服务' }
        'remove_autostart' { return '删除自启' }
        'disable_task'     { return '禁用任务' }
        'uninstall'        { return '手动卸载' }
        'investigate'      { return '仅观察' }
        'none'             { return '不处理' }
        default            { return $a }
    }
}

# v1.5.5: 特征库 id → 规则 查找表 (仅展示用; 执行层的严格校验由 CLI Load-Profiles + 授权验证负责)
function Get-ProfileLookup {
    $map = @{}
    $pf = Join-Path $script:Root 'bloatware-profiles.json'
    if (-not (Test-Path $pf)) { return $map }
    try {
        $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @($p.profiles)) { if ($r.id) { $map[$r.id] = $r } }
    } catch {}
    return $map
}

# v1.5.6: 从特征库查单条规则的展示标签 (风险/实测)
function Get-RuleDisplay($rule) {
    $riskLabel = '未知'
    $evidenceLabel = '未实测'
    if ($rule) {
        $riskLabel = switch ($rule.risk) { 'high' { '高风险' } 'medium' { '中风险' } 'low' { '低风险' } default { '未知' } }
        $evidenceLabel = if ($rule.evidence -and $rule.evidence.tested) { ('实测 {0} 台' -f $rule.evidence.tested_count) } else { '未实测' }
    }
    return [pscustomobject]@{ risk_label = $riskLabel; evidence_label = $evidenceLabel }
}

# v1.5.6: 构造勾选展示对象 — actions(可执行, 勾选) / observations(仅观察, checkbox disabled)
# 数据流: scan → Save-PendingActions 已分流; 这里 actions 只读可执行集, observations 只读观察集
function Get-PendingViewItems {
    $pf = Join-Path $script:Root 'pending_actions.json'
    if (-not (Test-Path $pf)) { return @() }
    $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = Get-ProfileLookup
    $view = @()
    # 1) 可执行项: 默认勾选, 可勾选
    foreach ($i in @($p.actions | Where-Object { $_ -and $_.status -in @('pending','failed') })) {
        $d = Get-RuleDisplay $map[$i.id]
        $view += [pscustomobject]@{
            IsChecked         = $true
            CanExecute        = $true
            name_cn           = $i.name_cn
            risk_label        = $d.risk_label
            evidence_label    = $d.evidence_label
            action_label      = Get-ActionLabel $i.action
            restorable_label  = '可恢复'
            status            = $i.status
            reason_cn         = $i.reason_cn
            _raw              = $i
        }
    }
    # 2) 观察项: 证据不足/仅观察 — checkbox disabled, 全选跳过
    foreach ($i in @($p.observations)) {
        $d = Get-RuleDisplay $map[$i.id]
        $obsReason = if ($i.obs_reason) { $i.obs_reason } else { '仅观察, 不允许自动处理' }
        $view += [pscustomobject]@{
            IsChecked         = $false
            CanExecute        = $false
            name_cn           = $i.name_cn
            risk_label        = $d.risk_label
            evidence_label    = $d.evidence_label
            action_label      = Get-ActionLabel $i.action
            restorable_label  = '不可自动'
            status            = '观察'
            reason_cn         = $obsReason
            _raw              = $i
        }
    }
    return $view
}

# v1.5.6: 全选/清空 — 全选跳过 CanExecute=false (观察项 checkbox disabled 且不可被全选勾上)
function Set-AllChecked($list, $value) {
    foreach ($it in @($list.Items)) {
        if (-not $value -or $it.CanExecute) { $it.IsChecked = $value }
    }
}

# v1.5.5: 把勾选子集临时文件的处理结果状态合并回主 pending_actions.json
# (clean 处理的是临时子集, 主清单不同步的话下次加载仍是 pending, 用户会看到重复待办)
function Merge-PendingStatus($SubsetPath) {
    $mainPath = Join-Path $script:Root 'pending_actions.json'
    if (-not (Test-Path $mainPath) -or -not (Test-Path $SubsetPath)) { return }
    $main = Get-Content $mainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $subset = Get-Content $SubsetPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $main.actions -or -not $subset.actions) { return }
    foreach ($sa in @($subset.actions)) {
        foreach ($ma in @($main.actions)) {
            $sameKey = (Get-PendingIdentityKey $ma) -eq (Get-PendingIdentityKey $sa)
            if ($sameKey) { $ma.status = $sa.status }
        }
    }
    ConvertTo-GuiPendingJson -InputObject $main | Out-File $mainPath -Encoding utf8
}

# v1.5.3: 扫描 job 收尾统一处理 — Completed 成功 / Failed / Stopped 都要恢复 UI
# 返回 $true 表示 job 已结束 (轮询 timer 应停止), $false 表示仍在运行
$script:ScanPhaseMarkers = @(
    '读取系统信息', '检查高占用进程', '检查系统服务', '检查启动项',
    '检查计划任务', '匹配安全规则', '生成扫描报告'
)
$script:ScanPhaseTextKeys = @{
    '读取系统信息' = 'ScanPhaseSystemInfo'
    '检查高占用进程' = 'ScanPhaseProcesses'
    '检查系统服务' = 'ScanPhaseServices'
    '检查启动项' = 'ScanPhaseAutoStart'
    '检查计划任务' = 'ScanPhaseTasks'
    '匹配安全规则' = 'ScanPhaseRules'
    '生成扫描报告' = 'ScanPhaseReport'
}
$script:ScanTranscriptLimit = 65536
$script:ScanTranscript = ''

function Add-GuiScanOutput {
    param([object[]]$Lines)
    $added = $false
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $added = $true
        $text = [string]$line
        if ([string]::IsNullOrEmpty($script:ScanTranscript)) {
            $script:ScanTranscript = $text
        } else {
            $script:ScanTranscript += "`r`n$text"
        }
        if ($script:ScanTranscript.Length -gt $script:ScanTranscriptLimit) {
            $script:ScanTranscript = $script:ScanTranscript.Substring($script:ScanTranscript.Length - $script:ScanTranscriptLimit)
        }
        foreach ($marker in $script:ScanPhaseMarkers) {
            if ($text.IndexOf($marker, [System.StringComparison]::Ordinal) -ge 0) {
                $window.FindName('ScanPhaseText').Text = Get-Text $script:ScanPhaseTextKeys[$marker]
                break
            }
        }
    }
    if ($added) { $window.FindName('ScanOutput').Text = $script:ScanTranscript }
}

function Receive-GuiScanOutput {
    param($job)
    $lines = @(Read-GuiBackgroundJob $job)
    Add-GuiScanOutput -Lines $lines
    return $lines
}

function Read-GuiBackgroundJob {
    param($Job)
    return @(Receive-Job $Job -ErrorAction SilentlyContinue)
}

function Invoke-GuiBackgroundJobStop {
    param($Job)
    Stop-Job $Job -ErrorAction SilentlyContinue
}

function Invoke-GuiBackgroundJobRemoval {
    param($Job)
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
}

function Invoke-GuiTimerStop {
    param($Timer)
    if ($null -ne $Timer) {
        try { $Timer.Stop() } catch { $null = $_ }
    }
}

function Invoke-GuiScanJobRemoval {
    param($Job)
    if ($null -eq $Job) { return }
    if ($Job.State -notin @('Completed','Failed','Stopped')) {
        try { Invoke-GuiBackgroundJobStop $Job } catch { $null = $_ }
    }
    try { Invoke-GuiBackgroundJobRemoval $Job } catch { $null = $_ }
}

function Invoke-GuiScanResourceCleanup {
    param($Job, $CheckTimer, $ScanTimer)
    Invoke-GuiTimerStop $CheckTimer
    Invoke-GuiTimerStop $ScanTimer
    Invoke-GuiScanJobRemoval $Job
    $script:ScanJob = $null
    $script:ScanCheckTimer = $null
    $script:ScanTimer = $null
}

function Show-GuiScanError {
    param([string]$Status, [string]$Detail)
    $window.FindName('ScanProgress').IsIndeterminate = $false
    $window.FindName('BtnStartScan').IsEnabled = $true
    $window.FindName('ErrorSummaryText').Text = ((Get-Text 'ScanErrorSummary') -f $Status)
    $window.FindName('ErrorMutationText').Text = (Get-Text 'ScanNoMutation')
    $window.FindName('ErrorDetailText').Text = $Detail
    Set-GuiState error
}

function Complete-ScanPoll {
    param($job, $checkTimer, $scanTimer)
    if ($job.State -notin @('Completed','Failed','Stopped')) { return $false }
    Invoke-GuiTimerStop $checkTimer
    Invoke-GuiTimerStop $scanTimer
    $result = $script:ScanTranscript
    try {
        $null = Receive-GuiScanOutput $job
        $result = $script:ScanTranscript
        $window.FindName('ScanProgress').IsIndeterminate = $false
        $window.FindName('BtnStartScan').IsEnabled = $true
        $window.FindName('ScanOutput').Text = [string]$result
        if ($job.State -eq 'Completed') {
            $items = @(Get-PendingViewItems)
            $summary = Get-GuiItemSummary $items
            $window.FindName('ResultSummaryText').Text = ((Get-Text 'ScanResultSummary') -f $summary.executable, $summary.observation)
            Set-GuiState results
        } else {
            Show-GuiScanError -Status ([string]$job.State) -Detail ([string]$result)
        }
    } catch {
        $detail = if ([string]::IsNullOrEmpty($result)) { $_.Exception.ToString() } else { "$result`r`n$($_.Exception)" }
        Show-GuiScanError -Status (Get-Text 'ScanStatusResults') -Detail $detail
    } finally {
        Invoke-GuiScanJobRemoval $job
        $script:ScanJob = $null
        $script:ScanCheckTimer = $null
        $script:ScanTimer = $null
        $window.FindName('ScanProgress').IsIndeterminate = $false
        $window.FindName('BtnStartScan').IsEnabled = $true
    }
    return $true
}

function Invoke-GuiScanPoll {
    param($job, $checkTimer, $scanTimer)
    try {
        $null = Receive-GuiScanOutput $job
        return (Complete-ScanPoll -job $job -checkTimer $checkTimer -scanTimer $scanTimer)
    } catch {
        Invoke-GuiScanResourceCleanup -Job $job -CheckTimer $checkTimer -ScanTimer $scanTimer
        Show-GuiScanError -Status (Get-Text 'ScanStatusOutput') -Detail $_.Exception.ToString()
        return $true
    }
}

# v1.5.3: clean 完成后读回 pending_actions.json 状态机统计 (不信任"进程结束=成功")
# v1.5.5: 支持 -Path 读自定义清单 (GUI 勾选子集临时文件)
function Get-CleanResultSummary {
    param([string]$Path = '')
    $items = @(Get-PendingItems -Path $Path)
    $sum = @{ success = 0; failed = 0; skipped = 0; manual_required = 0; pending = 0 }
    foreach ($i in $items) {
        $s = if ($i.status) { $i.status.ToString() } else { 'pending' }
        if ($sum.ContainsKey($s)) { $sum[$s]++ } else { $sum['pending']++ }
    }
    return $sum
}

# ---------- 语言切换 ----------
$window.FindName('BtnLang').Add_Click({
    if ($script:Lang -eq 'zh') { $script:Lang = 'en' } else { $script:Lang = 'zh' }
    Apply-Language
})

# ---------- 扫描 (后台 job + 真实阶段输出) ----------
$script:ScanTimer = $null
$script:ScanCheckTimer = $null
$script:ScanJob = $null
$script:ScanJobScript = {
    param($scriptPath)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode scan 2>&1
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) { throw "Scanner process exited with code $nativeExitCode." }
}
function Start-GuiScan {
    $script:ScanJob = $null
    $script:ScanCheckTimer = $null
    $script:ScanTimer = $null
    try {
        Set-GuiState scanning
        $window.FindName('ScanProgress').IsIndeterminate = $true
        $window.FindName('ScanPhaseText').Text = (Get-Text 'ScanPhaseInitial')
        $window.FindName('ScanOutput').Text = (Get-Text 'Scanning')
        $window.FindName('BtnStartScan').IsEnabled = $false
        $script:ScanTranscript = ''

        $script:ScanJob = Start-Job -ScriptBlock $script:ScanJobScript -ArgumentList (Join-Path $script:Root 'cpu-cleaner.ps1')

        $script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:ScanTimer.Add_Tick({
            $null = Invoke-GuiScanPoll -job $script:ScanJob -checkTimer $script:ScanCheckTimer -scanTimer $script:ScanTimer
        })
        $script:ScanTimer.Start()

        $script:ScanCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ScanCheckTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $script:ScanCheckTimer.Add_Tick({
            $null = Invoke-GuiScanPoll -job $script:ScanJob -checkTimer $script:ScanCheckTimer -scanTimer $script:ScanTimer
        })
        $script:ScanCheckTimer.Start()
        return $true
    } catch {
        Invoke-GuiScanResourceCleanup -Job $script:ScanJob -CheckTimer $script:ScanCheckTimer -ScanTimer $script:ScanTimer
        Show-GuiScanError -Status (Get-Text 'ScanStatusStart') -Detail $_.Exception.ToString()
        return $false
    }
}

$window.FindName('BtnStartScan').Add_Click({ Start-GuiScan })
$window.FindName('BtnRetry').Add_Click({ Start-GuiScan })
$window.FindName('BtnOpenReview').Add_Click({
    $items = @(Get-PendingViewItems)
    $list = $window.FindName('PendingList')
    $list.ItemsSource = $null
    $list.ItemsSource = $items
    $list.Items.Refresh()
    Set-GuiState review
})

# ---------- 读取处理建议 (v1.5.5: 勾选视图 — 风险/实测/建议标签 + 默认勾选 + 全选/清空) ----------
$legacyBtnLoadPending = $window.FindName('BtnLoadPending')
if ($legacyBtnLoadPending) { $legacyBtnLoadPending.Add_Click({
    $list = $window.FindName('PendingList')
    $hint = $window.FindName('PendingHint')
    $items = @(Get-PendingViewItems)
    if ($items.Count -eq 0) {
        $hint.Text = (Get-Text 'PendingNone')
        $list.ItemsSource = $null
        $list.Items.Clear()
    } else {
        $hint.Text = ((Get-Text 'PendingCount') -f $items.Count)
        $list.ItemsSource = $null
        $list.ItemsSource = $items
        $list.Items.Refresh()
    }
}) }

# v1.5.5: 全选 / 清空 勾选 (v1.5.6: 全选跳过观察项 CanExecute=false)
$window.FindName('BtnSelectAll').Add_Click({
    Set-AllChecked $window.FindName('PendingList') $true
    $window.FindName('PendingList').Items.Refresh()
})
$window.FindName('BtnClearAll').Add_Click({
    Set-AllChecked $window.FindName('PendingList') $false
    $window.FindName('PendingList').Items.Refresh()
})

# ---------- 处理已勾选项目 (v1.5.5: 勾选子集 → 临时清单 → clean -PendingFileArg) ----------
function Invoke-GuiCheckedExecution {
    param(
        $List = $window.FindName('PendingList'),
        $Hint = $window.FindName('ExecHint'),
        $Out = $window.FindName('ExecOutput')
    )
    $checked = @($list.Items | Where-Object { $_.IsChecked -and $_.CanExecute })
    if ($checked.Count -eq 0) {
        $hint.Text = (Get-Text 'ExecEmpty')
        return
    }
    $hint.Text = ((Get-Text 'ExecStart') -f $checked.Count)
    $tmpPending = $null
    try {
        # 构造勾选子集临时清单 (完整 payload 结构, 只含勾选条目; suspicious 原样带上)
        $srcPendingPath = Join-Path $script:Root 'pending_actions.json'
        $src = $null
        if (Test-Path $srcPendingPath) {
            $src = Get-Content $srcPendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $payload = New-PendingSubsetPayload -Checked $checked -SourcePending $src
        if (-not $payload) { throw '无法生成 pending 子集。请重新运行 scan 生成新清单。' }
        $tmpPending = Join-Path $env:TEMP ("shushu_pending_" + [guid]::NewGuid().ToString('N') + ".json")
        $json = ConvertTo-GuiPendingJson -InputObject $payload
        [System.IO.File]::WriteAllText($tmpPending, $json, (New-Object System.Text.UTF8Encoding($true)))

        $proc = Start-Process powershell -Verb RunAs -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','clean','-YesToAll','-PendingFileArg',"`"$tmpPending`""
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            # v1.5.3: 管理员进程异常退出 (UAC 取消会抛异常, 走到 catch; 非 0 = 脚本内致命错误)
            $msg = (Get-Text 'ExecFailed') -f $proc.ExitCode
            $hint.Text = $msg
            $out.Text = $msg
            return
        }
        # v1.5.3: 读回状态机统计 (从勾选子集临时文件, 不信任"进程结束=成功")
        $sum = Get-CleanResultSummary -Path $tmpPending
        # v1.5.5: 把子集处理结果同步回主清单, 避免下次加载仍是 pending
        Merge-PendingStatus $tmpPending
        $lines = @(
            (Get-Text 'ExecDone'),
            '',
            ('结果汇总 (处理 {0} 项):' -f $checked.Count),
            "  success: $($sum.success)",
            "  failed:  $($sum.failed)",
            "  skipped: $($sum.skipped)",
            "  manual:  $($sum.manual_required)"
        )
        $latest = Get-ChildItem (Join-Path $script:Root 'backups') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { $lines += ''; $lines += "备份目录: backups\$($latest.Name)" }
        $hint.Text = ((Get-Text 'ExecDoneSum') -f $sum.success, $sum.failed, $sum.skipped)
        $out.Text = ($lines -join "`r`n")
    } catch {
        $message = "ERR: $($_.Exception.Message)"
        $hint.Text = $message
        $out.Text = $message
    } finally {
        if ($tmpPending -and (Test-Path -LiteralPath $tmpPending)) {
            Remove-Item -LiteralPath $tmpPending -Force -ErrorAction SilentlyContinue
        }
    }
}

$legacyBtnExec = $window.FindName('BtnExec')
if ($legacyBtnExec) {
    $legacyBtnExec.Add_Click({ Invoke-GuiCheckedExecution })
}

# ---------- 查看最近结果 ----------
$legacyBtnResult = $window.FindName('BtnResult')
if ($legacyBtnResult) { $legacyBtnResult.Add_Click({
    $out = $window.FindName('ResultOutput')
    $backupRoot = Join-Path $script:Root 'backups'
    if (-not (Test-Path $backupRoot)) { $out.Text = (Get-Text 'NoBackup'); return }
    $latest = Get-ChildItem $backupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { $out.Text = (Get-Text 'NoBackup'); return }
    $mf = Join-Path $latest.FullName 'manifest.json'
    if (-not (Test-Path $mf)) { $out.Text = "manifest not found: $mf"; return }
    $man = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines = @("latest: $($latest.Name)", '')
    $ok = 0; $bad = 0
    foreach ($m in $man) {
        $v = if ($m.verified) { 'OK' } else { 'FAIL' }
        $lines += "  [$v] $($m.type) $($m.name)"
        if ($m.verified) { $ok++ } else { $bad++ }
    }
    $lines += ''; $lines += "success $ok, failed $bad"
    $lines += ''; $lines += "restore: cpu-cleaner.ps1 -Mode restore -BackupDir `".\backups\$($latest.Name)`""
    $out.Text = ($lines -join "`r`n")
}) }

# ---------- 恢复最近一次处理 ----------
$window.FindName('BtnRestore').Add_Click({
    $backupRoot = Join-Path $script:Root 'backups'
    $latest = Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        [System.Windows.MessageBox]::Show((Get-Text 'RestoreNone'), (Get-Text 'AppName'), 'OK', 'Information') | Out-Null
        return
    }
    try {
        $proc = Start-Process powershell -Verb RunAs -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','restore','-BackupDir',"`"$script:Root\backups\$($latest.Name)`""
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
            [System.Windows.MessageBox]::Show(((Get-Text 'RestoreOk') -f $latest.Name), (Get-Text 'AppName'), 'OK', 'Information') | Out-Null
        } elseif ($proc.ExitCode -eq 2) {
            # v1.5.3: CLI restore 执行后验证有失败
            [System.Windows.MessageBox]::Show((Get-Text 'RestorePartial'), (Get-Text 'AppName'), 'OK', 'Warning') | Out-Null
        } else {
            [System.Windows.MessageBox]::Show(((Get-Text 'RestoreErr') -f "ExitCode=$($proc.ExitCode)"), (Get-Text 'AppName'), 'OK', 'Warning') | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show(((Get-Text 'RestoreErr') -f $_.Exception.Message), (Get-Text 'AppName'), 'OK', 'Warning') | Out-Null
    }
})

Set-GuiState -Name idle -Force
Apply-Language
if ($script:TestMode) {
    # 测试模式: 不显示窗口, 暴露窗口对象供 Pester 无窗口断言
    $script:TestWindow = $window
} else {
    $window.ShowDialog() | Out-Null
}
