# 鼠鼠 Cleaner「鼠鼠的幻想」单页 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变已加固扫描与清理安全边界的前提下，把现有四标签 WPF GUI 改造成“鼠鼠的幻想”四格连环画单页状态旅程。

**Architecture:** 保留 `cpu-cleaner.ps1` 与 `src/Core/*.ps1` 作为唯一扫描、pending、授权、执行、备份和恢复实现。新增独立 XAML 布局和纯展示状态模块，`gui-cleaner.ps1` 只负责装配、启动后台任务、收集用户选择和把核心结果映射到 UI；任何可执行性判断仍来自 pending v2 的 `actions`/`observations` 分流与提权后的复核。

**Tech Stack:** Windows PowerShell 5.1, WPF/XAML, .NET DispatcherTimer and BitmapImage, Pester 5.9.0, existing JSON pending v2 and PowerShell core modules.

---

## File structure

- Create `src/Gui/Presentation.ps1`: pure GUI state definitions, state transition validation, count summaries, matcher detail formatting, and execution-row projection. It must not call service, registry, task, process, backup, or elevation APIs.
- Create `src/Gui/MainWindow.xaml`: single-page WPF layout, shared styles, four comic stage cards, seven state panels, review list, technical detail expanders, fixed action area, and accessibility properties.
- Modify `gui-cleaner.ps1`: load the two GUI files, keep existing pending subset/merge safety helpers, wire state transitions, run scan/clean/restore processes without blocking the UI, and render truthful results.
- Modify `tests/Gui.Tests.ps1`: protect XAML structure, state transitions, broad-match read-only behavior, provenance display, scan/error states, execution polling, partial failure, cleanup, language, and keyboard/accessibility behavior.
- Create `tests/GuiPresentation.Tests.ps1`: fast non-WPF tests for the pure presentation module.
- Modify `tests/run-gui-tests.ps1`: run both GUI test files under Windows PowerShell STA.
- Create `tests/render-gui-states.ps1`: render deterministic screenshots of all seven states without running a real scan or clean.
- Create `docs/design-references/shushu-fantasy-comic-target.png`: checked-in copy of the selected ImageGen option 2 used only for visual comparison.
- Update `assets/rat_gui_preview.png`: final verified screenshot after implementation; keep `rat_scan.jpg`, `rat_pending.jpg`, `rat_exec.jpg`, and `rat_result.jpg` as the four real comic assets.
- Modify `README.md`: replace the obsolete four-tab GUI explanation and preview with the single-page journey and precise safety wording.

## Locked implementation rules

- Do not change Schema 3.0 matcher semantics, pending v2 authorization, locked-file handling, autostart identity, service/task/process identity, backup, or restore behavior unless a failing regression test proves an integration defect.
- Do not copy action eligibility logic into XAML or GUI event handlers. `pending_actions.json.actions` is selectable; `observations` is always read-only.
- Do not execute a real clean, mutate production Run keys, change a real service/task, terminate a real process, or perform a physical restore in automated tests or visual rendering.
- Do not use fake random percentage progress. Scanning is indeterminate and names the current known phase.
- Do not use emoji, CSS art, inline SVG, or generated vector approximations as mouse assets. Load the four existing JPEG files through absolute paths.
- Preserve Chinese and English UI support.

### Task 1: Add a pure presentation state model

**Files:**
- Create: `src/Gui/Presentation.ps1`
- Create: `tests/GuiPresentation.Tests.ps1`
- Modify: `tests/run-gui-tests.ps1`

- [ ] **Step 1: Write failing state, count, provenance, and execution-row tests**

Create `tests/GuiPresentation.Tests.ps1` with these concrete cases:

```powershell
BeforeAll {
    $projectRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $projectRoot 'src\Gui\Presentation.ps1')
}

Describe 'GUI presentation model' {
    It 'defines the seven approved states' {
        @(Get-GuiStateNames) | Should -Be @('idle','scanning','results','review','executing','completed','error')
    }

    It 'allows only approved forward and recovery transitions' {
        Test-GuiStateTransition idle scanning | Should -BeTrue
        Test-GuiStateTransition scanning results | Should -BeTrue
        Test-GuiStateTransition results review | Should -BeTrue
        Test-GuiStateTransition review executing | Should -BeTrue
        Test-GuiStateTransition executing completed | Should -BeTrue
        Test-GuiStateTransition executing error | Should -BeTrue
        Test-GuiStateTransition results error | Should -BeTrue
        Test-GuiStateTransition review error | Should -BeTrue
        Test-GuiStateTransition completed error | Should -BeTrue
        Test-GuiStateTransition error scanning | Should -BeTrue
        Test-GuiStateTransition idle executing | Should -BeFalse
        Test-GuiStateTransition results completed | Should -BeFalse
    }

    It 'counts executable and observation items separately' {
        $items = @(
            [pscustomobject]@{ CanExecute=$true; status='pending' },
            [pscustomobject]@{ CanExecute=$true; status='failed' },
            [pscustomobject]@{ CanExecute=$false; status='观察' }
        )
        $summary = Get-GuiItemSummary $items
        $summary.executable | Should -Be 2
        $summary.observation | Should -Be 1
        $summary.total | Should -Be 3
    }

    It 'formats exact matcher provenance without granting authority' {
        $raw = [pscustomobject]@{
            hit_type='service'; service_name='ExactSvc'; action='disable_service'
            matched_pattern='ExactSvc'; matched_type='exact'; matched_field='service_name'
        }
        $text = Format-GuiMatcherDetail $raw
        $text | Should -Match 'service_name'
        $text | Should -Match 'exact'
        $text | Should -Match 'ExactSvc'
    }

    It 'projects partial execution results item by item' {
        $rows = @(ConvertTo-GuiExecutionRows @(
            [pscustomobject]@{ name_cn='A'; action='disable_service'; status='success'; reason_cn='ok' },
            [pscustomobject]@{ name_cn='B'; action='disable_task'; status='failed'; reason_cn='denied' },
            [pscustomobject]@{ name_cn='C'; action='remove_autostart'; status='skipped'; reason_cn='changed' }
        ))
        $rows[0].StateLabel | Should -Be '成功'
        $rows[1].StateLabel | Should -Be '失败'
        $rows[2].StateLabel | Should -Be '已跳过'
        $rows[1].IsFailure | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
Import-Module Pester -RequiredVersion 5.9.0
$r = Invoke-Pester -Path tests\GuiPresentation.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -eq 0) { throw 'Expected presentation tests to fail before implementation' }
```

Expected: failures report missing `src/Gui/Presentation.ps1` or undefined presentation functions.

- [ ] **Step 3: Implement the pure presentation module**

Create `src/Gui/Presentation.ps1` with no WPF dependency:

```powershell
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
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command without the deliberate RED guard. Expected: `FailedCount: 0`.

- [ ] **Step 5: Make the STA runner execute both GUI suites**

Replace the single-file `Invoke-Pester` call in `tests/run-gui-tests.ps1` with:

```powershell
$config = New-PesterConfiguration
$config.Run.Path = @(
    (Join-Path $PSScriptRoot 'GuiPresentation.Tests.ps1'),
    (Join-Path $PSScriptRoot 'Gui.Tests.ps1')
)
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$r = Invoke-Pester -Configuration $config
if ($r.FailedCount -gt 0) { throw "GUI tests failed: $($r.FailedCount)" }
```

Run the runner under `powershell -STA`. Expected: presentation tests pass; existing GUI tests remain at their pre-layout baseline.

- [ ] **Step 6: Commit the state model**

```powershell
git add src/Gui/Presentation.ps1 tests/GuiPresentation.Tests.ps1 tests/run-gui-tests.ps1
git commit -m "feat: add GUI presentation state model"
```

### Task 2: Replace the four tabs with the single-page comic shell

**Files:**
- Create: `src/Gui/MainWindow.xaml`
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Change the XAML contract test to require the new shell**

Replace the old `TabScan`/`TabPending`/`TabExec`/`TabResult` control assertion with:

```powershell
It 'loads the single-page fantasy comic shell' {
    $script:Win | Should -Not -BeNullOrEmpty
    foreach ($name in @(
        'StageCard1','StageCard2','StageCard3','StageCard4',
        'ImgStage1','ImgStage2','ImgStage3','ImgStage4',
        'IdlePanel','ScanningPanel','ResultsPanel','ReviewPanel',
        'ExecutingPanel','CompletedPanel','ErrorPanel',
        'StateTitle','StateSubtitle','PendingList','ExecutionList',
        'BtnStartScan','BtnOpenReview','BtnExecute','BtnRescan','BtnRetry','BtnRestore','BtnLang'
    )) {
        $script:Win.FindName($name) | Should -Not -BeNullOrEmpty
    }
    $script:Win.FindName('LegacyTabs') | Should -BeNullOrEmpty
}
```

- [ ] **Step 2: Run GUI tests and verify RED**

Run:

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\run-gui-tests.ps1
```

Expected: the shell contract test fails because the new named controls do not exist.

- [ ] **Step 3: Create the XAML file with fixed regions and seven state panels**

Create `src/Gui/MainWindow.xaml`. Use these exact layout and style contracts:

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鼠鼠cleaner" Width="1040" Height="760" MinWidth="900" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#FFF6DC"
        FontFamily="Microsoft YaHei UI" FontSize="13"
        AutomationProperties.Name="鼠鼠 Cleaner 安全整理工具">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#211D16"/>
    <SolidColorBrush x:Key="Cream" Color="#FFF6DC"/>
    <SolidColorBrush x:Key="Paper" Color="#FFFFF8"/>
    <SolidColorBrush x:Key="FantasyYellow" Color="#FFD21F"/>
    <SolidColorBrush x:Key="Muted" Color="#6E675D"/>
    <SolidColorBrush x:Key="Danger" Color="#B83A2D"/>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="MinWidth" Value="156"/><Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="18,0"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Background" Value="{StaticResource FantasyYellow}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="MinWidth" Value="120"/><Setter Property="Height" Value="38"/>
      <Setter Property="Padding" Value="14,0"/><Setter Property="Background" Value="#F0E5C8"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="BorderBrush" Value="#CDBF9D"/>
    </Style>
    <Style x:Key="StageCard" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Paper}"/><Setter Property="BorderBrush" Value="#D8CBAA"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="8"/>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="188"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="4,0,4,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock x:Name="TitleMain" Text="鼠鼠cleaner" FontSize="26" FontWeight="Bold" Foreground="{StaticResource Ink}"/>
        <TextBlock x:Name="TitleSub" Text="识别可以宽，执行必须窄" Foreground="{StaticResource Muted}"/></StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <TextBlock x:Name="PrivilegeText" Text="普通权限" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="BtnLang" Content="EN" Style="{StaticResource SecondaryButton}" MinWidth="52" AutomationProperties.Name="切换语言"/>
      </StackPanel>
    </Grid>
    <UniformGrid Grid.Row="1" Columns="4">
      <Border x:Name="StageCard1" Style="{StaticResource StageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Image x:Name="ImgStage1" Stretch="UniformToFill"/><TextBlock Grid.Row="1" Text="1 轻盈幻想" FontWeight="Bold" Margin="2,6,2,0"/></Grid></Border>
      <Border x:Name="StageCard2" Style="{StaticResource StageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Image x:Name="ImgStage2" Stretch="UniformToFill"/><TextBlock Grid.Row="1" Text="2 看清现实" FontWeight="Bold" Margin="2,6,2,0"/></Grid></Border>
      <Border x:Name="StageCard3" Style="{StaticResource StageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Image x:Name="ImgStage3" Stretch="UniformToFill"/><TextBlock Grid.Row="1" Text="3 谨慎整理" FontWeight="Bold" Margin="2,6,2,0"/></Grid></Border>
      <Border x:Name="StageCard4" Style="{StaticResource StageCard}"><Grid><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Image x:Name="ImgStage4" Stretch="UniformToFill"/><TextBlock Grid.Row="1" Text="4 幻想落地" FontWeight="Bold" Margin="2,6,2,0"/></Grid></Border>
    </UniformGrid>
    <Border Grid.Row="2" Margin="4,10,4,4" Padding="20" Background="{StaticResource Paper}" CornerRadius="14" BorderBrush="#D8CBAA" BorderThickness="1">
      <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel><TextBlock x:Name="StateTitle" FontSize="24" FontWeight="Bold" Foreground="{StaticResource Ink}"/>
          <TextBlock x:Name="StateSubtitle" Margin="0,4,0,12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/></StackPanel>
        <Grid Grid.Row="1">
          <StackPanel x:Name="IdlePanel"><TextBlock Text="扫描只读，不会修改系统。" Margin="0,0,0,16"/><Button x:Name="BtnStartScan" Content="开始安全扫描" HorizontalAlignment="Left" Style="{StaticResource PrimaryButton}"/></StackPanel>
          <StackPanel x:Name="ScanningPanel" Visibility="Collapsed"><ProgressBar x:Name="ScanProgress" Height="8" IsIndeterminate="True"/><TextBlock x:Name="ScanPhaseText" Text="正在检查系统项目" Margin="0,12,0,8"/><TextBox x:Name="ScanOutput" IsReadOnly="True" Height="160" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/></StackPanel>
          <StackPanel x:Name="ResultsPanel" Visibility="Collapsed"><TextBlock x:Name="ResultSummaryText" FontSize="18" FontWeight="Bold"/><TextBlock Text="目前尚未修改任何内容。" Margin="0,6,0,18"/><Button x:Name="BtnOpenReview" Content="查看处理建议" HorizontalAlignment="Left" Style="{StaticResource PrimaryButton}"/></StackPanel>
          <Grid x:Name="ReviewPanel" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal"><Button x:Name="BtnSelectAll" Content="选择全部安全项" Style="{StaticResource SecondaryButton}"/><Button x:Name="BtnClearAll" Content="清空选择" Margin="8,0,0,0" Style="{StaticResource SecondaryButton}"/></StackPanel>
            <ListBox x:Name="PendingList" Grid.Row="1" Margin="0,10" Background="Transparent" BorderThickness="0"><ListBox.ItemTemplate><DataTemplate><Border BorderBrush="#E2D7BC" BorderThickness="0,0,0,1" Padding="6"><StackPanel><DockPanel><CheckBox IsChecked="{Binding IsChecked}" IsEnabled="{Binding CanExecute}" VerticalAlignment="Center"/><TextBlock Text="{Binding name_cn}" FontWeight="Bold" Margin="8,0"/><TextBlock Text="{Binding action_label}" Foreground="#6E675D"/></DockPanel><TextBlock Text="{Binding reason_cn}" TextWrapping="Wrap" Margin="24,4,0,0"/><Expander Header="技术详情" Margin="24,4,0,0"><TextBlock Text="{Binding matcher_detail}" FontFamily="Consolas" TextWrapping="Wrap"/></Expander></StackPanel></Border></DataTemplate></ListBox.ItemTemplate></ListBox>
            <DockPanel Grid.Row="2"><TextBlock x:Name="ReviewBoundaryText" Text="观察项不会自动执行；执行前将再次验证。" VerticalAlignment="Center"/><Button x:Name="BtnExecute" Content="处理已选择项目" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}"/></DockPanel>
          </Grid>
          <StackPanel x:Name="ExecutingPanel" Visibility="Collapsed"><TextBlock Text="正在逐项处理；每项均会备份并复核。"/><ListBox x:Name="ExecutionList" Margin="0,10" DisplayMemberPath="StateLabel"/></StackPanel>
          <StackPanel x:Name="CompletedPanel" Visibility="Collapsed"><TextBlock x:Name="CompletedSummaryText" FontSize="18" FontWeight="Bold"/><ListBox x:Name="CompletedList" Height="150" DisplayMemberPath="StateLabel"/><StackPanel Orientation="Horizontal" Margin="0,12,0,0"><Button x:Name="BtnRescan" Content="重新扫描" Style="{StaticResource PrimaryButton}"/><Button x:Name="BtnRestore" Content="恢复最近处理" Margin="8,0,0,0" Style="{StaticResource SecondaryButton}"/></StackPanel></StackPanel>
          <StackPanel x:Name="ErrorPanel" Visibility="Collapsed"><TextBlock x:Name="ErrorSummaryText" Foreground="{StaticResource Danger}" FontWeight="Bold"/><TextBlock x:Name="ErrorMutationText" Margin="0,6,0,12"/><Expander Header="查看技术详情"><TextBox x:Name="ErrorDetailText" IsReadOnly="True" Height="120" TextWrapping="Wrap"/></Expander><Button x:Name="BtnRetry" Content="重试" Margin="0,12,0,0" HorizontalAlignment="Left" Style="{StaticResource PrimaryButton}"/></StackPanel>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
```

- [ ] **Step 4: Load external XAML and the pure presentation module**

In `gui-cleaner.ps1`, remove the complete inline XAML here-string from the `$xaml` assignment through its closing here-string terminator, and replace its reader creation with:

```powershell
. (Join-Path $script:Root 'src\Gui\Presentation.ps1')
$xamlPath = Join-Path $script:Root 'src\Gui\MainWindow.xaml'
if (-not (Test-Path -LiteralPath $xamlPath)) { throw "GUI layout missing: $xamlPath" }
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
```

Replace `$script:ImgMap` with:

```powershell
$script:ImgMap = [ordered]@{
    ImgStage1 = 'assets/rat_scan.jpg'
    ImgStage2 = 'assets/rat_pending.jpg'
    ImgStage3 = 'assets/rat_exec.jpg'
    ImgStage4 = 'assets/rat_result.jpg'
}
```

Keep the existing absolute `BitmapImage` loading loop so a different working directory cannot break resources.

- [ ] **Step 5: Run the shell contract and verify GREEN**

Run `tests\run-gui-tests.ps1`. Expected: XAML loads, all new names exist, and failures remain only in old tests that still reference removed tab controls or old event flow.

- [ ] **Step 6: Commit the single-page shell**

```powershell
git add src/Gui/MainWindow.xaml gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: add single-page fantasy comic shell"
```

### Task 3: Render state transitions and truthful stage emphasis

**Files:**
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Add failing tests for state visibility and invalid jumps**

Add:

```powershell
It 'shows exactly one state panel and emphasizes completed/current stages' {
    Set-GuiState -Name 'review' -Force
    $script:Win.FindName('ReviewPanel').Visibility.ToString() | Should -Be 'Visible'
    foreach ($name in @('IdlePanel','ScanningPanel','ResultsPanel','ExecutingPanel','CompletedPanel','ErrorPanel')) {
        $script:Win.FindName($name).Visibility.ToString() | Should -Be 'Collapsed'
    }
    $script:Win.FindName('StageCard3').BorderThickness.Left | Should -Be 3
    $script:Win.FindName('StageCard4').Opacity | Should -BeLessThan 1
}

It 'rejects a direct idle to executing jump' {
    Set-GuiState -Name 'idle' -Force
    { Set-GuiState -Name 'executing' } | Should -Throw '*非法界面状态转换*'
    $script:GuiState | Should -Be 'idle'
}
```

- [ ] **Step 2: Run GUI tests and verify RED**

Expected: `Set-GuiState` is undefined.

- [ ] **Step 3: Implement the state renderer**

Add to `gui-cleaner.ps1` after image loading:

```powershell
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
    foreach ($panelName in $script:StatePanels) {
        $window.FindName($panelName).Visibility = if ($panelName -eq $definition.Panel) { 'Visible' } else { 'Collapsed' }
    }
    $activeStage = if ($definition.ActiveStage -eq 0) { $script:GuiActiveStage } else { $definition.ActiveStage }
    for ($stage = 1; $stage -le 4; $stage++) {
        $card = $window.FindName("StageCard$stage")
        $card.Opacity = if ($stage -le $activeStage) { 1.0 } else { 0.46 }
        $card.BorderBrush = if ($stage -eq $activeStage) { '#FFD21F' } else { '#D8CBAA' }
        $card.BorderThickness = if ($stage -eq $activeStage) { 3 } else { 1 }
    }
    $script:GuiState = $Name
    $script:GuiActiveStage = $activeStage
    Update-GuiStateText
}
```

Add `Set-GuiState -Name idle -Force` immediately before `Apply-Language` at startup.

- [ ] **Step 4: Map state titles and subtitles through I18N**

Add these keys to both language maps and set `StateTitle`/`StateSubtitle` in `Apply-Language` based on `$script:GuiState`:

```powershell
State_idle_Title='鼠鼠开始幻想'; State_idle_Sub='先做只读扫描，不会修改系统。'
State_scanning_Title='正在看清现实'; State_scanning_Sub='只展示真实阶段，不伪造完成百分比。'
State_results_Title='扫描结论'; State_results_Sub='可处理项与观察项分开显示，目前尚未修改系统。'
State_review_Title='确认处理边界'; State_review_Sub='只有安全、已测试且窄匹配命中的项目可以选择。'
State_executing_Title='鼠鼠正在谨慎整理'; State_executing_Sub='每项都会重新验证、备份并记录结果。'
State_completed_Title='幻想落地'; State_completed_Sub='结果按成功、失败和跳过逐项展示。'
State_error_Title='鼠鼠的幻想被打断了'; State_error_Sub='查看真实原因后可以安全重试。'
```

Add this shared updater and call it at the end of `Apply-Language`; `Set-GuiState` already calls the same updater, so state transitions and language changes cannot drift:

```powershell
function Update-GuiStateText {
    $titleKey = 'State_{0}_Title' -f $script:GuiState
    $subtitleKey = 'State_{0}_Sub' -f $script:GuiState
    $window.FindName('StateTitle').Text = Get-Text $titleKey
    $window.FindName('StateSubtitle').Text = Get-Text $subtitleKey
}
```

Add these exact English values:

```powershell
State_idle_Title='The fantasy begins'; State_idle_Sub='Start with a read-only scan. No system settings will change.'
State_scanning_Title='Looking at reality'; State_scanning_Sub='Showing real scan phases without a fabricated percentage.'
State_results_Title='Scan result'; State_results_Sub='Safe actions and observations are separated. Nothing has changed yet.'
State_review_Title='Review the safety boundary'; State_review_Sub='Only tested items produced by narrow matches can be selected.'
State_executing_Title='Cleaning carefully'; State_executing_Sub='Every item is revalidated, backed up, and recorded.'
State_completed_Title='Fantasy delivered'; State_completed_Sub='Success, failure, and skipped results are shown item by item.'
State_error_Title='The fantasy was interrupted'; State_error_Sub='Read the real cause, then retry safely.'
```

- [ ] **Step 5: Run GUI and presentation tests and verify GREEN**

Expected: both files report `FailedCount: 0` for state-related cases.

- [ ] **Step 6: Commit the state renderer**

```powershell
git add gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: render GUI journey states"
```

### Task 4: Connect read-only scanning to results without fake progress

**Files:**
- Modify: `cpu-cleaner.ps1`
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`
- Modify: `tests/Pester/Scanner.Tests.ps1`

- [ ] **Step 1: Write failing scan completion tests**

Replace the old numeric-progress assertions with:

```powershell
It 'completed scan stops timers, loads result counts, and enters results' {
    Mock Receive-Job { 'scan complete' }
    Mock Remove-Job {}
    Mock Get-PendingViewItems {
        @([pscustomobject]@{CanExecute=$true},[pscustomobject]@{CanExecute=$false})
    }
    Set-GuiState scanning -Force
    $done = Complete-ScanPoll -job ([pscustomobject]@{State='Completed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer)
    $done | Should -BeTrue
    $script:GuiState | Should -Be 'results'
    $script:Win.FindName('ScanProgress').IsIndeterminate | Should -BeFalse
    $script:Win.FindName('ResultSummaryText').Text | Should -Match '1'
}

It 'failed scan enters error and states that no mutation occurred' {
    Mock Receive-Job { 'scanner failed' }
    Mock Remove-Job {}
    Set-GuiState scanning -Force
    Complete-ScanPoll -job ([pscustomobject]@{State='Failed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
    $script:GuiState | Should -Be 'error'
    $script:Win.FindName('ErrorMutationText').Text | Should -Match '未修改'
}
```

- [ ] **Step 2: Run GUI tests and verify RED**

Expected: the current `Complete-ScanPoll` signature/state behavior fails.

- [ ] **Step 3: Add truthful scan phase output and its regression test**

In `tests/Pester/Scanner.Tests.ps1`, add a source-order test for the seven scan phases:

```powershell
It 'emits scan phases in the same order as the read-only pipeline' {
    $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
    $markers = @(
        '读取系统信息', '检查高占用进程', '检查系统服务', '检查启动项',
        '检查计划任务', '匹配安全规则', '生成扫描报告'
    )
    $last = -1
    foreach ($marker in $markers) {
        $index = $source.IndexOf($marker, [System.StringComparison]::Ordinal)
        $index | Should -BeGreaterThan $last
        $last = $index
    }
}
```

In the `scan` switch branch of `cpu-cleaner.ps1`, place `Write-Step` immediately before its corresponding operation:

```powershell
Write-Step '读取系统信息...';       $sys = Get-SystemInfo
Write-Step '检查高占用进程...';     $procs = Get-TopProcesses 12
$susp = Get-SuspiciousProcesses $procs
Write-Step '检查系统服务...';       $svcs = Get-ServicesInfo
Write-Step '检查启动项...';         $autos = Get-AutoStart
Write-Step '检查计划任务...';       $tasks = Get-TasksInfo
Write-Step '匹配安全规则...';       $hits = Match-Profiles -Services $svcs -AutoStarts $autos -Tasks $tasks -TopProcs $procs
$autoStartNames = Get-AutoStartProcessNames $autos
Write-Step '生成扫描报告...'
```

Do not reorder or duplicate any scan operation. Run the focused scanner Pester file; expected: `FailedCount: 0`.

- [ ] **Step 4: Replace random progress with an indeterminate phase timer**

The scan click handler must:

```powershell
Set-GuiState scanning
$window.FindName('ScanProgress').IsIndeterminate = $true
$window.FindName('ScanPhaseText').Text = '正在检查服务、启动项、计划任务和进程'
$window.FindName('ScanOutput').Text = (Get-Text 'Scanning')
$window.FindName('BtnStartScan').IsEnabled = $false
```

Keep `Start-Job`, but invoke `powershell.exe` directly instead of wrapping it in `cmd /c ... | Out-String`, so phase lines are not buffered until completion:

```powershell
$job = Start-Job -ScriptBlock {
    param($scriptPath)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode scan 2>&1
} -ArgumentList (Join-Path $script:Root 'cpu-cleaner.ps1')
```

Remove every `Get-Random` and numeric `Value +=` statement. On each poll, drain currently available job output with `Receive-Job $job`, append it to `$script:ScanTranscript`, and update `ScanPhaseText` only when a received line contains one of the seven exact phase markers from Step 3. Never rotate phase text on a timer and never infer completion from elapsed time.

- [ ] **Step 5: Make `Complete-ScanPoll` load pending results and render counts**

Use this completion contract:

```powershell
function Complete-ScanPoll {
    param($job, $checkTimer, $scanTimer)
    if ($job.State -notin @('Completed','Failed','Stopped')) { return $false }
    $checkTimer.Stop(); $scanTimer.Stop()
    try { $result = Receive-Job $job -ErrorAction SilentlyContinue } catch { $result = $_.Exception.Message }
    try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch {}
    $window.FindName('ScanProgress').IsIndeterminate = $false
    $window.FindName('BtnStartScan').IsEnabled = $true
    $window.FindName('ScanOutput').Text = [string]$result
    if ($job.State -eq 'Completed') {
        $items = @(Get-PendingViewItems)
        $summary = Get-GuiItemSummary $items
        $window.FindName('ResultSummaryText').Text = ('{0} 项可以安全处理，{1} 项建议观察' -f $summary.executable, $summary.observation)
        Set-GuiState results
    } else {
        $window.FindName('ErrorSummaryText').Text = "扫描失败：$($job.State)"
        $window.FindName('ErrorMutationText').Text = '扫描阶段未修改任何系统设置。'
        $window.FindName('ErrorDetailText').Text = [string]$result
        Set-GuiState error
    }
    return $true
}
```

- [ ] **Step 6: Wire retry and review navigation**

`BtnRetry` calls the same scan-start function used by `BtnStartScan`. `BtnOpenReview` loads `Get-PendingViewItems`, assigns `PendingList.ItemsSource`, then calls `Set-GuiState review`. Extract the shared scan body into `Start-GuiScan` so neither handler raises another button event.

- [ ] **Step 7: Run GUI tests and verify GREEN**

Expected: completion, failure, stopped-job, and running-job cases pass; no test expects fake percentage 100.

- [ ] **Step 8: Commit truthful scanning**

```powershell
git add cpu-cleaner.ps1 gui-cleaner.ps1 tests/Gui.Tests.ps1 tests/Pester/Scanner.Tests.ps1
git commit -m "feat: connect truthful scan states"
```

### Task 5: Build the review list from pending v2 provenance

**Files:**
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Add failing mixed-matcher and provenance presentation tests**

Add a pending fixture with one executable exact hit and one contains observation:

```powershell
$pending = [pscustomobject]@{
    pending_schema_version = [int64]2
    actions = @([pscustomobject]@{
        id='mixed'; name_cn='精确服务'; hit_type='service'; action='disable_service'; status='pending';
        service_name='ExactService'; matched_pattern='ExactService'; matched_type='exact'; matched_field='service_name'; reason_cn='narrow'
    })
    observations = @([pscustomobject]@{
        id='mixed'; name_cn='联想观察项'; hit_type='service'; action='investigate'; status='观察';
        service_name='LenovoOtherService'; matched_pattern='Lenovo'; matched_type='contains'; matched_field='service_name'; obs_reason='宽匹配，只观察'
    })
    suspicious = @()
}
```

Write it to a test temp root, call `Get-PendingViewItems`, and assert:

```powershell
$items.Count | Should -Be 2
$items[0].CanExecute | Should -BeTrue
$items[0].IsChecked | Should -BeTrue
$items[0].matcher_detail | Should -Match 'exact'
$items[1].CanExecute | Should -BeFalse
$items[1].IsChecked | Should -BeFalse
$items[1].matcher_detail | Should -Match 'contains'
Set-AllChecked $script:Win.FindName('PendingList') $true
@($script:Win.FindName('PendingList').Items | Where-Object { -not $_.CanExecute -and $_.IsChecked }).Count | Should -Be 0
```

- [ ] **Step 2: Run the focused GUI test and verify RED**

Expected: `matcher_detail` is absent.

- [ ] **Step 3: Extend only the view projection, not action eligibility**

In both `actions` and `observations` branches of `Get-PendingViewItems`, add:

```powershell
matcher_detail = Format-GuiMatcherDetail $i
matched_type   = [string]$i.matched_type
matched_field  = [string]$i.matched_field
```

Do not add any check like `$i.matched_type -in @('exact','path')` to decide `CanExecute`; preserve the authoritative actions/observations split produced by the core.

- [ ] **Step 4: Keep pending v2 fail-closed behavior in the review path**

Before binding review items, parse the source and call `Get-GuiPendingSchemaVersion`. On failure, set:

```powershell
$window.FindName('ErrorSummaryText').Text = '待处理清单已过期，必须重新扫描。'
$window.FindName('ErrorMutationText').Text = '没有执行任何系统修改。'
$window.FindName('ErrorDetailText').Text = $_.Exception.Message
Set-GuiState error
```

Retain all existing `New-PendingSubsetPayload`, deep JSON, identity-key, and temporary-file cleanup tests.

- [ ] **Step 5: Run all GUI tests and verify GREEN**

Expected: existing pending v2, deep payload, identity merge, temp cleanup, mixed matcher, and selection tests all report `FailedCount: 0`.

- [ ] **Step 6: Commit the review journey**

```powershell
git add gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: show safe review and matcher evidence"
```

### Task 6: Execute asynchronously and show truthful per-item results

**Files:**
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Write failing tests for waiting, partial success, UAC cancellation, and cleanup**

Use mocked `Start-Process`, a fake process exposing `HasExited`/`ExitCode`, and a temp pending subset. Assert:

```powershell
Set-GuiState review -Force
Start-GuiExecution | Should -BeTrue
$script:GuiState | Should -Be 'executing'
@($script:Win.FindName('ExecutionList').ItemsSource).Count | Should -Be 3

$script:ExecutionProcess.HasExited = $true
$script:ExecutionProcess.ExitCode = 0
Complete-ExecutionPoll | Should -BeTrue
$script:GuiState | Should -Be 'completed'
$script:Win.FindName('CompletedSummaryText').Text | Should -Match '成功 1'
$script:Win.FindName('CompletedSummaryText').Text | Should -Match '失败 1'
$script:Win.FindName('CompletedSummaryText').Text | Should -Match '跳过 1'
```

Add separate assertions that a thrown UAC cancellation enters `error`, says no action was authorized, and removes only the exact generated `shushu_pending_<guid>.json` file while preserving an unrelated sentinel temp file.

- [ ] **Step 2: Run GUI tests and verify RED**

Expected: `Start-GuiExecution` and `Complete-ExecutionPoll` are undefined.

- [ ] **Step 3: Extract subset creation and elevated process start into `Start-GuiExecution`**

The function must reuse the existing checked filter and safety helpers:

```powershell
$checked = @($window.FindName('PendingList').Items | Where-Object { $_.IsChecked -and $_.CanExecute })
if ($checked.Count -eq 0) { return $false }
$src = Get-Content (Join-Path $script:Root 'pending_actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$payload = New-PendingSubsetPayload -Checked $checked -SourcePending $src
$script:ExecutionPendingPath = Join-Path $env:TEMP ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($script:ExecutionPendingPath, (ConvertTo-GuiPendingJson $payload), [System.Text.UTF8Encoding]::new($true))
$waiting = @($payload.actions | ForEach-Object { $_.status = 'pending'; $_ })
$window.FindName('ExecutionList').ItemsSource = @(ConvertTo-GuiExecutionRows $waiting)
Set-GuiState executing
$script:ExecutionProcess = Start-Process powershell -Verb RunAs -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script:Root\cpu-cleaner.ps1`"",'-Mode','clean','-YesToAll','-PendingFileArg',"`"$script:ExecutionPendingPath`""
```

Wrap the complete function in `try/catch`; on failure call `Set-GuiError -Stage 'authorization' -MutationSummary '管理员授权未完成，没有开始处理。' -Exception $_.Exception`, remove the exact temp file in `finally` only when no process was started, and return `$false`.

- [ ] **Step 4: Poll without blocking the WPF thread**

Create a 500 ms DispatcherTimer. On each tick, if the subset file can be read, project its actions with `ConvertTo-GuiExecutionRows` and refresh `ExecutionList.ItemsSource`. Never call `WaitForExit()` on the UI thread.

Implement `Complete-ExecutionPoll` to return `$false` while the process is running. After exit:

```powershell
$sum = Get-CleanResultSummary -Path $script:ExecutionPendingPath
Merge-PendingStatus $script:ExecutionPendingPath
$rows = @(ConvertTo-GuiExecutionRows (Get-PendingItems -Path $script:ExecutionPendingPath))
$window.FindName('CompletedList').ItemsSource = $rows
$window.FindName('CompletedSummaryText').Text = ('成功 {0} · 失败 {1} · 跳过 {2} · 手动 {3}' -f $sum.success,$sum.failed,$sum.skipped,$sum.manual_required)
```

If exit code is `0`, enter `completed` even when some items failed or were skipped; the summary must remain partial and truthful. If exit code is nonzero, enter `error` and state that some actions may already have run, then display any readable item statuses. In all terminal paths, remove only `$script:ExecutionPendingPath` and clear the script variables.

- [ ] **Step 5: Add a single error helper**

```powershell
function Set-GuiError {
    param([string]$Stage, [string]$MutationSummary, [System.Exception]$Exception)
    $window.FindName('ErrorSummaryText').Text = "阶段失败：$Stage"
    $window.FindName('ErrorMutationText').Text = $MutationSummary
    $window.FindName('ErrorDetailText').Text = if ($Exception) { $Exception.ToString() } else { '' }
    Set-GuiState error
}
```

- [ ] **Step 6: Run GUI tests and verify GREEN**

Expected: no UI-thread blocking test remains; partial results, nonzero exit, UAC cancellation, temp-file cleanup, deep pending serialization, and merge identity all pass.

- [ ] **Step 7: Commit asynchronous execution**

```powershell
git add gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: show asynchronous per-item clean results"
```

### Task 7: Finish restore, language, accessibility, and scaling behavior

**Files:**
- Modify: `src/Gui/MainWindow.xaml`
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Write failing tests for restore outcomes, language coverage, and keyboard behavior**

Add assertions that:

```powershell
$script:Lang='zh'; Apply-Language
$script:Win.FindName('StateTitle').Text | Should -Not -BeNullOrEmpty
$script:Lang='en'; Apply-Language
$script:Win.FindName('StateTitle').Text | Should -Match 'Scan|Review|Result|Interrupted|Fantasy'
$script:Win.FindName('BtnStartScan').IsDefault | Should -BeTrue
$script:Win.FindName('BtnRetry').IsDefault | Should -BeTrue
[System.Windows.Input.KeyboardNavigation]::GetTabNavigation($script:Win.FindName('PendingList')).ToString() | Should -Be 'Continue'
```

Mock restore process outcomes `0`, `2`, nonzero, and thrown UAC cancellation. Assert success/partial/error wording and that restore never claims complete success for exit code `2`.

- [ ] **Step 2: Run GUI tests and verify RED**

Expected: untranslated state strings/default keyboard properties or restore state assertions fail.

- [ ] **Step 3: Complete all visible I18N keys**

Move every visible state title, subtitle, button label, count sentence, mutation summary, restore result, and matcher field label into `$script:I18N`. `Apply-Language` must update the currently visible state without changing `$script:GuiState`.

- [ ] **Step 4: Add keyboard and screen-reader properties in XAML**

Set `IsDefault="True"` on `BtnStartScan`, `BtnOpenReview`, `BtnExecute`, `BtnRescan`, and `BtnRetry`; because only one state panel is visible, only one default button is active. Do not add an `IsCancel` control: this design does not promise safe mid-execution cancellation. Add `AutomationProperties.Name` to image stage cards, primary actions, restore, language, result counts, and error summary. Set `KeyboardNavigation.TabNavigation="Continue"` on the review list.

- [ ] **Step 5: Keep layout usable at Windows scaling**

Wrap the state body in a `ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"`; keep the state summary outside that scroller and keep action controls in a bottom `DockPanel`. Do not assign fixed pixel heights to review or result lists except the window minimums already defined.

- [ ] **Step 6: Render restore results inside the single-page journey**

Retain the existing newest-backup lookup and CLI `-Mode restore -BackupDir` invocation. Replace modal-only success with a completed-state summary; keep a modal warning only for UAC/restore failure that requires immediate attention. Exit code `2` must use partial wording and list the manifest verification failures when available.

- [ ] **Step 7: Run GUI tests and verify GREEN**

Expected: all Chinese/English, restore, keyboard, XAML-load, state, and safety tests report `FailedCount: 0` under `powershell -STA`.

- [ ] **Step 8: Commit polish and accessibility**

```powershell
git add src/Gui/MainWindow.xaml gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: finish accessible fantasy journey"
```

### Task 8: Add deterministic visual QA and compare with the selected target

**Files:**
- Create: `tests/render-gui-states.ps1`
- Create: `docs/design-references/shushu-fantasy-comic-target.png`
- Update: `assets/rat_gui_preview.png`

- [ ] **Step 1: Preserve the selected visual target in the repository**

Copy the selected option 2 image from:

```text
C:\Users\34615\.codex\generated_images\019fe507-f3f8-77f0-9913-f3d354ce989d\exec-502995b2-4f18-4c1f-8c57-cfa308d8fa47.png
```

to `docs/design-references/shushu-fantasy-comic-target.png`. Verify both SHA-256 hashes are identical before committing.

Use:

```powershell
$source = 'C:\Users\34615\.codex\generated_images\019fe507-f3f8-77f0-9913-f3d354ce989d\exec-502995b2-4f18-4c1f-8c57-cfa308d8fa47.png'
$destinationDirectory = Join-Path (Get-Location) 'docs\design-references'
$destination = Join-Path $destinationDirectory 'shushu-fantasy-comic-target.png'
New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $destination
$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
if ($sourceHash -ne $destinationHash) { throw 'Design reference copy hash mismatch' }
```

- [ ] **Step 2: Create a non-mutating WPF renderer**

Create `tests/render-gui-states.ps1` with this non-mutating renderer:

```powershell
param([ValidateSet(1.0,1.25,1.5)][double]$Scale = 1.0)
$ErrorActionPreference = 'Stop'
$env:SHUSHU_CLEANER_TEST = '1'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'gui-cleaner.ps1')
$window = $script:TestWindow
$scaleLabel = [string][int]($Scale * 100)
$outputRoot = Join-Path $projectRoot ("artifacts\gui-states\$scaleLabel")
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$reviewRows = @(
    [pscustomobject]@{ IsChecked=$true; CanExecute=$true; name_cn='精确命中的安全服务'; action_label='禁用服务'; reason_cn='已实测，可恢复'; matcher_detail="命中字段: service_name`r`n命中类型: exact`r`n命中模式: ExactService" },
    [pscustomobject]@{ IsChecked=$false; CanExecute=$false; name_cn='宽匹配观察项'; action_label='仅观察'; reason_cn='宽匹配，不允许自动处理'; matcher_detail="命中字段: service_name`r`n命中类型: contains`r`n命中模式: Lenovo" }
)
$executionRows = @(
    [pscustomobject]@{ Name='安全服务'; StateLabel='成功' },
    [pscustomobject]@{ Name='计划任务'; StateLabel='失败' },
    [pscustomobject]@{ Name='启动项'; StateLabel='已跳过' }
)

function Save-WindowPng {
    param([string]$Path)
    $width = [int](1040 * $Scale); $height = [int](760 * $Scale)
    $window.Width = 1040; $window.Height = 760
    $window.Measure([System.Windows.Size]::new(1040,760))
    $window.Arrange([System.Windows.Rect]::new(0,0,1040,760))
    $window.UpdateLayout()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96*$Scale,96*$Scale,[System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

foreach ($state in Get-GuiStateNames) {
    $window.FindName('ResultSummaryText').Text = '2 项可以安全处理，4 项建议观察'
    $window.FindName('PendingList').ItemsSource = $reviewRows
    $window.FindName('ExecutionList').ItemsSource = $executionRows
    $window.FindName('CompletedList').ItemsSource = $executionRows
    $window.FindName('CompletedSummaryText').Text = '成功 1 · 失败 1 · 跳过 1 · 手动 0'
    $window.FindName('ErrorSummaryText').Text = '扫描失败：测试夹具错误'
    $window.FindName('ErrorMutationText').Text = '扫描阶段未修改任何系统设置。'
    $window.FindName('ErrorDetailText').Text = 'fixture_error: deterministic visual state'
    Set-GuiState -Name $state -Force
    Apply-Language
    Save-WindowPng (Join-Path $outputRoot "$state.png")
}
```

The script never raises a button event and therefore never calls `Start-Job`, `Start-Process`, scan, clean, or restore. The scale parameter changes pixel density while retaining the same logical window size.

- [ ] **Step 3: Run deterministic state rendering**

Run:

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\render-gui-states.ps1 -Scale 1.0
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\render-gui-states.ps1 -Scale 1.25
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\render-gui-states.ps1 -Scale 1.5
```

Expected: seven non-empty PNG files in each of `artifacts/gui-states/100`, `artifacts/gui-states/125`, and `artifacts/gui-states/150`, with no system mutation process launched.

- [ ] **Step 4: Perform visual comparison, not screenshot-only approval**

For each scale, inspect a side-by-side composite containing the selected target and the seven implementation screenshots. Check:

- all four real mouse images are visible and not stretched;
- the current stage is obvious and future stages are subdued;
- no text, checkbox, expander, button, or final list item is clipped;
- the fixed action area does not cover scrollable content;
- partial failure and error states remain visually prominent;
- the cream/black/yellow contrast matches the selected target without introducing blue-purple gradients;
- the comic remains visually dominant while technical detail stays folded.

Fix visible mismatches, rerender, and compare again. This repeat is required; a single screenshot pass is not acceptance.

- [ ] **Step 5: Update the checked-in GUI preview**

After the second comparison passes, copy `artifacts/gui-states/100/results.png` to `assets/rat_gui_preview.png`. Do not commit the whole `artifacts/` directory.

- [ ] **Step 6: Commit visual QA tooling and reference**

```powershell
git add tests/render-gui-states.ps1 docs/design-references/shushu-fantasy-comic-target.png assets/rat_gui_preview.png
git commit -m "test: add fantasy UI visual QA"
```

### Task 9: Update documentation and run the complete non-mutating gate

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the GUI documentation**

Replace the four-tab description with the exact journey:

```text
开始安全扫描（只读） → 扫描结论 → 处理建议复核 → 管理员重新验证并执行 → 逐项结果与恢复
```

Document that broad `contains`/`regex` matches appear as observations and cannot be selected, while executable items still undergo elevated same-matcher/current-object revalidation. State that the mouse comic is presentation only and does not determine safety.

- [ ] **Step 2: Run the focused GUI gates**

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File tests\run-gui-tests.ps1
```

Expected: both `GuiPresentation.Tests.ps1` and `Gui.Tests.ps1` pass with zero failures.

- [ ] **Step 3: Run the complete Pester suite**

```powershell
Import-Module Pester -RequiredVersion 5.9.0
$r = Invoke-Pester -Path tests\Pester -Output Detailed -PassThru
if ($r.FailedCount -gt 0) { throw "Pester failed: $($r.FailedCount)" }
```

Expected: the existing 212 tests plus any deliberately added core integration regressions pass; record exact passed/failed/skipped totals rather than assuming the old count.

- [ ] **Step 4: Run legacy logic and schema gates**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-unit.ps1
```

Expected: logic and Schema runners exit `0` and retain their current passing totals.

- [ ] **Step 5: Run AST, JSON, and analyzer gates**

```powershell
$parseFailures = @()
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    if ($errors) { $parseFailures += $errors }
}
if ($parseFailures.Count) { $parseFailures | Format-List; throw 'PowerShell AST failures' }

Get-ChildItem -Recurse -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null }

Import-Module PSScriptAnalyzer
$issues = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error)
if ($issues.Count) { $issues | Format-Table; throw "PSScriptAnalyzer errors: $($issues.Count)" }
```

Expected: zero AST parse errors, zero JSON parse errors, and zero Error-severity analyzer findings.

- [ ] **Step 6: Verify scope and commit documentation**

```powershell
git diff --check
git status --short
git diff --stat HEAD~8..HEAD
git add README.md
git commit -m "docs: describe single-page cleaner journey"
```

Confirm no core safety file changed without a corresponding focused regression test and review. Confirm tests did not perform a real clean, restore, service/task/Run-key/process mutation, or publish operation.

- [ ] **Step 7: Record final evidence**

Capture exact GUI, Pester, legacy, AST, JSON, and analyzer totals; list the implementation commits; state that visual rendering used fixtures and that runtime system mutation acceptance remains deliberately unperformed.
