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
        BtnLoad='读取待处理清单'; PendingHint='按风险/实测展示，勾选要处理的项目（未实测=仅观察，默认不勾选）'; PendingNone='没有待处理项目——请先到【1. 扫描】页扫描（或已全部处理完）'; PendingCount='共 {0} 项待处理。勾选后到【3. 执行】页处理。'
        SelectAll='全选'; ClearAll='清空'
        ExecInfo1='在【2. 处理建议】页勾选要处理的项目，到这里一键执行。'; ExecInfo2='每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。'
        BtnExec='处理已勾选项目（需要管理员）'; ExecEmpty='请先勾选要处理的项目（【2. 处理建议】页勾选）。'; ExecStart='将处理 {0} 项。已请求管理员权限，请在弹窗点【是】…'; ExecDone='处理窗口已结束。到【4. 结果】页查看（建议重启电脑让改动完全生效）。'
        ExecFailed='执行失败: ExitCode={0}（可能被取消或出错）'; ExecDoneSum='执行完成: success {0} / failed {1} / skipped {2}'
        BtnResult='查看最近处理结果'; BtnRestore='恢复最近一次处理'; ResultHint='恢复会弹管理员窗口，选最新备份还原'
        NoBackup='还没有备份记录（还没处理过）。'; RestoreOk='已恢复 {0}。详见管理员窗口。'; RestoreNone='还没有备份，无需恢复。'; RestoreErr='恢复出错或被取消: {0}'; RestorePartial='恢复完成，但部分条目验证失败（详见管理员窗口）。'
        LangLabel='EN'
    }
    'en' = @{
        AppName='Shushu Cleaner'; SubTitle='Scan · Clean · Restore — auto backup, undo anytime'; Hint0='GUI is a shell; core logic is identical to CLI'
        TabScan='🐹 1. Scan (read-only)'; TabPending='📋 2. Recommendations'; TabExec='⚙️ 3. Execute (admin)'; TabResult='✅ 4. Result & Restore'
        BtnScan='Start Scan'; ScanHint='Scan only reads, changes nothing'; Scanning='Scanning, please wait…'
        BtnLoad='Load Pending Items'; PendingHint='Risk & evidence shown; check items to process (unverified = observe only, unchecked)'; PendingNone='No pending items — run Scan first (or all done)'; PendingCount='{0} item(s) pending. Check items, then go to tab 3.'
        SelectAll='Select All'; ClearAll='Clear'
        ExecInfo1='Check items in tab 2, then process them here.'; ExecInfo2='Every action is backed up and verified. UAC popup: click YES.'
        BtnExec='Process Checked Items (admin)'; ExecEmpty='Check items first (tab 2).'; ExecStart='Processing {0} item(s). UAC requested, click YES…'; ExecDone='Processing done. See tab 4 (restart PC recommended).'
        ExecFailed='Execution failed: ExitCode={0} (cancelled or error)'; ExecDoneSum='Done: success {0} / failed {1} / skipped {2}'
        BtnResult='Show Latest Result'; BtnRestore='Restore Last Changes'; ResultHint='Restore opens admin window, picks newest backup'
        NoBackup='No backup yet (nothing processed).'; RestoreOk='Restored {0}. See admin window.'; RestoreNone='No backup, nothing to restore.'; RestoreErr='Restore failed/cancelled: {0}'; RestorePartial='Restore finished, but some items failed verification (see admin window).'
        LangLabel='中文'
    }
}

function Get-Text($key) { return $script:I18N[$script:Lang][$key] }

function Apply-Language {
    $t = $script:I18N[$script:Lang]
    $w = $window
    $w.Title = $t['AppName']
    $w.FindName('TitleMain').Text = $t['AppName']
    $w.FindName('TitleSub').Text = $t['SubTitle']
    $w.FindName('TitleHint').Text = $t['Hint0']
    $w.FindName('TabScan').Header = $t['TabScan']
    $w.FindName('TabPending').Header = $t['TabPending']
    $w.FindName('TabExec').Header = $t['TabExec']
    $w.FindName('TabResult').Header = $t['TabResult']
    $w.FindName('BtnScan').Content = $t['BtnScan']
    $w.FindName('ScanHint').Text = $t['ScanHint']
    $w.FindName('BtnLoadPending').Content = $t['BtnLoad']
    $w.FindName('BtnSelectAll').Content = $t['SelectAll']
    $w.FindName('BtnClearAll').Content = $t['ClearAll']
    $w.FindName('PendingHint').Text = $t['PendingHint']
    $w.FindName('ExecInfo1').Text = $t['ExecInfo1']
    $w.FindName('ExecInfo2').Text = $t['ExecInfo2']
    $w.FindName('BtnExec').Content = $t['BtnExec']
    $w.FindName('BtnResult').Content = $t['BtnResult']
    $w.FindName('BtnRestore').Content = $t['BtnRestore']
    $w.FindName('ResultHint').Text = $t['ResultHint']
    $w.FindName('BtnLang').Content = $t['LangLabel']
}

# ---------- 鼠鼠风格 XAML ----------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="鼠鼠cleaner" Width="880" Height="660"
        WindowStartupLocation="CenterScreen" Background="#FFF6DC"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <StreamGeometry x:Key="RatHeadGeo">M45 58 C58 46 182 46 195 58 C220 72 236 98 238 128 C240 156 198 180 120 180 C42 180 0 156 2 128 C4 98 20 72 45 58 Z</StreamGeometry>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- 头部: 鼠鼠 + 标题 + 语言切换 -->
    <Border Grid.Row="0" Background="#211D16" CornerRadius="14" Margin="0,0,0,10">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Viewbox Width="150" Height="113" Margin="14,4,4,2">
        <Canvas Width="240" Height="180">
          <Ellipse Canvas.Left="28"  Canvas.Top="33" Width="36" Height="30" Fill="#8D8478" Stroke="#211D16" StrokeThickness="3.5"/>
          <Ellipse Canvas.Left="35"  Canvas.Top="39" Width="18" Height="14" Fill="#D9A8A0"/>
          <Ellipse Canvas.Left="176" Canvas.Top="33" Width="36" Height="30" Fill="#8D8478" Stroke="#211D16" StrokeThickness="3.5"/>
          <Ellipse Canvas.Left="183" Canvas.Top="39" Width="18" Height="14" Fill="#D9A8A0"/>
          <Path Data="M45 58 C58 46 182 46 195 58 C220 72 236 98 238 128 C240 156 198 180 120 180 C42 180 0 156 2 128 C4 98 20 72 45 58 Z" Fill="#F1EBE1" Stroke="#211D16" StrokeThickness="4.5"/>
          <Path Data="M4 100 C40 92 70 96 95 96 C108 96 114 102 120 110 C126 102 132 96 145 96 C170 96 200 92 236 100 L236 240 L4 240 Z" Fill="#8D8478" Clip="{StaticResource RatHeadGeo}"/>
          <Ellipse Canvas.Left="54" Canvas.Top="57" Width="40" Height="22" Fill="#6F675C" Opacity="0.28"/>
          <Ellipse Canvas.Left="146" Canvas.Top="57" Width="40" Height="22" Fill="#6F675C" Opacity="0.28"/>
          <Ellipse Canvas.Left="53" Canvas.Top="82.5" Width="30" Height="27" Fill="#231E1B">
            <Ellipse.RenderTransform><RotateTransform Angle="-4" CenterX="68" CenterY="96"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse Canvas.Left="157" Canvas.Top="82.5" Width="30" Height="27" Fill="#231E1B">
            <Ellipse.RenderTransform><RotateTransform Angle="4" CenterX="172" CenterY="96"/></Ellipse.RenderTransform>
          </Ellipse>
          <Path Data="M114 110 Q120 107 126 110 Q128 115 120 120 Q112 115 114 110 Z" Fill="#D89C96" Stroke="#211D16" StrokeThickness="2"/>
          <Line X1="120" Y1="116" X2="120" Y2="124" Stroke="#C08880" StrokeThickness="2.5"/>
          <Path Data="M74 116 L166 116 C166 138 148 150 120 150 C92 150 74 138 74 116 Z" Fill="#171210"/>
          <Rectangle Canvas.Left="86" Canvas.Top="114" Width="68" Height="24" RadiusX="6" RadiusY="6" Fill="#FFFFFF" Stroke="#211D16" StrokeThickness="2.5"/>
          <Line X1="120" Y1="114" X2="120" Y2="138" Stroke="#211D16" StrokeThickness="2.5"/>
        </Canvas>
      </Viewbox>
      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
        <TextBlock x:Name="TitleMain" Text="鼠鼠cleaner" FontSize="26" FontWeight="Bold" Foreground="#FFD21F"/>
        <TextBlock x:Name="TitleSub" Text="扫描 · 清理 · 恢复 —— 全程自动备份，后悔可还原" FontSize="12" Foreground="#FFF6DC"/>
        <TextBlock x:Name="TitleHint" Text="图形界面只是壳，核心逻辑与命令行版一致" FontSize="10" Foreground="#8D8478"/>
      </StackPanel>
      <Button x:Name="BtnLang" Grid.Column="2" Content="EN" Width="46" Height="30" Margin="0,0,14,0" VerticalAlignment="Center" Background="#FFD21F" Foreground="#211D16" FontWeight="Bold" BorderThickness="0"/>
    </Grid>
    </Border>

    <!-- 4 页 Tab -->
    <TabControl Grid.Row="1" Background="Transparent" BorderThickness="0">
      <TabItem x:Name="TabScan" Header="🐹 1. 扫描（只读）">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Image x:Name="ImgScan" Source="assets/rat_scan.jpg" Width="72" Height="72" Stretch="UniformToFill" Margin="0,0,10,0"/>
            <StackPanel>
              <Button x:Name="BtnScan" Content="开始扫描" Width="130" Height="36" Background="#FFD21F" Foreground="#211D16" FontWeight="Bold" BorderThickness="0"/>
              <TextBlock x:Name="ScanHint" Text="扫描只查看、不改任何设置，随便点" Foreground="#666" Margin="0,4,0,0"/>
            </StackPanel>
          </StackPanel>
          <ProgressBar x:Name="ScanProgress" Grid.Row="1" Height="10" Margin="0,0,0,6" Foreground="#FFD21F" Background="#E8DCC0" BorderThickness="0" Minimum="0" Maximum="100" Value="0"/>
          <TextBox x:Name="ScanOutput" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" Background="#1E1E1E" Foreground="#DDD" BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabPending" Header="📋 2. 处理建议">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Image x:Name="ImgPending" Source="assets/rat_pending.jpg" Width="72" Height="72" Stretch="UniformToFill" Margin="0,0,10,0"/>
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnLoadPending" Content="读取待处理清单" Width="150" Height="30" Background="#FFD21F" Foreground="#211D16" FontWeight="Bold" BorderThickness="0"/>
                <Button x:Name="BtnSelectAll" Content="全选" Width="64" Height="30" Background="#27AE60" Foreground="White" BorderThickness="0" Margin="8,0,0,0"/>
                <Button x:Name="BtnClearAll" Content="清空" Width="64" Height="30" Background="#95A5A6" Foreground="White" BorderThickness="0" Margin="6,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="PendingHint" Text="按风险/实测展示，勾选要处理的项目（未实测=仅观察，默认不勾选）" Foreground="#666" Margin="0,4,0,0"/>
            </StackPanel>
          </StackPanel>
          <ListView x:Name="PendingList" Grid.Row="1" BorderThickness="1" BorderBrush="#DDD" Background="#FFFDF4">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="☑" Width="40">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding IsChecked}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="项目" Width="180" DisplayMemberBinding="{Binding name_cn}"/>
                <GridViewColumn Header="风险" Width="70" DisplayMemberBinding="{Binding risk_label}"/>
                <GridViewColumn Header="实测" Width="80" DisplayMemberBinding="{Binding evidence_label}"/>
                <GridViewColumn Header="建议" Width="80" DisplayMemberBinding="{Binding action_label}"/>
                <GridViewColumn Header="恢复" Width="56" DisplayMemberBinding="{Binding restorable_label}"/>
                <GridViewColumn Header="状态" Width="70" DisplayMemberBinding="{Binding status}"/>
                <GridViewColumn Header="说明" Width="280" DisplayMemberBinding="{Binding reason_cn}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabExec" Header="⚙️ 3. 执行（管理员）">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Image x:Name="ImgExec" Source="assets/rat_exec.jpg" Width="72" Height="72" Stretch="UniformToFill" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="ExecInfo1" Text="点击下面按钮，会把【处理建议】里的全部项目处理掉。" Foreground="#333"/>
              <TextBlock x:Name="ExecInfo2" Text="每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。" Foreground="#666" Margin="0,4,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                <Button x:Name="BtnExec" Content="执行全部处理（需要管理员）" Width="230" Height="38" Background="#E74C3C" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
                <TextBlock x:Name="ExecHint" Text="" Foreground="#C0392B" VerticalAlignment="Center" Margin="10,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
          <TextBox x:Name="ExecOutput" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" Background="#1E1E1E" Foreground="#DDD" BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabResult" Header="✅ 4. 结果与恢复">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Image x:Name="ImgResult" Source="assets/rat_result.jpg" Width="72" Height="72" Stretch="UniformToFill" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnResult" Content="查看最近处理结果" Width="150" Height="36" Background="#27AE60" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
                <Button x:Name="BtnRestore" Content="恢复最近一次处理" Width="150" Height="36" Background="#95A5A6" Foreground="White" FontWeight="Bold" BorderThickness="0" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="ResultHint" Text="恢复会弹管理员窗口，选最新备份还原" Foreground="#666" Margin="0,4,0,0"/>
            </StackPanel>
          </StackPanel>
          <TextBox x:Name="ResultOutput" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" Background="#1E1E1E" Foreground="#DDD" BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 鼠鼠页面形象图: 用绝对路径 (Image Source 相对路径按工作目录解析, 不可靠)
$script:ImgMap = @{
    'ImgScan'   = 'assets/rat_scan.jpg'
    'ImgPending'= 'assets/rat_pending.jpg'
    'ImgExec'   = 'assets/rat_exec.jpg'
    'ImgResult' = 'assets/rat_result.jpg'
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

function Get-PendingItems {
    param([string]$Path = '')
    $pf = if ($Path) { $Path } else { Join-Path $script:Root 'pending_actions.json' }
    if (-not (Test-Path $pf)) { return @() }
    $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $p.actions) { return @() }
    return @($p.actions)
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

# v1.5.5: 构造勾选展示对象 — 风险/实测/建议/可恢复标签
# 只显示可处理状态 (pending/failed); 默认勾选 = 可自动处理 (investigate/none 仅观察不勾选)
function Get-PendingViewItems {
    $items = @(Get-PendingItems | Where-Object { $_.status -in @('pending','failed') })
    $map = Get-ProfileLookup
    $view = @()
    foreach ($i in $items) {
        $rule = $map[$i.id]
        $riskLabel = '未知'
        $evidenceLabel = '未实测'
        if ($rule) {
            $riskLabel = switch ($rule.risk) { 'high' { '高风险' } 'medium' { '中风险' } 'low' { '低风险' } default { '未知' } }
            $evidenceLabel = if ($rule.evidence -and $rule.evidence.tested) { ('实测 {0} 台' -f $rule.evidence.tested_count) } else { '未实测' }
        }
        $canAuto = $i.action -ne 'investigate' -and $i.action -ne 'none'
        $view += [pscustomobject]@{
            IsChecked         = $canAuto
            name_cn           = $i.name_cn
            risk_label        = $riskLabel
            evidence_label    = $evidenceLabel
            action_label      = Get-ActionLabel $i.action
            restorable_label  = '可恢复'
            status            = $i.status
            reason_cn         = $i.reason_cn
            _raw              = $i
        }
    }
    return $view
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
            $sameKey = ($ma.id -eq $sa.id) -and ($ma.hit_type -eq $sa.hit_type) -and
                       ($ma.service_name -eq $sa.service_name) -and ($ma.autostart_name -eq $sa.autostart_name) -and
                       ($ma.task_path -eq $sa.task_path) -and ($ma.process_name -eq $sa.process_name)
            if ($sameKey) { $ma.status = $sa.status }
        }
    }
    $main | ConvertTo-Json -Depth 5 | Out-File $mainPath -Encoding utf8
}

# v1.5.3: 扫描 job 收尾统一处理 — Completed 成功 / Failed / Stopped 都要恢复 UI
# 返回 $true 表示 job 已结束 (轮询 timer 应停止), $false 表示仍在运行
function Complete-ScanPoll {
    param($job, $checkTimer, $scanTimer, $btn, $prog, $out)
    if ($job.State -notin @('Completed','Failed','Stopped')) { return $false }
    $checkTimer.Stop()
    $scanTimer.Stop()
    try { $result = Receive-Job $job -ErrorAction SilentlyContinue } catch { $result = '' }
    try { Remove-Job $job -Force -ErrorAction SilentlyContinue } catch {}
    $prog.Value = 100
    if ($job.State -eq 'Completed') { $out.Text = $result }
    else { $out.Text = "扫描失败 (后台任务状态: $($job.State))`r`n$result" }
    $btn.IsEnabled = $true
    return $true
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

# ---------- 扫描 (后台 job + 进度条动画) ----------
$script:ScanTimer = $null
$window.FindName('BtnScan').Add_Click({
    $btn = $window.FindName('BtnScan')
    $out = $window.FindName('ScanOutput')
    $prog = $window.FindName('ScanProgress')
    $btn.IsEnabled = $false
    $out.Text = (Get-Text 'Scanning')
    $prog.Value = 0

    # 进度条动画 (UI 线程定时推进)
    $script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:ScanTimer.Add_Tick({
        if ($prog.Value -lt 90) { $prog.Value += (Get-Random -Minimum 2 -Maximum 6) }
        if ($prog.Value -gt 90) { $prog.Value = 90 }
    })
    $script:ScanTimer.Start()

    # 后台 job 跑 scan
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script:Root\cpu-cleaner.ps1`" -Mode scan"
    $job = Start-Job -ScriptBlock { param($c) cmd /c $c 2>&1 | Out-String } -ArgumentList $cmd

    # 轮询 job 完成 (UI 不卡: 用第二个 timer; v1.5.3: Completed/Failed/Stopped 都收尾)
    $checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $checkTimer.Add_Tick({
        if (Complete-ScanPoll -job $job -checkTimer $checkTimer -scanTimer $script:ScanTimer -btn $btn -prog $prog -out $out) {
            $checkTimer.Stop()
        }
    })
    $checkTimer.Start()
})

# ---------- 读取处理建议 (v1.5.5: 勾选视图 — 风险/实测/建议标签 + 默认勾选 + 全选/清空) ----------
$window.FindName('BtnLoadPending').Add_Click({
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
})

# v1.5.5: 全选 / 清空 勾选
$window.FindName('BtnSelectAll').Add_Click({
    $list = $window.FindName('PendingList')
    foreach ($it in @($list.Items)) { $it.IsChecked = $true }
    $list.Items.Refresh()
})
$window.FindName('BtnClearAll').Add_Click({
    $list = $window.FindName('PendingList')
    foreach ($it in @($list.Items)) { $it.IsChecked = $false }
    $list.Items.Refresh()
})

# ---------- 处理已勾选项目 (v1.5.5: 勾选子集 → 临时清单 → clean -PendingFileArg) ----------
$window.FindName('BtnExec').Add_Click({
    $hint = $window.FindName('ExecHint')
    $out = $window.FindName('ExecOutput')
    $list = $window.FindName('PendingList')
    $checked = @($list.Items | Where-Object { $_.IsChecked })
    if ($checked.Count -eq 0) {
        $hint.Text = (Get-Text 'ExecEmpty')
        return
    }
    $hint.Text = ((Get-Text 'ExecStart') -f $checked.Count)
    try {
        # 构造勾选子集临时清单 (完整 payload 结构, 只含勾选条目; suspicious 原样带上)
        $tmpPending = Join-Path $env:TEMP ("shushu_pending_" + [guid]::NewGuid().ToString('N') + ".json")
        $srcPendingPath = Join-Path $script:Root 'pending_actions.json'
        $suspArr = @()
        if (Test-Path $srcPendingPath) {
            $src = Get-Content $srcPendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($src.suspicious) { $suspArr = @($src.suspicious) }
        }
        $actions = @()
        foreach ($c in $checked) {
            $r = $c._raw
            $actions += [pscustomobject]@{
                id=$r.id; vendor=$r.vendor; name_cn=$r.name_cn; action=$r.action; hit_type=$r.hit_type
                detail=$r.detail; reason_cn=$r.reason_cn; service_name=$r.service_name
                autostart_source=$r.autostart_source; autostart_name=$r.autostart_name
                task_path=$r.task_path; process_name=$r.process_name; safe=$r.safe; status='pending'
            }
        }
        $payload = [pscustomobject]@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); actions=$actions; suspicious=$suspArr }
        $payload | ConvertTo-Json -Depth 5 | Out-File $tmpPending -Encoding utf8

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
        $hint.Text = "ERR: $($_.Exception.Message)"
    }
})

# ---------- 查看最近结果 ----------
$window.FindName('BtnResult').Add_Click({
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
})

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

Apply-Language
if ($script:TestMode) {
    # 测试模式: 不显示窗口, 暴露窗口对象供 Pester 无窗口断言
    $script:TestWindow = $window
} else {
    $window.ShowDialog() | Out-Null
}
