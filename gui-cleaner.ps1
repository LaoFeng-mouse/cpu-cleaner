# ============================================================
#  CPU 后台整理工具 - 鼠鼠版图形界面 (gui-cleaner.ps1)
#  需要: Windows 10/11 + PowerShell 5.1 (自带 WPF, 无需安装)
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File gui-cleaner.ps1
#  或双击 "鼠鼠版-图形界面.bat"
# ============================================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- 鼠鼠风格 XAML (镜像大脸鼠: 黑色大圆脸 + 橘黄耳内) ----------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CPU 后台整理工具 - 鼠鼠版" Width="860" Height="620"
        WindowStartupLocation="CenterScreen" Background="#FFF6DC"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <!-- 鼠鼠头部几何 (viewBox 240, 与乐不思鼠 MascotRat.tsx 同参数) -->
    <StreamGeometry x:Key="RatHeadGeo">M45 58 C58 46 182 46 195 58 C220 72 236 98 238 128 C240 156 198 180 120 180 C42 180 0 156 2 128 C4 98 20 72 45 58 Z</StreamGeometry>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- 头部: 鼠鼠 + 标题 (鼠鼠风格指南配色: 墨黑底 + 蛋黄字) -->
    <Border Grid.Row="0" Background="#211D16" CornerRadius="14" Margin="0,0,0,10" Padding="0">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- 鼠鼠吉祥物 (镜像大脸鼠: 奶白柿饼脸+暖灰褐头盔+死黑豆眼+龇牙) -->
      <Viewbox Width="150" Height="113" Margin="14,4,4,2">
        <Canvas Width="240" Height="180">
          <!-- 耳朵 (压头下层, 外灰内粉) -->
          <Ellipse Canvas.Left="28"  Canvas.Top="33" Width="36" Height="30" Fill="#8D8478" Stroke="#211D16" StrokeThickness="3.5"/>
          <Ellipse Canvas.Left="35"  Canvas.Top="39" Width="18" Height="14" Fill="#D9A8A0"/>
          <Ellipse Canvas.Left="176" Canvas.Top="33" Width="36" Height="30" Fill="#8D8478" Stroke="#211D16" StrokeThickness="3.5"/>
          <Ellipse Canvas.Left="183" Canvas.Top="39" Width="18" Height="14" Fill="#D9A8A0"/>
          <!-- 头: 柿饼脸 -->
          <Path Data="M45 58 C58 46 182 46 195 58 C220 72 236 98 238 128 C240 156 198 180 120 180 C42 180 0 156 2 128 C4 98 20 72 45 58 Z" Fill="#F1EBE1" Stroke="#211D16" StrokeThickness="4.5"/>
          <!-- 头盔 (裁进头形) + 额斑 -->
          <Path Data="M4 100 C40 92 70 96 95 96 C108 96 114 102 120 110 C126 102 132 96 145 96 C170 96 200 92 236 100 L236 240 L4 240 Z" Fill="#8D8478" Clip="{StaticResource RatHeadGeo}"/>
          <Ellipse Canvas.Left="54" Canvas.Top="57" Width="40" Height="22" Fill="#6F675C" Opacity="0.28"/>
          <Ellipse Canvas.Left="146" Canvas.Top="57" Width="40" Height="22" Fill="#6F675C" Opacity="0.28"/>
          <!-- 眼睛: 死黑豆眼, 微外八 4度, 无高光 -->
          <Ellipse Canvas.Left="53" Canvas.Top="82.5" Width="30" Height="27" Fill="#231E1B">
            <Ellipse.RenderTransform><RotateTransform Angle="-4" CenterX="68" CenterY="96"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse Canvas.Left="157" Canvas.Top="82.5" Width="30" Height="27" Fill="#231E1B">
            <Ellipse.RenderTransform><RotateTransform Angle="4" CenterX="172" CenterY="96"/></Ellipse.RenderTransform>
          </Ellipse>
          <!-- 脏粉鼻 + 人中线 -->
          <Path Data="M114 110 Q120 107 126 110 Q128 115 120 120 Q112 115 114 110 Z" Fill="#D89C96" Stroke="#211D16" StrokeThickness="2"/>
          <Line X1="120" Y1="116" X2="120" Y2="124" Stroke="#C08880" StrokeThickness="2.5"/>
          <!-- 嘴: 黑嘴 + 两大白方牙 + 中缝 (happy 龇牙) -->
          <Path Data="M74 116 L166 116 C166 138 148 150 120 150 C92 150 74 138 74 116 Z" Fill="#171210"/>
          <Rectangle Canvas.Left="86" Canvas.Top="114" Width="68" Height="24" RadiusX="6" RadiusY="6" Fill="#FFFFFF" Stroke="#211D16" StrokeThickness="2.5"/>
          <Line X1="120" Y1="114" X2="120" Y2="138" Stroke="#211D16" StrokeThickness="2.5"/>
        </Canvas>
      </Viewbox>

      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,10,0">
        <TextBlock Text="CPU 后台整理工具" FontSize="24" FontWeight="Bold" Foreground="#FFD21F"/>
        <TextBlock Text="扫描 · 清理 · 恢复 —— 全程自动备份，后悔可还原" FontSize="12" Foreground="#FFF6DC"/>
        <TextBlock Text="鼠鼠版 v1.5.1（图形界面只是壳，核心逻辑与命令行版完全一致）" FontSize="10" Foreground="#8D8478"/>
      </StackPanel>
    </Grid>
    </Border>

    <!-- 4 页 Tab -->
    <TabControl Grid.Row="1" Background="Transparent" BorderThickness="0">
      <!-- 页 1: 扫描 -->
      <TabItem Header="🐹 1. 扫描（只读）">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="BtnScan" Content="开始扫描" Width="120" Height="36" Background="#F5A623" Foreground="#2C2C2C" FontWeight="Bold" BorderThickness="0"/>
            <TextBlock x:Name="ScanHint" Text="  扫描只查看、不改任何设置，随便点" VerticalAlignment="Center" Foreground="#666"/>
          </StackPanel>
          <TextBox x:Name="ScanOutput" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" Background="#1E1E1E" Foreground="#DDD" BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>

      <!-- 页 2: 处理建议 -->
      <TabItem Header="📋 2. 处理建议">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="BtnLoadPending" Content="读取待处理清单" Width="140" Height="36" Background="#F5A623" Foreground="#2C2C2C" FontWeight="Bold" BorderThickness="0"/>
            <TextBlock x:Name="PendingHint" Text="  显示扫描后需要处理的项目（未扫描或清单为空则无内容）" VerticalAlignment="Center" Foreground="#666"/>
          </StackPanel>
          <ListView x:Name="PendingList" Grid.Row="1" BorderThickness="1" BorderBrush="#DDD">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="项目" Width="240" DisplayMemberBinding="{Binding name_cn}"/>
                <GridViewColumn Header="动作" Width="120" DisplayMemberBinding="{Binding action}"/>
                <GridViewColumn Header="状态" Width="90" DisplayMemberBinding="{Binding status}"/>
                <GridViewColumn Header="说明" Width="320" DisplayMemberBinding="{Binding reason_cn}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </TabItem>

      <!-- 页 3: 执行 -->
      <TabItem Header="⚙️ 3. 执行（管理员）">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Text="点击下面按钮，会把【处理建议】里的全部项目处理掉。" Foreground="#333" Margin="0,0,0,4"/>
            <TextBlock Text="每个动作自动备份、执行后自动验证。会弹管理员确认窗口，点【是】。" Foreground="#666" Margin="0,0,0,8"/>
            <Button x:Name="BtnExec" Content="执行全部处理（需要管理员）" Width="240" Height="40" Background="#E74C3C" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
            <TextBlock x:Name="ExecHint" Text="" Foreground="#C0392B" Margin="0,6,0,0"/>
          </StackPanel>
          <TextBox x:Name="ExecOutput" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" Background="#1E1E1E" Foreground="#DDD" BorderThickness="0" Padding="8"/>
        </Grid>
      </TabItem>

      <!-- 页 4: 结果 -->
      <TabItem Header="✅ 4. 结果与恢复">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="BtnResult" Content="查看最近处理结果" Width="150" Height="36" Background="#27AE60" Foreground="White" FontWeight="Bold" BorderThickness="0"/>
            <Button x:Name="BtnRestore" Content="恢复最近一次处理" Width="150" Height="36" Background="#95A5A6" Foreground="White" FontWeight="Bold" BorderThickness="0" Margin="8,0,0,0"/>
            <TextBlock x:Name="ResultHint" Text="  恢复会弹管理员窗口，选最新备份还原" VerticalAlignment="Center" Foreground="#666" Margin="8,0,0,0"/>
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

# ---------- 工具函数 ----------
function Invoke-Output($sb) {
    # 同步执行, 把 stdout+stderr 合并返回
    $out = & $sb 2>&1 | Out-String
    return $out
}

function Get-PendingItems {
    $pf = Join-Path $script:Root 'pending_actions.json'
    if (-not (Test-Path $pf)) { return @() }
    $p = Get-Content $pf -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $p.actions) { return @() }
    return @($p.actions)
}

# ---------- 事件: 扫描 ----------
$window.FindName('BtnScan').Add_Click({
    $btn = $window.FindName('BtnScan')
    $out = $window.FindName('ScanOutput')
    $btn.IsEnabled = $false
    $out.Text = '正在扫描...'
    try {
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script:Root\cpu-cleaner.ps1`" -Mode scan"
        $text = cmd /c $cmd 2>&1 | Out-String
        $out.Text = $text
    } catch {
        $out.Text = "扫描出错: $($_.Exception.Message)"
    } finally {
        $btn.IsEnabled = $true
    }
})

# ---------- 事件: 读取处理建议 ----------
$window.FindName('BtnLoadPending').Add_Click({
    $list = $window.FindName('PendingList')
    $hint = $window.FindName('PendingHint')
    $items = Get-PendingItems
    if ($items.Count -eq 0) {
        $hint.Text = '  没有待处理项目 —— 请先到【1. 扫描】页扫描（或已经全部处理完）'
    } else {
        $hint.Text = "  共 $($items.Count) 项待处理。到【3. 执行】页一键处理。"
    }
    $list.ItemsSource = $items
})

# ---------- 事件: 执行全部处理 ----------
$window.FindName('BtnExec').Add_Click({
    $hint = $window.FindName('ExecHint')
    $out = $window.FindName('ExecOutput')
    $items = Get-PendingItems
    if ($items.Count -eq 0) {
        $hint.Text = '没有待处理项目，先扫描。'
        return
    }
    $hint.Text = "将处理 $($items.Count) 项。已请求管理员权限，请在弹窗点【是】..."
    try {
        # 提权运行 CLI 的 clean -YesToAll (复用核心逻辑, 不重复实现)
        $ps = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script:Root\cpu-cleaner.ps1`" -Mode clean -YesToAll"
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$script:Root\cpu-cleaner.ps1",'-Mode','clean','-YesToAll' -Wait
        $hint.Text = '处理窗口已结束。到【4. 结果】页查看（建议重启电脑让改动完全生效）。'
        $out.Text = '执行完成（详见管理员窗口输出）。建议重启电脑。'
    } catch {
        $hint.Text = "执行出错或被取消: $($_.Exception.Message)"
    }
})

# ---------- 事件: 查看最近结果 ----------
$window.FindName('BtnResult').Add_Click({
    $out = $window.FindName('ResultOutput')
    $backupRoot = Join-Path $script:Root 'backups'
    if (-not (Test-Path $backupRoot)) { $out.Text = '还没有备份记录（还没处理过）。'; return }
    $latest = Get-ChildItem $backupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { $out.Text = '还没有备份记录。'; return }
    $mf = Join-Path $latest.FullName 'manifest.json'
    if (-not (Test-Path $mf)) { $out.Text = "备份目录 $($latest.Name) 没有 manifest.json"; return }
    $man = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines = @("最近处理: $($latest.Name)", '')
    $ok = 0; $bad = 0
    foreach ($m in $man) {
        $verified = if ($m.verified) { '✓' } else { '✗' }
        $lines += "  $verified [$($m.type)] $($m.name)"
        if ($m.verified) { $ok++ } else { $bad++ }
    }
    $lines += ''
    $lines += "成功 $ok 项, 失败 $bad 项"
    $lines += ''
    $lines += "恢复方法: 点【恢复最近一次处理】按钮, 或命令行:"
    $lines += "  cpu-cleaner.ps1 -Mode restore -BackupDir `".\backups\$($latest.Name)`""
    $out.Text = ($lines -join "`r`n")
})

# ---------- 事件: 恢复最近一次处理 ----------
$window.FindName('BtnRestore').Add_Click({
    $backupRoot = Join-Path $script:Root 'backups'
    $latest = Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        [System.Windows.MessageBox]::Show('还没有备份，无需恢复。', '鼠鼠提示', 'OK', 'Information') | Out-Null
        return
    }
    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$script:Root\cpu-cleaner.ps1",'-Mode','restore','-BackupDir',"$script:Root\backups\$($latest.Name)" -Wait
        [System.Windows.MessageBox]::Show("已恢复 $($latest.Name)。详见管理员窗口。", '鼠鼠提示', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("恢复出错或被取消: $($_.Exception.Message)", '鼠鼠提示', 'OK', 'Warning') | Out-Null
    }
})

$window.ShowDialog() | Out-Null
