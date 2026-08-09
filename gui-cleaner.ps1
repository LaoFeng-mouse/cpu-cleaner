# ============================================================
#  鼠鼠cleaner - 图形界面 (gui-cleaner.ps1)
#  需要: Windows 10/11 + PowerShell 5.1 (自带 WPF)
#  用法: 双击 鼠鼠cleaner.bat 或 powershell -File gui-cleaner.ps1
# ============================================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Lang = 'zh'   # zh / en

# ---------- 单实例: 只能开一个窗口 ----------
$existing = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -match '鼠鼠cleaner' }
if ($existing) {
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
        BtnLoad='读取待处理清单'; PendingHint='显示扫描后需要处理的项目（未扫描或清单为空则无内容）'; PendingNone='没有待处理项目——请先到【1. 扫描】页扫描（或已全部处理完）'; PendingCount='共 {0} 项待处理。到【3. 执行】页一键处理。'
        ExecInfo1='点击下面按钮，会把【处理建议】里的全部项目处理掉。'; ExecInfo2='每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。'
        BtnExec='执行全部处理（需要管理员）'; ExecEmpty='没有待处理项目，请先扫描。'; ExecStart='将处理 {0} 项。已请求管理员权限，请在弹窗点【是】…'; ExecDone='处理窗口已结束。到【4. 结果】页查看（建议重启电脑让改动完全生效）。'
        BtnResult='查看最近处理结果'; BtnRestore='恢复最近一次处理'; ResultHint='恢复会弹管理员窗口，选最新备份还原'
        NoBackup='还没有备份记录（还没处理过）。'; RestoreOk='已恢复 {0}。详见管理员窗口。'; RestoreNone='还没有备份，无需恢复。'; RestoreErr='恢复出错或被取消: {0}'
        LangLabel='EN'
    }
    'en' = @{
        AppName='Shushu Cleaner'; SubTitle='Scan · Clean · Restore — auto backup, undo anytime'; Hint0='GUI is a shell; core logic is identical to CLI'
        TabScan='🐹 1. Scan (read-only)'; TabPending='📋 2. Recommendations'; TabExec='⚙️ 3. Execute (admin)'; TabResult='✅ 4. Result & Restore'
        BtnScan='Start Scan'; ScanHint='Scan only reads, changes nothing'; Scanning='Scanning, please wait…'
        BtnLoad='Load Pending Items'; PendingHint='Items to process after scan (empty if none)'; PendingNone='No pending items — run Scan first (or all done)'; PendingCount='{0} item(s) pending. Go to tab 3 to process.'
        ExecInfo1='Click below to process all recommended items.'; ExecInfo2='Every action is backed up and verified. UAC popup: click YES.'
        BtnExec='Process All (admin)'; ExecEmpty='No pending items. Scan first.'; ExecStart='Processing {0} item(s). UAC requested, click YES…'; ExecDone='Processing done. See tab 4 (restart PC recommended).'
        BtnResult='Show Latest Result'; BtnRestore='Restore Last Changes'; ResultHint='Restore opens admin window, picks newest backup'
        NoBackup='No backup yet (nothing processed).'; RestoreOk='Restored {0}. See admin window.'; RestoreNone='No backup, nothing to restore.'; RestoreErr='Restore failed/cancelled: {0}'
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
              <Button x:Name="BtnLoadPending" Content="读取待处理清单" Width="150" Height="36" Background="#FFD21F" Foreground="#211D16" FontWeight="Bold" BorderThickness="0"/>
              <TextBlock x:Name="PendingHint" Text="显示扫描后需要处理的项目（未扫描或清单为空则无内容）" Foreground="#666" Margin="0,4,0,0"/>
            </StackPanel>
          </StackPanel>
          <ListView x:Name="PendingList" Grid.Row="1" BorderThickness="1" BorderBrush="#DDD" Background="#FFFDF4">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="项目" Width="230" DisplayMemberBinding="{Binding name_cn}"/>
                <GridViewColumn Header="动作" Width="110" DisplayMemberBinding="{Binding action}"/>
                <GridViewColumn Header="状态" Width="90" DisplayMemberBinding="{Binding status}"/>
                <GridViewColumn Header="说明" Width="330" DisplayMemberBinding="{Binding reason_cn}"/>
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
    $pf = Join-Path $script:Root 'pending_actions.json'
    if (-not (Test-Path $pf)) { return @() }
    $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $p.actions) { return @() }
    return @($p.actions)
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

    # 轮询 job 完成 (UI 不卡: 用第二个 timer)
    $checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(800)
    $checkTimer.Add_Tick({
        if ($job.State -eq 'Completed') {
            $checkTimer.Stop()
            $script:ScanTimer.Stop()
            $result = Receive-Job $job
            Remove-Job $job -Force
            $prog.Value = 100
            $out.Text = $result
            $btn.IsEnabled = $true
        }
    })
    $checkTimer.Start()
})

# ---------- 读取处理建议 (修复: 兜底提示 + 强制刷新) ----------
$window.FindName('BtnLoadPending').Add_Click({
    $list = $window.FindName('PendingList')
    $hint = $window.FindName('PendingHint')
    $items = @(Get-PendingItems)
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

# ---------- 执行全部处理 ----------
$window.FindName('BtnExec').Add_Click({
    $hint = $window.FindName('ExecHint')
    $out = $window.FindName('ExecOutput')
    $items = @(Get-PendingItems)
    if ($items.Count -eq 0) {
        $hint.Text = (Get-Text 'ExecEmpty')
        return
    }
    $hint.Text = ((Get-Text 'ExecStart') -f $items.Count)
    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$script:Root\cpu-cleaner.ps1",'-Mode','clean','-YesToAll' -Wait
        $hint.Text = (Get-Text 'ExecDone')
        $out.Text = (Get-Text 'ExecDone')
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
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$script:Root\cpu-cleaner.ps1",'-Mode','restore','-BackupDir',"$script:Root\backups\$($latest.Name)" -Wait
        [System.Windows.MessageBox]::Show(((Get-Text 'RestoreOk') -f $latest.Name), (Get-Text 'AppName'), 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show(((Get-Text 'RestoreErr') -f $_.Exception.Message), (Get-Text 'AppName'), 'OK', 'Warning') | Out-Null
    }
})

Apply-Language
$window.ShowDialog() | Out-Null
