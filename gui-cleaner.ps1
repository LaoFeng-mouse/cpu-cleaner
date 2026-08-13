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
        AppName='鼠鼠cleaner'; SubTitle='识别可以宽，执行必须窄'; Privilege='普通权限'; Hint0='图形界面只是壳，核心逻辑与命令行版一致'
        Stage1='1 轻盈幻想'; Stage2='2 看清现实'; Stage3='3 谨慎整理'; Stage4='4 幻想落地'
        IdleBody='扫描只读，不会修改系统。'; ResultsNoMutation='目前尚未修改任何内容。'; ExecutingBody='正在逐项处理；每项均会备份并复核。'
        BtnStartScan='开始安全扫描'; BtnOpenReview='查看处理建议'; BtnSkipReview='这次先不处理'; BtnExecute='处理已选择项目'; BtnRescan='重新扫描'; BtnRetry='重试'
        ResultStatus='扫描完成，发现需要关注的项目'; ResultStatusEmpty='扫描完成，未发现匹配项'; ResultStatusDegraded='扫描完成，但扫描信息不完整'; ResultHeadlinePrefix='抓到 '; ResultHeadlineSuffix=' 个偷偷常驻的后台'; ResultHeadlineEmpty='这次没有抓到偷偷常驻的后台'; ResultHeadlineDegraded='部分信息使用兼容方式读取，暂不能判断电脑是否干净'; ResultsEvidence='专业证据与服务名称（点击展开）'; ResultsEvidenceEmpty='没有可展示的匹配证据。'; ScanResultDegradedSuffix='；部分分类使用兼容采集'
        SelectAll='选择全部安全项'; ClearAll='清空选择'; ReviewBoundary='观察项不会自动执行；执行前将再次验证。'; SuspiciousBoundary='可疑进程：只结束本次进程，不删除文件或关闭自启。'; SuspiciousHint='默认不勾选；执行前会复核 PID、名称、路径和启动时间。'; BtnStopProcesses='一次性结束已选进程'; TechnicalDetails='技术详情'; ErrorDetails='查看技术详情'
        TabScan='🐹 1. 扫描（只读）'; TabPending='📋 2. 处理建议'; TabExec='⚙️ 3. 执行（管理员）'; TabResult='✅ 4. 结果与恢复'
        BtnScan='开始扫描'; ScanHint='扫描只查看、不改任何设置，随便点'; Scanning='正在扫描，请稍候…'
        ScanPhaseInitial='正在检查服务、启动项、计划任务和进程'; ScanPhaseSystemInfo='读取系统信息'; ScanPhaseProcesses='检查高占用进程'; ScanPhaseServices='检查系统服务'; ScanPhaseAutoStart='检查启动项'; ScanPhaseTasks='检查计划任务'; ScanPhaseRules='匹配安全规则'; ScanPhaseReport='生成扫描报告'
        ScanResultSummary='{0} 项可以安全处理，{1} 项建议观察'; ScanErrorSummary='扫描失败：{0}'; ScanNoMutation='扫描阶段未修改任何系统设置。'; ScanStatusStart='启动'; ScanStatusOutput='输出读取'; ScanStatusResults='结果处理'
        ReviewErrorSummary='待处理清单已过期，必须重新扫描。'; ReviewNoMutation='没有执行任何系统修改。'
        BtnLoad='读取待处理清单'; PendingHint='按风险/实测展示，勾选要处理的项目（未实测=仅观察，默认不勾选）'; PendingNone='没有待处理项目——请先到【1. 扫描】页扫描（或已全部处理完）'; PendingCount='共 {0} 项待处理。勾选后到【3. 执行】页处理。'
        ExecInfo1='在【2. 处理建议】页勾选要处理的项目，到这里一键执行。'; ExecInfo2='每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。'
        BtnExec='处理已勾选项目（需要管理员）'; ExecEmpty='请先勾选要处理的项目（【2. 处理建议】页勾选）。'; ExecStart='将处理 {0} 项。已请求管理员权限，请在弹窗点【是】…'; ExecDone='处理窗口已结束。到【4. 结果】页查看（建议重启电脑让改动完全生效）。'
        ExecFailed='执行失败: ExitCode={0}（可能被取消或出错）'; ExecDoneSum='执行完成: success {0} / failed {1} / skipped {2} / manual {3}'; ExecCloseBlocked='管理员处理仍在启动、运行或状态未知，暂不能关闭窗口。'; ExecStatusUnknown='管理员进程状态未知'
        ExecUnauthorized='未授权、未开始处理。'; ExecNotStarted='管理员授权未完成，未开始处理，系统设置没有变化。'; ExecPartialPossible='执行进程异常结束，可能已有部分动作执行。'; ExecResultReadFailed='无法完整读取逐项结果。'
        BtnResult='查看最近处理结果'; BtnRestore='恢复最近一次处理'; ResultHint='恢复会弹管理员窗口，选最新备份还原'
        NoBackup='还没有备份记录（还没处理过）。'; RestoreOk='已恢复最近的可信备份。'; RestoreNone='没有通过安全验证的可信备份。'; RestoreErr='恢复失败: {0}'; RestorePartial='恢复已执行，但部分条目验证失败。'; RestoreNotStarted='管理员授权未完成，恢复没有开始。'; RestoreStatusUnknown='恢复进程已启动，状态未知，可能已发生部分修改。'; RestoreMayHaveChanged='恢复进程异常结束，部分设置可能已经改变。'; LegacyBackupUnsupported='旧版项目目录备份不可自动恢复，请重新执行一次安全处理生成可信备份。'
        AutoStage1='轻盈幻想阶段插图'; AutoStage2='看清现实阶段插图'; AutoStage3='谨慎整理阶段插图'; AutoStage4='幻想落地阶段插图'; AutoResult='扫描结果摘要'; AutoCompleted='处理或恢复结果摘要'; AutoError='错误摘要'
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
        AppName='Shushu Cleaner'; SubTitle='Detection may be broad; execution must be narrow'; Privilege='Standard privileges'; Hint0='GUI is a shell; core logic is identical to CLI'
        Stage1='1 Light fantasy'; Stage2='2 Face reality'; Stage3='3 Tidy carefully'; Stage4='4 Fantasy delivered'
        IdleBody='Scanning is read-only and changes no system settings.'; ResultsNoMutation='Nothing has been changed yet.'; ExecutingBody='Processing item by item; each action is backed up and verified.'
        BtnStartScan='Start safe scan'; BtnOpenReview='Review recommendations'; BtnSkipReview='Not this time'; BtnExecute='Process selected items'; BtnRescan='Scan again'; BtnRetry='Retry'
        ResultStatus='Scan complete — items need attention'; ResultStatusEmpty='Scan complete — no matching items found'; ResultStatusDegraded='Scan complete, but some scan information is incomplete'; ResultHeadlinePrefix='Found '; ResultHeadlineSuffix=' resident background items'; ResultHeadlineEmpty='No resident background items found this time'; ResultHeadlineDegraded='Compatibility collection was used; this scan cannot declare the PC clean'; ResultsEvidence='Evidence and service names (expand)'; ResultsEvidenceEmpty='No matcher evidence to display.'; ScanResultDegradedSuffix='; some categories used compatibility collection'
        SelectAll='Select all safe items'; ClearAll='Clear selection'; ReviewBoundary='Observation items never run automatically; every action is revalidated.'; SuspiciousBoundary='Suspicious processes: stop this instance only; do not delete files or disable startup.'; SuspiciousHint='Unchecked by default; PID, name, path, and start time are revalidated.'; BtnStopProcesses='Stop selected once'; TechnicalDetails='Technical details'; ErrorDetails='View technical details'
        TabScan='🐹 1. Scan (read-only)'; TabPending='📋 2. Recommendations'; TabExec='⚙️ 3. Execute (admin)'; TabResult='✅ 4. Result & Restore'
        BtnScan='Start Scan'; ScanHint='Scan only reads, changes nothing'; Scanning='Scanning, please wait…'
        ScanPhaseInitial='Checking services, startup items, scheduled tasks, and processes'; ScanPhaseSystemInfo='Reading system information'; ScanPhaseProcesses='Checking high-usage processes'; ScanPhaseServices='Checking system services'; ScanPhaseAutoStart='Checking startup items'; ScanPhaseTasks='Checking scheduled tasks'; ScanPhaseRules='Matching safety rules'; ScanPhaseReport='Generating scan report'
        ScanResultSummary='{0} safe item(s), {1} observation(s)'; ScanErrorSummary='Scan failed: {0}'; ScanNoMutation='The scan did not change any system settings.'; ScanStatusStart='startup'; ScanStatusOutput='output read'; ScanStatusResults='result processing'
        ReviewErrorSummary='The pending review is stale and must be rescanned.'; ReviewNoMutation='No system settings were changed.'
        BtnLoad='Load Pending Items'; PendingHint='Risk & evidence shown; check items to process (unverified = observe only, unchecked)'; PendingNone='No pending items — run Scan first (or all done)'; PendingCount='{0} item(s) pending. Check items, then go to tab 3.'
        ExecInfo1='Check items in tab 2, then process them here.'; ExecInfo2='Every action is backed up and verified. UAC popup: click YES.'
        BtnExec='Process Checked Items (admin)'; ExecEmpty='Check items first (tab 2).'; ExecStart='Processing {0} item(s). UAC requested, click YES…'; ExecDone='Processing done. See tab 4 (restart PC recommended).'
        ExecFailed='Execution failed: ExitCode={0} (cancelled or error)'; ExecDoneSum='Done: success {0} / failed {1} / skipped {2} / manual {3}'; ExecCloseBlocked='The elevated operation is starting, running, or has unknown status. Keep this window open.'; ExecStatusUnknown='Elevated process status is unknown'
        ExecUnauthorized='Not authorized; processing did not start.'; ExecNotStarted='Administrator authorization was not completed. Processing did not start and no system settings changed.'; ExecPartialPossible='The execution process ended abnormally; some actions may already have run.'; ExecResultReadFailed='The per-item result could not be read completely.'
        BtnResult='Show Latest Result'; BtnRestore='Restore Last Changes'; ResultHint='Restore opens admin window, picks newest backup'
        NoBackup='No backup yet (nothing processed).'; RestoreOk='Restored the latest trusted backup.'; RestoreNone='No backup passed the trust validation.'; RestoreErr='Restore failed: {0}'; RestorePartial='Restore ran, but some items failed verification.'; RestoreNotStarted='Administrator authorization was not completed; restore did not start.'; RestoreStatusUnknown='The restore process started, but its status is unknown; partial changes may already have occurred.'; RestoreMayHaveChanged='The restore process ended abnormally; some settings may already have changed.'; LegacyBackupUnsupported='Legacy project-folder backups cannot be restored automatically. Run one safe cleanup to create a trusted backup.'
        AutoStage1='Light fantasy stage illustration'; AutoStage2='Face reality stage illustration'; AutoStage3='Careful cleanup stage illustration'; AutoStage4='Fantasy delivered stage illustration'; AutoResult='Scan result summary'; AutoCompleted='Cleanup or restore result summary'; AutoError='Error summary'
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

function Set-GuiCompletedSummary {
    param(
        [int]$Success = 0,
        [int]$Failed = 0,
        [int]$Skipped = 0,
        [int]$Manual = 0,
        [string]$Text = ''
    )
    $control = $window.FindName('CompletedSummaryText')
    $control.Text = if ([string]::IsNullOrEmpty($Text)) {
        (Get-Text 'ExecDoneSum') -f $Success, $Failed, $Skipped, $Manual
    } else {
        $Text
    }
    $control.Foreground = if ($Failed -gt 0) { $window.Resources['Danger'] } else { $window.Resources['Ink'] }
}

function Set-GuiResultSummary {
    param(
        [int]$Executable,
        [int]$Observation,
        [string[]]$Evidence = @(),
        [bool]$Degraded = $false,
        [string[]]$Warnings = @()
    )
    $script:LastResultExecutable = $Executable
    $script:LastResultObservation = $Observation
    $script:LastResultEvidence = @($Evidence)
    $script:LastResultDegraded = $Degraded
    $script:LastResultWarnings = @($Warnings)
    $total = $Executable + $Observation
    $window.FindName('ResultStatusText').Text = Get-Text $(if ($Degraded) { 'ResultStatusDegraded' } elseif ($total -eq 0) { 'ResultStatusEmpty' } else { 'ResultStatus' })
    $window.FindName('ResultHeadlinePrefix').Text = Get-Text $(if ($Degraded -and $total -eq 0) { 'ResultHeadlineDegraded' } elseif ($total -eq 0) { 'ResultHeadlineEmpty' } else { 'ResultHeadlinePrefix' })
    $window.FindName('ResultHeadlineCount').Text = if ($total -eq 0) { '' } else { [string]$total }
    $window.FindName('ResultHeadlineSuffix').Text = if ($total -eq 0) { '' } else { Get-Text 'ResultHeadlineSuffix' }
    $summaryText = (Get-Text 'ScanResultSummary') -f $Executable, $Observation
    if ($Degraded) { $summaryText += Get-Text 'ScanResultDegradedSuffix' }
    $window.FindName('ResultSummaryText').Text = $summaryText
    $details = @($Evidence) + @($Warnings | ForEach-Object { '⚠ ' + $_ })
    $window.FindName('ResultEvidenceText').Text = if ($details.Count -gt 0) { $details -join [Environment]::NewLine } else { Get-Text 'ResultsEvidenceEmpty' }
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
    if ([string]::IsNullOrEmpty($TitleText)) { $TitleText = Get-Text ('State_{0}_Title' -f $StateName) }
    if ([string]::IsNullOrEmpty($SubtitleText)) { $SubtitleText = Get-Text ('State_{0}_Sub' -f $StateName) }
    $TitleControl.Text = $TitleText
    $SubtitleControl.Text = $SubtitleText
}

function Apply-Language {
    $t = $script:I18N[$script:Lang]
    $w = $window
    $w.Title = $t['AppName']
    $w.FindName('TitleMain').Text = $t['AppName']
    $w.FindName('TitleSub').Text = $t['SubTitle']
    $w.FindName('PrivilegeText').Text = $t['Privilege']
    $w.FindName('BtnLang').Content = $t['LangLabel']
    foreach ($entry in @(
        @('StageLabel1','Stage1'), @('StageLabel2','Stage2'), @('StageLabel3','Stage3'), @('StageLabel4','Stage4'),
        @('IdleBodyText','IdleBody'), @('ResultsNoMutationText','ResultsNoMutation'), @('ExecutingBodyText','ExecutingBody'),
        @('ResultStatusText','ResultStatus'), @('ResultHeadlinePrefix','ResultHeadlinePrefix'), @('ResultHeadlineSuffix','ResultHeadlineSuffix'), @('ResultsEvidenceExpander','ResultsEvidence'),
        @('BtnStartScan','BtnStartScan'), @('BtnOpenReview','BtnOpenReview'), @('BtnSkipReview','BtnSkipReview'), @('BtnExecute','BtnExecute'), @('BtnRescan','BtnRescan'), @('BtnRetry','BtnRetry'), @('BtnRestore','BtnRestore'),
        @('BtnSelectAll','SelectAll'), @('BtnClearAll','ClearAll'), @('ReviewBoundaryText','ReviewBoundary'),
        @('SuspiciousBoundaryText','SuspiciousBoundary'), @('SuspiciousSelectionHint','SuspiciousHint'), @('BtnStopProcesses','BtnStopProcesses')
    )) {
        $control = $w.FindName($entry[0])
        if ($null -eq $control) { throw "GUI control missing: $($entry[0])" }
        if ($control -is [System.Windows.Controls.TextBlock]) { $control.Text = $t[$entry[1]] }
        elseif ($control -is [System.Windows.Controls.Expander]) { $control.Header = $t[$entry[1]] }
        else { $control.Content = $t[$entry[1]] }
    }
    $w.Resources['TechnicalDetailsText'] = $t['TechnicalDetails']
    $w.Resources['ErrorDetailsText'] = $t['ErrorDetails']
    $automationKeys = @{
        ImgStage1='AutoStage1'; ImgStage2='AutoStage2'; ImgStage3='AutoStage3'; ImgStage4='AutoStage4'
        BtnStartScan='BtnStartScan'; BtnOpenReview='BtnOpenReview'; BtnSkipReview='BtnSkipReview'; BtnExecute='BtnExecute'; BtnStopProcesses='BtnStopProcesses'; BtnRescan='BtnRescan'; BtnRetry='BtnRetry'; BtnRestore='BtnRestore'; BtnLang='LangLabel'
        ResultSummaryText='AutoResult'; CompletedSummaryText='AutoCompleted'; ErrorSummaryText='AutoError'
    }
    foreach ($name in $automationKeys.Keys) {
        [System.Windows.Automation.AutomationProperties]::SetName($w.FindName($name), $t[$automationKeys[$name]])
    }
    Update-GuiStateText -StateName $script:GuiState -TitleControl ($w.FindName('StateTitle')) -SubtitleControl ($w.FindName('StateSubtitle'))
    if ($script:GuiState -eq 'scanning' -and -not [string]::IsNullOrWhiteSpace($script:CurrentScanPhaseTextKey)) {
        $w.FindName('ScanPhaseText').Text = Get-Text $script:CurrentScanPhaseTextKey
    }
    if ($script:GuiState -eq 'results') {
        Set-GuiResultSummary -Executable $script:LastResultExecutable -Observation $script:LastResultObservation -Evidence $script:LastResultEvidence -Degraded $script:LastResultDegraded -Warnings $script:LastResultWarnings
    }
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
$script:LastResultExecutable = 0
$script:LastResultObservation = 0
$script:LastResultEvidence = @()
$script:LastResultDegraded = $false
$script:LastResultWarnings = @()
$script:ReviewedPendingSnapshot = $null
$script:ReviewedPendingGenerationSha256 = $null
$emptyReviewedActionKeys = [System.Collections.Generic.List[string]]::new()
$script:ReviewedActionIdentityKeys = $emptyReviewedActionKeys.AsReadOnly()
$emptyReviewedSuspiciousKeys = [System.Collections.Generic.List[string]]::new()
$script:ReviewedSuspiciousIdentityKeys = $emptyReviewedSuspiciousKeys.AsReadOnly()
$script:ExecutionProcess = $null
$script:ExecutionTimer = $null
$script:ExecutionTempPath = $null
$script:ExecutionActions = @()
$script:ExecutionInProgress = $false
$script:RestoreInProgress = $false
$script:ExecutionLifecycle = 'idle'
$script:ExecutionUnknownProbeCount = 0
$script:ExecutionUnknownProbeLimit = 3
$script:SuspiciousStopProcess = $null
$script:SuspiciousStopTimer = $null
$script:SuspiciousStopTempPath = $null
$script:SuspiciousStopRows = @()
$script:SuspiciousStopInProgress = $false
$script:SuspiciousStopLifecycle = 'idle'
$script:SuspiciousStopUnknownProbeCount = 0
$script:StatePanels = @('IdlePanel','ScanningPanel','ResultsPanel','ReviewPanel','ExecutingPanel','CompletedPanel','ErrorPanel')

function Update-GuiExecuteAvailability {
    param($List = $window.FindName('PendingList'))
    $selectedExecutable = @($List.Items | Where-Object {
        ($_.CanExecute -is [bool]) -and $_.CanExecute -and
        ($_.IsChecked -is [bool]) -and $_.IsChecked
    })
    $window.FindName('BtnExecute').IsEnabled = ($selectedExecutable.Count -gt 0 -and -not $script:ExecutionInProgress -and -not $script:SuspiciousStopInProgress)
}

function Update-GuiStopProcessAvailability {
    param($List = $window.FindName('SuspiciousList'))
    $selected = @($List.Items | Where-Object {
        ($_.CanStop -is [bool]) -and $_.CanStop -and
        ($_.IsChecked -is [bool]) -and $_.IsChecked
    })
    $window.FindName('BtnStopProcesses').IsEnabled = ($selected.Count -gt 0 -and -not $script:SuspiciousStopInProgress -and -not $script:ExecutionInProgress)
}

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

    $stateHeader = $window.FindName('StateHeader')
    $titleControl = $window.FindName('StateTitle')
    $subtitleControl = $window.FindName('StateSubtitle')
    if ($null -eq $stateHeader) { throw 'GUI control missing: StateHeader' }
    if ($null -eq $titleControl) { throw 'GUI control missing: StateTitle' }
    if ($null -eq $subtitleControl) { throw 'GUI control missing: StateSubtitle' }
    if (-not $stateHeader.PSObject.Properties['Visibility']) { throw 'GUI control invalid: StateHeader.Visibility' }
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
    $previousHeaderVisibility = $stateHeader.Visibility

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
        $stateHeader.Visibility = if ($Name -eq 'results') { 'Collapsed' } else { 'Visible' }
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
        try { $stateHeader.Visibility = $previousHeaderVisibility } catch {}
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

function Copy-GuiSuspiciousForSubset($RawRow) {
    $properties = [ordered]@{}
    foreach ($property in $RawRow.PSObject.Properties) { $properties[$property.Name] = $property.Value }
    $properties['status'] = 'pending'
    return [pscustomobject]$properties
}

function Get-GuiSuspiciousIdentityKey($Item) {
    return ConvertTo-Json -Compress -Depth 3 -InputObject ([ordered]@{
        PID = $Item.PID
        Name = $Item.Name
        Path = $Item.Path
        StartTimeUtc = $Item.StartTimeUtc
    })
}

function Get-GuiValidatedSuspiciousIdentityKeys($Pending) {
    $keys = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in @($Pending.suspicious)) {
        if ($row.CanStop -isnot [bool] -or -not $row.CanStop -or [string]$row.status -cnotin @('pending','failed')) { continue }
        if (($row.PID -isnot [int32] -and $row.PID -isnot [int64]) -or [int64]$row.PID -le 0) { throw 'stoppable suspicious PID is invalid.' }
        foreach ($name in @('Name','Path','StartTimeUtc')) {
            if ($row.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($row.$name)) { throw "stoppable suspicious $name is invalid." }
        }
        if (-not [System.IO.Path]::IsPathRooted([string]$row.Path) -or -not ([string]$row.StartTimeUtc).EndsWith('Z',[System.StringComparison]::Ordinal)) { throw 'stoppable suspicious identity is incomplete.' }
        $key = Get-GuiSuspiciousIdentityKey $row
        if (-not $seen.Add($key)) { throw 'duplicate suspicious identity in reviewed snapshot.' }
        $keys.Add($key)
    }
    return @($keys)
}

function Get-GuiSuspiciousViewItems($Pending) {
    $rows = @()
    if ($null -eq $Pending -or -not $Pending.suspicious) { return @() }
    foreach ($item in @($Pending.suspicious)) {
        $canStop = ($item.CanStop -is [bool]) -and $item.CanStop -and ([string]$item.status -cin @('pending','failed'))
        $rows += [pscustomobject]@{
            IsChecked = $false; CanStop = [bool]$canStop; PID = $item.PID
            PidLabel = 'PID ' + [string]$item.PID; Name = [string]$item.Name
            Path = [string]$item.Path; StartTimeUtc = [string]$item.StartTimeUtc
            Reason = [string]$item.Reason; StopBlockReason = [string]$item.StopBlockReason
            status = [string]$item.status; _raw = $item
        }
    }
    return @($rows)
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

function New-GuiSuspiciousSubsetPayload {
    param($Selected, $SourcePending)
    $pendingVersion = Get-GuiPendingSchemaVersion $SourcePending
    $rows = @()
    foreach ($selectedRow in @($Selected)) {
        $raw = if ($selectedRow.PSObject.Properties['_raw'] -and $null -ne $selectedRow._raw) { $selectedRow._raw } else { $selectedRow }
        $rows += Copy-GuiSuspiciousForSubset $raw
    }
    return [pscustomobject]([ordered]@{
        pending_schema_version = $pendingVersion
        generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions = @()
        observations = @()
        suspicious = @($rows)
    })
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
    param([Parameter(Mandatory=$true)]$Pending)
    $p = $Pending
    $map = Get-ProfileLookup
    $view = @()
    # 1) 可执行项: 默认勾选, 可勾选
    foreach ($i in @($p.actions | Where-Object { $_ -and $_.status -cin @('pending','failed') })) {
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
            matcher_detail    = Format-GuiMatcherDetail $i
            matched_type      = [string]$i.matched_type
            matched_field     = [string]$i.matched_field
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
            matcher_detail    = Format-GuiMatcherDetail $i
            matched_type      = [string]$i.matched_type
            matched_field     = [string]$i.matched_field
            _raw              = $i
        }
    }
    return $view
}

function Get-GuiReviewScalarString {
    param($Item, [string]$PropertyName, [string]$Context)
    $property = if ($null -ne $Item) { $Item.PSObject.Properties[$PropertyName] } else { $null }
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
        throw "pending review shape invalid: $Context.$PropertyName must be a non-empty scalar string."
    }
    return [string]$property.Value
}

function Assert-GuiPendingPresentationRow {
    param($Item, [string]$Branch, [int]$Index)
    $context = "$Branch[$Index]"
    foreach ($propertyName in @('id','name_cn','hit_type','action','matched_pattern','matched_type','matched_field')) {
        $null = Get-GuiReviewScalarString -Item $Item -PropertyName $propertyName -Context $context
    }
    if ($Branch -eq 'actions') {
        $status = Get-GuiReviewScalarString -Item $Item -PropertyName 'status' -Context $context
        if ($status -cnotin @('pending','failed','success','skipped','manual_required')) {
            throw "pending review shape invalid: $context.status must be an exact known status."
        }
        $null = Get-GuiReviewScalarString -Item $Item -PropertyName 'reason_cn' -Context $context
    } else {
        $null = Get-GuiReviewScalarString -Item $Item -PropertyName 'obs_reason' -Context $context
    }

    $hitType = [string]$Item.hit_type
    $allowedMatchedFields = switch ($hitType) {
        'service'   { @('service_name','service_display_name') }
        'autostart' { @('autostart_name','autostart_value') }
        'task'      { @('task_name','task_path') }
        'process'   { @('process_name','process_path') }
        default     { @() }
    }
    if ($allowedMatchedFields.Count -eq 0 -or $Item.matched_field -notin $allowedMatchedFields) {
        throw "pending review shape invalid: $context.matched_field is not compatible with hit_type."
    }

    switch ($hitType) {
        'service' {
            $null = Get-GuiReviewScalarString -Item $Item -PropertyName 'service_name' -Context $context
        }
        'autostart' {
            foreach ($propertyName in @('autostart_source','autostart_name','autostart_value')) {
                $null = Get-GuiReviewScalarString -Item $Item -PropertyName $propertyName -Context $context
            }
        }
        'task' {
            $null = Get-GuiReviewScalarString -Item $Item -PropertyName 'task_path' -Context $context
        }
        'process' {
            foreach ($propertyName in @('process_name','process_path')) {
                $null = Get-GuiReviewScalarString -Item $Item -PropertyName $propertyName -Context $context
            }
            $processIdProperty = $Item.PSObject.Properties['process_id']
            if ($null -eq $processIdProperty -or
                ($processIdProperty.Value -isnot [int32] -and $processIdProperty.Value -isnot [int64]) -or
                [int64]$processIdProperty.Value -le 0) {
                throw "pending review shape invalid: $context.process_id must be a positive scalar integer."
            }
        }
    }
}

function Assert-GuiPendingPresentationShape {
    param([Parameter(Mandatory=$true)]$Pending)
    if ($null -eq $Pending) { throw 'pending review shape invalid: pending object is null.' }
    foreach ($branch in @('actions','observations')) {
        $property = $Pending.PSObject.Properties[$branch]
        if ($null -eq $property -or $property.Value -isnot [System.Array]) {
            throw "pending review shape invalid: $branch must be an array."
        }
        $rows = @($property.Value)
        for ($index = 0; $index -lt $rows.Count; $index++) {
            Assert-GuiPendingPresentationRow -Item $rows[$index] -Branch $branch -Index $index
        }
    }
}

function Get-GuiValidatedActionIdentityKeys {
    param([Parameter(Mandatory=$true)]$Pending)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $selectableKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($action in @($Pending.actions)) {
        $key = Get-PendingIdentityKey $action
        if (-not $seen.Add($key)) {
            throw 'pending review shape invalid: duplicate action identity.'
        }
        if ($action.status -cin @('pending','failed')) {
            $selectableKeys.Add($key)
        }
    }
    foreach ($observation in @($Pending.observations)) {
        if ($seen.Contains((Get-PendingIdentityKey $observation))) {
            throw 'pending review shape invalid: observation identity collides with action identity.'
        }
    }
    return [string[]]$selectableKeys.ToArray()
}

function Read-GuiPendingFile {
    param([string]$Path = '')
    $pendingPath = if ($Path) { $Path } else { Join-Path $script:Root 'pending_actions.json' }
    return Get-Content $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-GuiBytesSha256 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '')
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function ConvertFrom-GuiPendingBytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $offset = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $offset = 3 }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return $utf8.GetString($Bytes, $offset, $Bytes.Length - $offset) | ConvertFrom-Json
}

function Read-GuiPendingByteSnapshot {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $length = $stream.Length
        if ($length -lt 0 -or $length -gt 5MB) { throw 'pending review file size is invalid.' }
        $bytes = New-Object byte[] ([int]$length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -le 0) { throw 'pending review file ended during the single read.' }
            $read += $count
        }
        if ($stream.Length -ne $length) { throw 'pending review file changed during the single read.' }
        return [pscustomobject]@{ Pending=(ConvertFrom-GuiPendingBytes $bytes); Sha256=(Get-GuiBytesSha256 $bytes) }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-GuiLockedStreamBytes {
    param([Parameter(Mandatory=$true)]$Stream)
    $Stream.Position = 0
    $length = $Stream.Length
    if ($length -lt 0 -or $length -gt 5MB) { throw 'pending merge file size is invalid.' }
    $bytes = New-Object byte[] ([int]$length)
    $read = 0
    while ($read -lt $bytes.Length) {
        $count = $Stream.Read($bytes, $read, $bytes.Length - $read)
        if ($count -le 0) { throw 'pending merge file ended during locked read.' }
        $read += $count
    }
    if ($Stream.Length -ne $length) { throw 'pending merge file changed during locked read.' }
    return $bytes
}

function Write-GuiPendingBytesToLockedStream {
    param([Parameter(Mandatory=$true)]$Stream, [Parameter(Mandatory=$true)][byte[]]$Bytes)
    $Stream.Position = 0
    $Stream.SetLength(0)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush($true)
}

function Restore-GuiPendingBytesToLockedStream {
    param([Parameter(Mandatory=$true)]$Stream, [Parameter(Mandatory=$true)][byte[]]$Bytes)
    $Stream.Position = 0
    $Stream.SetLength(0)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush($true)
}

# v1.5.6: 全选/清空 — 全选跳过 CanExecute=false (观察项 checkbox disabled 且不可被全选勾上)
function Set-AllChecked($list, $value) {
    foreach ($it in @($list.Items)) {
        if (-not $value -or $it.CanExecute) { $it.IsChecked = $value }
    }
}

# v1.5.5: 把勾选子集临时文件的处理结果状态合并回主 pending_actions.json
# (clean 处理的是临时子集, 主清单不同步的话下次加载仍是 pending, 用户会看到重复待办)
function Merge-PendingStatus($ExecutionResult) {
    $mainPath = Join-Path $script:Root 'pending_actions.json'
    if (-not (Test-Path -LiteralPath $mainPath) -or $null -eq $ExecutionResult) { throw 'pending merge input is missing.' }
    if ($script:ReviewedPendingGenerationSha256 -isnot [string] -or $script:ReviewedPendingGenerationSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'review generation is missing; refusing pending merge.'
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($mainPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $mainBytes = Read-GuiLockedStreamBytes -Stream $stream
        $currentGeneration = Get-GuiBytesSha256 $mainBytes
        if (-not [string]::Equals($currentGeneration, $script:ReviewedPendingGenerationSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'pending review generation changed; refusing to overwrite a newer scan.'
        }
        $main = ConvertFrom-GuiPendingBytes $mainBytes
        $null = Get-GuiPendingSchemaVersion $main
        if ($null -eq $main.actions -or $null -eq $ExecutionResult.Items) { throw 'pending merge actions are missing.' }

        $mainByKey = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
        foreach ($ma in @($main.actions)) { $mainByKey.Add((Get-PendingIdentityKey $ma), $ma) }
        $executionKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($expectedAction in @($script:ExecutionActions)) { [void]$executionKeys.Add((Get-PendingIdentityKey $expectedAction)) }
        if (@($ExecutionResult.Items).Count -ne $executionKeys.Count) { throw 'pending merge result count does not match this execution.' }
        foreach ($item in @($ExecutionResult.Items)) {
            if ($item -isnot [System.Tuple[string,string]]) { throw 'pending merge result item is not an immutable identity/status pair.' }
            $key = $item.Item1
            $status = $item.Item2
            if (-not $executionKeys.Contains($key)) { throw 'pending merge identity is outside this execution.' }
            if ($status -cnotin @('success','failed','skipped','manual_required')) { throw 'pending merge status is not terminal.' }
            if (-not $mainByKey.ContainsKey($key)) { throw 'pending merge identity is absent from reviewed generation.' }
            $mainByKey[$key].status = $status
        }
        $updatedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-GuiPendingJson -InputObject $main))
        try {
            Write-GuiPendingBytesToLockedStream -Stream $stream -Bytes $updatedBytes
        } catch {
            $writeFailure = $_
            try {
                Restore-GuiPendingBytesToLockedStream -Stream $stream -Bytes $mainBytes
            } catch {
                throw ('pending merge write failed and rollback also failed. Write: {0}; Rollback: {1}' -f $writeFailure.Exception.Message, $_.Exception.Message)
            }
            throw $writeFailure
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
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
$script:CurrentScanPhaseTextKey = 'ScanPhaseInitial'

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
                $script:CurrentScanPhaseTextKey = $script:ScanPhaseTextKeys[$marker]
                $window.FindName('ScanPhaseText').Text = Get-Text $script:CurrentScanPhaseTextKey
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

function Set-GuiError {
    param(
        [Parameter(Mandatory=$true)][string]$Summary,
        [Parameter(Mandatory=$true)][string]$Mutation,
        [AllowEmptyString()][string]$Detail = ''
    )
    $window.FindName('ErrorSummaryText').Text = $Summary
    $window.FindName('ErrorMutationText').Text = $Mutation
    $window.FindName('ErrorDetailText').Text = $Detail
    if ($script:GuiState -ne 'error') { Set-GuiState error }
}

function Show-GuiScanError {
    param([string]$Status, [string]$Detail)
    $window.FindName('ScanProgress').IsIndeterminate = $false
    $window.FindName('BtnStartScan').IsEnabled = $true
    Set-GuiError -Summary ((Get-Text 'ScanErrorSummary') -f $Status) -Mutation (Get-Text 'ScanNoMutation') -Detail $Detail
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
            $pending = Read-GuiPendingFile
            $items = @(Get-PendingViewItems -Pending $pending)
            $summary = Get-GuiItemSummary $items
            $evidence = @($items | ForEach-Object { '{0} — {1}' -f $_.name_cn, ($_.matcher_detail -replace "`r?`n", ' | ') })
            $degraded = $false
            if ($pending.PSObject.Properties.Name -contains 'scan_health' -and $null -ne $pending.scan_health) {
                $degraded = @('system_info','services','tasks' | Where-Object { [string]$pending.scan_health.$_ -ne 'complete' }).Count -gt 0
            }
            $warnings = if ($pending.PSObject.Properties.Name -contains 'scan_warnings') { @($pending.scan_warnings) } else { @() }
            Set-GuiResultSummary -Executable $summary.executable -Observation $summary.observation -Evidence $evidence -Degraded $degraded -Warnings $warnings
            Set-GuiState results
        } else {
            $detail = [string]$result
            $reason = $null
            try { $reason = $job.JobStateInfo.Reason } catch { $reason = $null }
            if ($null -ne $reason -and -not [string]::IsNullOrWhiteSpace([string]$reason)) {
                if (-not [string]::IsNullOrEmpty($detail)) { $detail += "`r`n" }
                $detail += $reason.ToString()
            }
            Show-GuiScanError -Status ([string]$job.State) -Detail $detail
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
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
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
        $script:CurrentScanPhaseTextKey = 'ScanPhaseInitial'

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
function Dismiss-GuiResults {
    $script:ReviewedPendingSnapshot = $null
    $script:ReviewedPendingGenerationSha256 = $null
    $emptyActionKeys = [System.Collections.Generic.List[string]]::new()
    $script:ReviewedActionIdentityKeys = $emptyActionKeys.AsReadOnly()
    $emptySuspiciousKeys = [System.Collections.Generic.List[string]]::new()
    $script:ReviewedSuspiciousIdentityKeys = $emptySuspiciousKeys.AsReadOnly()
    Set-GuiState idle -Force
}
$window.FindName('BtnSkipReview').Add_Click({ Dismiss-GuiResults })
$window.FindName('BtnOpenReview').Add_Click({
    $list = $window.FindName('PendingList')
    $suspiciousList = $window.FindName('SuspiciousList')
    try {
        $pendingPath = Join-Path $script:Root 'pending_actions.json'
        $reviewSnapshot = Read-GuiPendingByteSnapshot -Path $pendingPath
        $pending = $reviewSnapshot.Pending
        $null = Get-GuiPendingSchemaVersion $pending
        Assert-GuiPendingPresentationShape -Pending $pending
        $validatedActionKeys = @(Get-GuiValidatedActionIdentityKeys -Pending $pending)
        $validatedSuspiciousKeys = @(Get-GuiValidatedSuspiciousIdentityKeys -Pending $pending)
        $actionKeyList = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $validatedActionKeys) { $actionKeyList.Add($key) }
        $actionAllowlist = $actionKeyList.AsReadOnly()
        $suspiciousKeyList = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $validatedSuspiciousKeys) { $suspiciousKeyList.Add($key) }
        $suspiciousAllowlist = $suspiciousKeyList.AsReadOnly()
        $items = @(Get-PendingViewItems -Pending $pending)
        $suspiciousItems = @(Get-GuiSuspiciousViewItems -Pending $pending)
        $list.ItemsSource = $null
        $list.ItemsSource = $items
        $list.Items.Refresh()
        $script:ReviewedPendingSnapshot = $pending
        $script:ReviewedPendingGenerationSha256 = $reviewSnapshot.Sha256
        $script:ReviewedActionIdentityKeys = $actionAllowlist
        $script:ReviewedSuspiciousIdentityKeys = $suspiciousAllowlist
        Set-GuiState review
        Update-GuiExecuteAvailability -List $list
        Update-GuiStopProcessAvailability -List $suspiciousList
    } catch {
        $list.ItemsSource = $null
        $list.Items.Clear()
        $suspiciousList.ItemsSource = $null
        $suspiciousList.Items.Clear()
        $script:ReviewedPendingSnapshot = $null
        $script:ReviewedPendingGenerationSha256 = $null
        $emptyActionKeys = [System.Collections.Generic.List[string]]::new()
        $script:ReviewedActionIdentityKeys = $emptyActionKeys.AsReadOnly()
        $emptySuspiciousKeys = [System.Collections.Generic.List[string]]::new()
        $script:ReviewedSuspiciousIdentityKeys = $emptySuspiciousKeys.AsReadOnly()
        Update-GuiExecuteAvailability -List $list
        Update-GuiStopProcessAvailability -List $suspiciousList
        Set-GuiError -Summary (Get-Text 'ReviewErrorSummary') -Mutation (Get-Text 'ReviewNoMutation') -Detail $_.Exception.Message
    }
})

# ---------- 读取处理建议 (v1.5.5: 勾选视图 — 风险/实测/建议标签 + 默认勾选 + 全选/清空) ----------
$legacyBtnLoadPending = $window.FindName('BtnLoadPending')
if ($legacyBtnLoadPending) { $legacyBtnLoadPending.Add_Click({
    $list = $window.FindName('PendingList')
    $hint = $window.FindName('PendingHint')
    $pending = Read-GuiPendingFile
    $items = @(Get-PendingViewItems -Pending $pending)
    if ($items.Count -eq 0) {
        $hint.Text = (Get-Text 'PendingNone')
        $list.ItemsSource = $null
        $list.Items.Clear()
    } else {
        $hint.Text = ((Get-Text 'PendingCount') -f $items.Count)
        $list.ItemsSource = $null
        $list.ItemsSource = $items
        $list.Items.Refresh()
        $suspiciousList.ItemsSource = $null
        $suspiciousList.ItemsSource = $suspiciousItems
        $suspiciousList.Items.Refresh()
    }
    Update-GuiExecuteAvailability -List $list
}) }

# v1.5.5: 全选 / 清空 勾选 (v1.5.6: 全选跳过观察项 CanExecute=false)
$window.FindName('BtnSelectAll').Add_Click({
    Set-AllChecked $window.FindName('PendingList') $true
    $window.FindName('PendingList').Items.Refresh()
    Update-GuiExecuteAvailability
})
$window.FindName('BtnClearAll').Add_Click({
    Set-AllChecked $window.FindName('PendingList') $false
    $window.FindName('PendingList').Items.Refresh()
    Update-GuiExecuteAvailability
})

$script:PendingSelectionChangedHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $eventArgs)
    Update-GuiExecuteAvailability -List $window.FindName('PendingList')
}
$window.FindName('PendingList').AddHandler(
    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    $script:PendingSelectionChangedHandler
)

$script:SuspiciousSelectionChangedHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $eventArgs)
    Update-GuiStopProcessAvailability -List $window.FindName('SuspiciousList')
}
$window.FindName('SuspiciousList').AddHandler(
    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    $script:SuspiciousSelectionChangedHandler
)

function Remove-GuiSuspiciousStopTempFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ([System.IO.Path]::GetFileName($Path) -cnotmatch '^shushu_suspicious_[0-9a-f]{32}\.json$') { return }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Clear-GuiSuspiciousStopResources {
    param([switch]$RemoveTemp, [switch]$ProcessExitConfirmed)
    if ($null -ne $script:SuspiciousStopProcess -and -not $ProcessExitConfirmed) { return $false }
    Invoke-GuiTimerStop $script:SuspiciousStopTimer
    if ($RemoveTemp) { Remove-GuiSuspiciousStopTempFile -Path $script:SuspiciousStopTempPath }
    $script:SuspiciousStopProcess = $null
    $script:SuspiciousStopTimer = $null
    $script:SuspiciousStopTempPath = $null
    $script:SuspiciousStopRows = @()
    $script:SuspiciousStopInProgress = $false
    $script:SuspiciousStopLifecycle = 'idle'
    $script:SuspiciousStopUnknownProbeCount = 0
    Update-GuiStopProcessAvailability
    Update-GuiExecuteAvailability
    return $true
}

function Read-GuiStrictSuspiciousStopResult {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$ExpectedRows)
    $pending = Read-GuiPendingFile -Path $Path
    $null = Get-GuiPendingSchemaVersion $pending
    foreach ($name in @('actions','observations','suspicious')) {
        if ($pending.PSObject.Properties.Name -notcontains $name -or $pending.$name -isnot [System.Array]) { throw "suspicious stop result $name is not an array." }
    }
    if (@($pending.actions).Count -ne 0 -or @($pending.observations).Count -ne 0) { throw 'suspicious stop result crossed the OEM action boundary.' }
    $items = @($pending.suspicious)
    $expected = @($ExpectedRows)
    if ($items.Count -ne $expected.Count) { throw 'suspicious stop result identity count changed.' }
    $expectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $expected) { if (-not $expectedKeys.Add((Get-GuiSuspiciousIdentityKey $row))) { throw 'suspicious expected identity is duplicated.' } }
    $resultKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $items) {
        $key = Get-GuiSuspiciousIdentityKey $row
        if (-not $resultKeys.Add($key) -or -not $expectedKeys.Contains($key)) { throw 'suspicious stop result identity changed.' }
        if ([string]$row.status -cnotin @('success','failed','skipped')) { throw 'suspicious stop result contains a non-terminal status.' }
    }
    return @($items)
}

function Resolve-GuiReviewedSuspiciousRows {
    param($List)
    if ($null -eq $script:ReviewedPendingSnapshot -or $null -eq $script:ReviewedSuspiciousIdentityKeys) { throw 'suspicious reviewed allowlist is unavailable.' }
    $validatedKeys = @(Get-GuiValidatedSuspiciousIdentityKeys $script:ReviewedPendingSnapshot)
    if ($validatedKeys.Count -ne $script:ReviewedSuspiciousIdentityKeys.Count) { throw 'suspicious reviewed allowlist changed.' }
    $byKey = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($row in @($script:ReviewedPendingSnapshot.suspicious)) {
        if ($row.CanStop -is [bool] -and $row.CanStop -and [string]$row.status -cin @('pending','failed')) {
            $key = Get-GuiSuspiciousIdentityKey $row
            if (-not $script:ReviewedSuspiciousIdentityKeys.Contains($key)) { throw 'suspicious reviewed allowlist changed.' }
            $byKey.Add($key,$row)
        }
    }
    $resolved = @()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($view in @($List.Items | Where-Object { $_.IsChecked })) {
        if ($view.CanStop -isnot [bool] -or -not $view.CanStop -or $null -eq $view._raw) { throw 'selected suspicious row is not stoppable.' }
        $key = Get-GuiSuspiciousIdentityKey $view._raw
        if (-not $script:ReviewedSuspiciousIdentityKeys.Contains($key) -or -not $byKey.ContainsKey($key)) { throw 'selected suspicious row is outside the reviewed allowlist.' }
        if (-not $seen.Add($key)) { throw 'selected suspicious identity is duplicated.' }
        $resolved += $byKey[$key]
    }
    return @($resolved)
}

function Complete-SuspiciousStopPoll {
    if ($null -eq $script:SuspiciousStopProcess) { return $false }
    $probe = Get-GuiExecutionProcessStatus -Process $script:SuspiciousStopProcess
    if ($probe.State -eq 'running') { return $false }
    if ($probe.State -eq 'unknown') {
        $script:SuspiciousStopLifecycle = 'unknown'
        $script:SuspiciousStopUnknownProbeCount++
        $window.FindName('SuspiciousSelectionHint').Text = '进程状态暂时不可读，已保留诊断清单。'
        if ($script:SuspiciousStopUnknownProbeCount -ge $script:ExecutionUnknownProbeLimit) {
            Invoke-GuiTimerStop $script:SuspiciousStopTimer
            $script:SuspiciousStopInProgress = $false
            $script:SuspiciousStopLifecycle = 'detached'
            Update-GuiStopProcessAvailability
            return $true
        }
        return $false
    }
    Invoke-GuiTimerStop $script:SuspiciousStopTimer
    try {
        $rows = @(Read-GuiStrictSuspiciousStopResult -Path $script:SuspiciousStopTempPath -ExpectedRows $script:SuspiciousStopRows)
        $window.FindName('SuspiciousList').ItemsSource = @(Get-GuiSuspiciousViewItems ([pscustomobject]@{ suspicious=$rows }))
        $success = @($rows | Where-Object { $_.status -ceq 'success' }).Count
        $skipped = @($rows | Where-Object { $_.status -ceq 'skipped' }).Count
        $failed = @($rows | Where-Object { $_.status -ceq 'failed' }).Count
        $window.FindName('SuspiciousSelectionHint').Text = "一次性结束结果：成功 $success，跳过 $skipped，失败 $failed。"
        if ($probe.ExitCode -ne 0 -or $failed -gt 0) { throw "stop_process exited with code $($probe.ExitCode)." }
        $null = Clear-GuiSuspiciousStopResources -RemoveTemp -ProcessExitConfirmed
    } catch {
        $detail = $_.Exception.Message + [Environment]::NewLine + 'Diagnostic subset: ' + $script:SuspiciousStopTempPath
        $window.FindName('SuspiciousSelectionHint').Text = $detail
        $null = Clear-GuiSuspiciousStopResources -ProcessExitConfirmed
    }
    return $true
}

function Start-GuiSuspiciousStop {
    param($List = $window.FindName('SuspiciousList'))
    if ($script:SuspiciousStopInProgress -or $script:ExecutionInProgress -or $null -ne $script:SuspiciousStopProcess -or $script:SuspiciousStopLifecycle -cin @('starting','running','unknown','detached')) { return $false }
    $selectedRows = @(Resolve-GuiReviewedSuspiciousRows -List $List)
    if ($selectedRows.Count -eq 0) { return $false }
    $script:SuspiciousStopInProgress = $true
    $script:SuspiciousStopLifecycle = 'starting'
    Update-GuiStopProcessAvailability -List $List
    try {
        $payload = New-GuiSuspiciousSubsetPayload -Selected $selectedRows -SourcePending $script:ReviewedPendingSnapshot
        $script:SuspiciousStopTempPath = Join-Path $env:TEMP ('shushu_suspicious_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($script:SuspiciousStopTempPath, (ConvertTo-GuiPendingJson $payload), [System.Text.UTF8Encoding]::new($true))
        $pendingSha256 = Get-GuiFileSha256 -Path $script:SuspiciousStopTempPath
        $script:SuspiciousStopRows = @($payload.suspicious)
        $script:SuspiciousStopProcess = Start-Process powershell -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','stop_process','-PendingFileArg',"`"$script:SuspiciousStopTempPath`"",'-PendingSha256Arg',$pendingSha256
        if ($null -eq $script:SuspiciousStopProcess) { throw 'stop_process 未启动。' }
        $script:SuspiciousStopLifecycle = 'running'
        $script:SuspiciousStopTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:SuspiciousStopTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:SuspiciousStopTimer.Add_Tick({ $null = Complete-SuspiciousStopPoll })
        $script:SuspiciousStopTimer.Start()
        $window.FindName('SuspiciousSelectionHint').Text = '正在结束已选的这一次进程实例…'
        return $true
    } catch {
        if ($null -ne $script:SuspiciousStopProcess) {
            $script:SuspiciousStopLifecycle = 'detached'
            $window.FindName('SuspiciousSelectionHint').Text = $_.Exception.Message + '；已保留诊断清单。'
        } else {
            $null = Clear-GuiSuspiciousStopResources -RemoveTemp
            $window.FindName('SuspiciousSelectionHint').Text = $_.Exception.Message
        }
        return $false
    }
}

$window.FindName('BtnStopProcesses').Add_Click({ Start-GuiSuspiciousStop })

# ---------- 异步处理已选择项目 (review snapshot → 临时清单 → elevated clean) ----------
function Remove-GuiExecutionTempFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $leaf = [System.IO.Path]::GetFileName($Path)
    if ($leaf -cnotmatch '^shushu_pending_[0-9a-f]{32}\.json$') { return }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-GuiFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = $null
    $sha = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '')
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Clear-GuiExecutionResources {
    param([switch]$RemoveTemp, [switch]$ProcessExitConfirmed)
    if ($null -ne $script:ExecutionProcess -and -not $ProcessExitConfirmed) { return $false }
    Invoke-GuiTimerStop $script:ExecutionTimer
    if ($RemoveTemp) { Remove-GuiExecutionTempFile -Path $script:ExecutionTempPath }
    $script:ExecutionProcess = $null
    $script:ExecutionTimer = $null
    $script:ExecutionTempPath = $null
    $script:ExecutionActions = @()
    $script:ExecutionInProgress = $false
    $script:ExecutionLifecycle = 'idle'
    $script:ExecutionUnknownProbeCount = 0
    Update-GuiExecuteAvailability
    return $true
}

function Protect-GuiExecutionWindowClose {
    param([Parameter(Mandatory=$true)]$EventArgs)
    if ($script:ExecutionInProgress -or $script:ExecutionLifecycle -cin @('starting','running','unknown') -or
        $script:SuspiciousStopInProgress -or $script:SuspiciousStopLifecycle -cin @('starting','running','unknown')) {
        $EventArgs.Cancel = $true
        $window.FindName('StateSubtitle').Text = Get-Text 'ExecCloseBlocked'
        return $false
    }
    return $true
}

function Resolve-GuiReviewedActions {
    param($List)
    if ($null -eq $script:ReviewedPendingSnapshot -or $null -eq $script:ReviewedActionIdentityKeys) {
        throw '没有有效的 reviewed pending snapshot。请重新运行 scan 并审核。'
    }
    $null = Get-GuiPendingSchemaVersion $script:ReviewedPendingSnapshot
    Assert-GuiPendingPresentationShape -Pending $script:ReviewedPendingSnapshot
    $validatedKeys = @(Get-GuiValidatedActionIdentityKeys -Pending $script:ReviewedPendingSnapshot)
    if ($validatedKeys.Count -ne $script:ReviewedActionIdentityKeys.Count) {
        throw 'reviewed action allowlist 与审核快照不一致。请重新运行 scan 并审核。'
    }
    foreach ($key in $validatedKeys) {
        if (-not $script:ReviewedActionIdentityKeys.Contains($key)) {
            throw 'reviewed action allowlist 与审核快照不一致。请重新运行 scan 并审核。'
        }
    }

    $actionByKey = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($action in @($script:ReviewedPendingSnapshot.actions)) {
        $actionByKey.Add((Get-PendingIdentityKey $action), $action)
    }
    $selectedRows = @($List.Items | Where-Object { $_.IsChecked })
    if ($selectedRows.Count -eq 0) { return @() }

    $resolved = @()
    $seenSelected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $selectedRows) {
        if ($null -eq $row._raw) { throw '选择项缺少审核身份。未开始处理。' }
        $key = Get-PendingIdentityKey $row._raw
        if (-not $script:ReviewedActionIdentityKeys.Contains($key) -or -not $actionByKey.ContainsKey($key)) {
            throw '选择项不在 reviewed action allowlist 中。未开始处理。'
        }
        if (-not $seenSelected.Add($key)) { throw '选择项包含重复审核身份。未开始处理。' }
        $resolved += [pscustomobject]@{ _raw = $actionByKey[$key] }
    }
    return @($resolved)
}

function Format-GuiExecutionDetail {
    param($Rows, [string]$Prefix = '')
    $lines = @()
    if ($Prefix) { $lines += $Prefix }
    foreach ($row in @($Rows)) {
        $line = '[{0}] {1}' -f $row.State, $row.Name
        if ($row.Reason) { $line += ': ' + $row.Reason }
        $lines += $line
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-GuiExecutionProcessStatus {
    param([Parameter(Mandatory=$true)]$Process)
    try {
        $waitMethod = $Process.PSObject.Methods['WaitForExit']
        if ($null -ne $waitMethod) {
            $hasExited = $Process.WaitForExit(0)
            if ($hasExited -isnot [bool]) { throw 'WaitForExit(0) 未返回 Boolean 状态。' }
        } else {
            $hasExited = $Process.HasExited
            if ($hasExited -isnot [bool]) { throw 'HasExited 未返回 Boolean 状态。' }
        }
        if (-not $hasExited) { return [pscustomobject]@{ State='running'; ExitCode=$null; Detail='' } }

        $exitCode = $Process.ExitCode
        if ($exitCode -isnot [int32] -and $exitCode -isnot [int64]) {
            throw 'ExitCode 不可读或不是整数。'
        }
        return [pscustomobject]@{ State='exited'; ExitCode=[int]$exitCode; Detail='' }
    } catch {
        return [pscustomobject]@{ State='unknown'; ExitCode=$null; Detail=$_.Exception.ToString() }
    }
}

function Read-GuiStrictExecutionResult {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$ExpectedActions)
    $pending = Read-GuiPendingFile -Path $Path
    $null = Get-GuiPendingSchemaVersion $pending
    Assert-GuiPendingPresentationShape -Pending $pending
    $items = @($pending.actions)
    $expected = @($ExpectedActions)
    if ($items.Count -ne $expected.Count) { throw 'execution result action count does not match this execution.' }

    $expectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($action in $expected) {
        if (-not $expectedKeys.Add((Get-PendingIdentityKey $action))) { throw 'execution expected identity set contains duplicates.' }
    }
    $resultKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($action in $items) {
        $key = Get-PendingIdentityKey $action
        if (-not $resultKeys.Add($key)) { throw 'execution result identity set contains duplicates.' }
        if (-not $expectedKeys.Contains($key)) { throw 'execution result identity does not match this execution.' }
        if ([string]$action.status -cnotin @('success','failed','skipped','manual_required')) {
            throw 'execution result contains a non-terminal action status.'
        }
    }
    $actionCopies = [System.Collections.Generic.List[object]]::new()
    $resultPairs = [System.Collections.Generic.List[System.Tuple[string,string]]]::new()
    $statusMap = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach ($action in $items) {
        $copy = Copy-PendingActionForSubset $action
        $copy.status = [string]$action.status
        $key = Get-PendingIdentityKey $copy
        $status = [string]$copy.status
        $actionCopies.Add($copy)
        $resultPairs.Add([System.Tuple[string,string]]::new($key, $status))
        $statusMap.Add($key, $status)
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(ConvertTo-GuiExecutionRows $actionCopies)) { $rows.Add($row) }
    $summaryValues = Get-GuiExecutionSummaryFromActions $actionCopies
    $summaryMap = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::Ordinal)
    foreach ($name in @('success','failed','skipped','manual_required')) { $summaryMap.Add($name, [int]$summaryValues[$name]) }
    return [pscustomobject]@{
        Actions = $actionCopies.AsReadOnly()
        Items = $resultPairs.AsReadOnly()
        StatusByIdentity = [System.Collections.ObjectModel.ReadOnlyDictionary[string,string]]::new($statusMap)
        Summary = [System.Collections.ObjectModel.ReadOnlyDictionary[string,int]]::new($summaryMap)
        Rows = $rows.AsReadOnly()
    }
}

function Get-GuiExecutionSummaryFromActions {
    param($Actions)
    $sum = @{ success=0; failed=0; skipped=0; manual_required=0 }
    foreach ($action in @($Actions)) { $sum[[string]$action.status]++ }
    return $sum
}

function Save-GuiExecutionDiagnostic {
    param([Parameter(Mandatory=$true)][string]$Path)
    $evidencePath = $Path
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $directory = Join-Path $script:Root 'diagnostics'
        [void][System.IO.Directory]::CreateDirectory($directory)
        $destination = Join-Path $directory ('execution_result_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllBytes($destination, $bytes)
        Remove-GuiExecutionTempFile -Path $Path
        $evidencePath = $destination
    } catch {
        # If archival fails, leave the original exact temp file as the only diagnostic evidence.
    }
    return $evidencePath
}

function Enter-GuiExecutionSafeDetach {
    param([AllowEmptyString()][string]$Detail = '')
    $script:ExecutionUnknownProbeCount = $script:ExecutionUnknownProbeLimit
    Invoke-GuiTimerStop $script:ExecutionTimer
    $script:ExecutionLifecycle = 'detached'
    $script:ExecutionInProgress = $false
    $diagnosticDetail = $Detail
    if ($diagnosticDetail) { $diagnosticDetail += [Environment]::NewLine }
    $diagnosticDetail += 'Diagnostic subset: ' + $script:ExecutionTempPath
    Set-GuiError -Summary (Get-Text 'ExecStatusUnknown') -Mutation (Get-Text 'ExecPartialPossible') -Detail $diagnosticDetail
}

function Complete-ExecutionPoll {
    $process = $script:ExecutionProcess
    if ($null -eq $process) { return $false }
    $probe = Get-GuiExecutionProcessStatus -Process $process
    if ($probe.State -eq 'running') {
        if ($script:ExecutionLifecycle -eq 'unknown') {
            $script:ExecutionLifecycle = 'running'
            $script:ExecutionUnknownProbeCount = 0
            if ($null -ne $script:ExecutionTimer) { $script:ExecutionTimer.Interval = [TimeSpan]::FromMilliseconds(500) }
            Set-GuiState executing -Force
        }
        try {
            $pending = Read-GuiPendingFile -Path $script:ExecutionTempPath
            $null = Get-GuiPendingSchemaVersion $pending
            Assert-GuiPendingPresentationShape -Pending $pending
            $items = @($pending.actions)
            $expected = @($script:ExecutionActions)
            if ($items.Count -ne $expected.Count) { throw 'running subset action count changed.' }
            for ($index = 0; $index -lt $items.Count; $index++) {
                if ((Get-PendingIdentityKey $items[$index]) -cne (Get-PendingIdentityKey $expected[$index])) {
                    throw 'running subset action identity changed.'
                }
            }
            $window.FindName('ExecutionList').ItemsSource = @(ConvertTo-GuiExecutionRows $items)
        } catch {
            # Elevated clean rewrites the subset while this timer reads it. Keep the last truthful rows and retry.
        }
        return $false
    }
    if ($probe.State -eq 'unknown') {
        $script:ExecutionUnknownProbeCount++
        $script:ExecutionLifecycle = 'unknown'
        if ($script:ExecutionUnknownProbeCount -ge $script:ExecutionUnknownProbeLimit) {
            Enter-GuiExecutionSafeDetach -Detail $probe.Detail
            return $true
        }
        $detail = $probe.Detail + [Environment]::NewLine + ('Diagnostic subset: ' + $script:ExecutionTempPath) + [Environment]::NewLine + ('Probe retry: {0}/{1}' -f $script:ExecutionUnknownProbeCount, $script:ExecutionUnknownProbeLimit)
        Set-GuiError -Summary (Get-Text 'ExecStatusUnknown') -Mutation (Get-Text 'ExecPartialPossible') -Detail $detail
        if ($null -ne $script:ExecutionTimer) { $script:ExecutionTimer.Interval = [TimeSpan]::FromSeconds(1) }
        return $false
    }

    if ($script:ExecutionLifecycle -eq 'unknown') { Set-GuiState executing -Force }
    $script:ExecutionUnknownProbeCount = 0
    Invoke-GuiTimerStop $script:ExecutionTimer
    $script:ExecutionLifecycle = 'exited'
    $exitCode = $probe.ExitCode
    if ($exitCode -eq 0) {
        try {
            $result = Read-GuiStrictExecutionResult -Path $script:ExecutionTempPath -ExpectedActions $script:ExecutionActions
            Merge-PendingStatus $result
            $window.FindName('CompletedList').ItemsSource = @($result.Rows)
            Set-GuiCompletedSummary -Success $result.Summary['success'] -Failed $result.Summary['failed'] -Skipped $result.Summary['skipped'] -Manual $result.Summary['manual_required']
            Set-GuiState completed
            $null = Clear-GuiExecutionResources -RemoveTemp -ProcessExitConfirmed
        } catch {
            $failure = $_.Exception.ToString()
            $diagnosticPath = Save-GuiExecutionDiagnostic -Path $script:ExecutionTempPath
            $detail = $failure + [Environment]::NewLine + 'Diagnostic: ' + $diagnosticPath
            Set-GuiError -Summary (Get-Text 'ExecResultReadFailed') -Mutation (Get-Text 'ExecPartialPossible') -Detail $detail
            $null = Clear-GuiExecutionResources -ProcessExitConfirmed
        }
        return $true
    }

    $rows = @()
    $readError = $null
    try {
        $resultItems = @(Get-PendingItems -Path $script:ExecutionTempPath)
        $rows = @(ConvertTo-GuiExecutionRows $resultItems)
    } catch {
        $readError = $_.Exception.ToString()
    }

    try {
        $summary = (Get-Text 'ExecFailed') -f $exitCode
        $prefix = if ($readError) { $readError } else { '' }
        $detail = Format-GuiExecutionDetail -Rows $rows -Prefix $prefix
        Set-GuiError -Summary $summary -Mutation (Get-Text 'ExecPartialPossible') -Detail $detail
    } finally {
        $null = Clear-GuiExecutionResources -RemoveTemp -ProcessExitConfirmed
    }
    return $true
}

function Start-GuiExecution {
    param($List = $window.FindName('PendingList'))
    if ($script:ExecutionInProgress -or $script:SuspiciousStopInProgress -or $null -ne $script:ExecutionProcess -or $script:ExecutionLifecycle -cin @('starting','running','unknown','detached')) {
        return $false
    }
    $script:ExecutionInProgress = $true
    $script:ExecutionLifecycle = 'starting'
    $script:ExecutionUnknownProbeCount = 0
    Update-GuiExecuteAvailability -List $List
    $startedProcess = $false
    try {
        $checked = @(Resolve-GuiReviewedActions -List $List)
        if ($checked.Count -eq 0) {
            $window.FindName('ReviewBoundaryText').Text = (Get-Text 'ExecEmpty')
            $null = Clear-GuiExecutionResources -RemoveTemp
            return $false
        }

        $payload = New-PendingSubsetPayload -Checked $checked -SourcePending $script:ReviewedPendingSnapshot
        if (-not $payload) { throw '无法生成 pending 子集。请重新运行 scan 生成新清单。' }
        $payload.observations = @()
        $script:ExecutionTempPath = Join-Path $env:TEMP ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($script:ExecutionTempPath, (ConvertTo-GuiPendingJson -InputObject $payload), [System.Text.UTF8Encoding]::new($true))
        $pendingSha256 = Get-GuiFileSha256 -Path $script:ExecutionTempPath
        $script:ExecutionActions = @($payload.actions)

        $runningItems = foreach ($action in @($payload.actions)) {
            $copy = Copy-PendingActionForSubset $action
            $copy.status = 'running'
            $copy
        }
        $window.FindName('ExecutionList').ItemsSource = @(ConvertTo-GuiExecutionRows $runningItems)

        $script:ExecutionProcess = Start-Process powershell -Verb RunAs -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','clean','-YesToAll','-PendingFileArg',"`"$script:ExecutionTempPath`"",'-PendingSha256Arg',$pendingSha256
        if ($null -eq $script:ExecutionProcess) { throw '管理员进程未启动。' }
        $startedProcess = $true
        $script:ExecutionLifecycle = 'running'

        $script:ExecutionTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:ExecutionTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:ExecutionTimer.Add_Tick({ $null = Complete-ExecutionPoll })
        Set-GuiState executing
        $script:ExecutionTimer.Start()
        return $true
    } catch {
        $detail = $_.Exception.ToString()
        if ($startedProcess) {
            Enter-GuiExecutionSafeDetach -Detail $detail
        } else {
            $null = Clear-GuiExecutionResources -RemoveTemp
            Set-GuiError -Summary (Get-Text 'ExecUnauthorized') -Mutation (Get-Text 'ExecNotStarted') -Detail $detail
        }
        return $false
    }
}

$window.Add_Closing({ param($sender, $eventArgs); $null = Protect-GuiExecutionWindowClose -EventArgs $eventArgs })

$window.FindName('BtnExecute').Add_Click({ Start-GuiExecution })
$legacyBtnExec = $window.FindName('BtnExec')
if ($legacyBtnExec) { $legacyBtnExec.Add_Click({ Start-GuiExecution }) }

# ---------- 查看最近结果 ----------
$legacyBtnResult = $window.FindName('BtnResult')
if ($legacyBtnResult) { $legacyBtnResult.Add_Click({
    $out = $window.FindName('ResultOutput')
    $out.Text = Get-Text 'LegacyBackupUnsupported'
}) }

function Show-GuiMessage {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('Information','Warning')][string]$Icon = 'Information'
    )
    [System.Windows.MessageBox]::Show($Message, (Get-Text 'AppName'), 'OK', $Icon) | Out-Null
}

function Invoke-GuiRestoreLatest {
    if ($script:RestoreInProgress) { return $false }
    $script:RestoreInProgress = $true
    $processStarted = $false
    $restoreButton = $window.FindName('BtnRestore')
    $restoreButton.IsEnabled = $false
    $window.FindName('CompletedSummaryText').Text = ''
    $window.FindName('CompletedList').ItemsSource = $null
    try {
        $proc = Start-Process powershell -Verb RunAs -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','restore','-BackupDir','latest'
        if ($null -eq $proc) { throw '管理员恢复进程未启动。' }
        $processStarted = $true
        $proc.WaitForExit()
        $rawExitCode = $proc.ExitCode
        if ($null -eq $rawExitCode -or $rawExitCode -isnot [int]) {
            throw '恢复进程退出码不可读或不是整数。'
        }
        $exitCode = [int]$rawExitCode
        if ($exitCode -eq 0) {
            Set-GuiCompletedSummary -Text (Get-Text 'RestoreOk')
            Set-GuiState completed -Force
            return $true
        }
        if ($exitCode -eq 2) {
            Set-GuiCompletedSummary -Failed 1 -Text (Get-Text 'RestorePartial')
            Set-GuiState completed -Force
            return $false
        }
        if ($exitCode -eq 3) {
            $summary = Get-Text 'RestoreNone'
            Set-GuiError -Summary $summary -Mutation (Get-Text 'RestoreNone') -Detail $summary
            return $false
        }
        $summary = (Get-Text 'RestoreErr') -f "ExitCode=$exitCode"
        Set-GuiError -Summary $summary -Mutation (Get-Text 'RestoreMayHaveChanged') -Detail $summary
        Show-GuiMessage -Message $summary -Icon Warning
        return $false
    } catch {
        $summary = (Get-Text 'RestoreErr') -f $_.Exception.Message
        $mutation = if ($processStarted) { Get-Text 'RestoreStatusUnknown' } else { Get-Text 'RestoreNotStarted' }
        Set-GuiError -Summary $summary -Mutation $mutation -Detail $_.Exception.ToString()
        Show-GuiMessage -Message $summary -Icon Warning
        return $false
    } finally {
        $script:RestoreInProgress = $false
        $restoreButton.IsEnabled = $true
    }
}

# ---------- 恢复最近一次处理 ----------
$window.FindName('BtnRestore').Add_Click({ $null = Invoke-GuiRestoreLatest })

Set-GuiState -Name idle -Force
Apply-Language
if ($script:TestMode) {
    # 测试模式: 不显示窗口, 暴露窗口对象供 Pester 无窗口断言
    $script:TestWindow = $window
} else {
    $window.ShowDialog() | Out-Null
}
