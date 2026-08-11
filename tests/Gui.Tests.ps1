# Pester 测试: GUI 壳 (WPF 无窗口验证, 必须用 powershell -STA 运行 — 见 tests/run-gui-tests.ps1)
# v1.5.3: GUI 是主要入口, CI 必须保护它 — XAML 加载 / 图片资源 / 语言切换 / 扫描轮询状态 / clean 统计
Describe 'GUI 壳 (无窗口)' {
    BeforeAll {
        $env:SHUSHU_CLEANER_TEST = '1'
        $script:GuiRoot = Split-Path $PSScriptRoot -Parent
        . (Join-Path $script:GuiRoot 'gui-cleaner.ps1')
        # dot-source 后把窗口对象显式存入 script scope, 供各 It 断言
        $script:Win = $window
        # fake DispatcherTimer: NoteProperty + ScriptMethod, 可被 $obj.Stop() 调用
        function New-FakeTimer {
            $t = New-Object PSObject
            $t | Add-Member -MemberType NoteProperty -Name Stopped -Value $false
            $t | Add-Member -MemberType NoteProperty -Name Started -Value $false
            $t | Add-Member -MemberType NoteProperty -Name TickHandler -Value $null
            $t | Add-Member -MemberType NoteProperty -Name Interval -Value $null
            $t | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true }
            $t | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Started = $true }
            $t | Add-Member -MemberType ScriptMethod -Name Add_Tick -Value { param($handler); $this.TickHandler = $handler }
            return $t
        }

        function Get-GuiRenderSnapshot {
            $panels = [ordered]@{}
            foreach ($name in $script:StatePanels) {
                $panels[$name] = $script:Win.FindName($name).Visibility.ToString()
            }
            $cards = [ordered]@{}
            for ($stage = 1; $stage -le 4; $stage++) {
                $card = $script:Win.FindName("StageCard$stage")
                $cards["StageCard$stage"] = [ordered]@{
                    Opacity = $card.Opacity
                    BorderBrush = $card.BorderBrush.ToString()
                    BorderThickness = @($card.BorderThickness.Left, $card.BorderThickness.Top, $card.BorderThickness.Right, $card.BorderThickness.Bottom)
                }
            }
            return [ordered]@{
                GuiState = $script:GuiState
                GuiActiveStage = $script:GuiActiveStage
                StateTitle = $script:Win.FindName('StateTitle').Text
                StateSubtitle = $script:Win.FindName('StateSubtitle').Text
                Panels = $panels
                Cards = $cards
            }
        }

        function New-GuiWindowProxy {
            param($RealWindow, [string]$MissingName = '', [string]$ReplacementName = '', $Replacement)
            $proxy = [pscustomobject]@{
                RealWindow = $RealWindow
                MissingName = $MissingName
                ReplacementName = $ReplacementName
                Replacement = $Replacement
            }
            $proxy | Add-Member -MemberType ScriptMethod -Name FindName -Value {
                param($name)
                if ($name -eq $this.MissingName) { return $null }
                if ($name -eq $this.ReplacementName) { return $this.Replacement }
                return $this.RealWindow.FindName($name)
            }
            return $proxy
        }

        function New-OneShotFailingControl {
            param($RealControl, [Parameter(Mandatory=$true)][string]$PropertyName)
            $values = @{}
            foreach ($name in @('Visibility','Opacity','BorderBrush','BorderThickness','Text')) {
                if ($RealControl.PSObject.Properties[$name]) { $values[$name] = $RealControl.$name }
            }
            $control = [pscustomobject]@{ Values=$values; FailProperty=$PropertyName; HasFailed=$false }
            foreach ($name in @($values.Keys)) {
                $property = $name
                $getter = { return $this.Values[$property] }.GetNewClosure()
                $setter = {
                    if ($property -eq $this.FailProperty -and -not $this.HasFailed) {
                        $this.HasFailed = $true
                        throw "Injected assignment failure: $property"
                    }
                    $this.Values[$property] = $args[0]
                }.GetNewClosure()
                $control | Add-Member -MemberType ScriptProperty -Name $name -Value $getter -SecondValue $setter
            }
            return $control
        }
    }

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

    It '鼠鼠图片资源存在' {
        foreach ($imgName in $script:ImgMap.Keys) {
            Test-Path (Join-Path $script:GuiRoot $script:ImgMap[$imgName]) | Should -Be $true
        }
    }

    It '四格漫画使用完整叙事素材且不裁切鼠鼠表情' {
        for ($stage = 1; $stage -le 4; $stage++) {
            $name = "ImgStage$stage"
            $script:Win.FindName($name).Stretch.ToString() | Should -Be 'Uniform'
            Test-Path (Join-Path $script:GuiRoot $script:ImgMap[$name]) | Should -BeTrue
        }
    }

    It 'results 状态恢复原设计的大标题动态计数和双操作层级' {
        foreach ($name in @('ComicRail','ResultStatusText','ResultHeadlinePrefix','ResultHeadlineCount','ResultHeadlineSuffix','BtnSkipReview','ResultsEvidenceExpander','ResultEvidenceText')) {
            $script:Win.FindName($name) | Should -Not -BeNullOrEmpty
        }
        Set-GuiResultSummary -Executable 2 -Observation 4 -Evidence @('ExactService', 'Lenovo observation')
        $script:Win.FindName('ResultHeadlineCount').Text | Should -Be '6'
        $script:Win.FindName('ResultHeadlineCount').FontSize | Should -BeGreaterOrEqual 44
        $script:Win.FindName('ResultHeadlinePrefix').FontSize | Should -BeGreaterOrEqual 34
        $script:Win.FindName('BtnOpenReview').MinWidth | Should -BeGreaterOrEqual 240
        $script:Win.FindName('BtnSkipReview').MinWidth | Should -BeGreaterOrEqual 200
        $script:Win.FindName('ResultsEvidenceExpander').IsExpanded | Should -BeFalse
        $script:Win.FindName('ResultEvidenceText').Text | Should -Match 'ExactService'
    }

    It '零命中结果明确显示未发现而不是发现问题或抓到 0 个' {
        Set-GuiResultSummary -Executable 0 -Observation 0 -Evidence @()

        $script:Win.FindName('ResultStatusText').Text | Should -Match '未发现'
        $script:Win.FindName('ResultHeadlinePrefix').Text | Should -Match '没有抓到'
        $script:Win.FindName('ResultHeadlineCount').Text | Should -Be ''
        $script:Win.FindName('ResultHeadlineSuffix').Text | Should -Be ''

        Set-GuiResultSummary -Executable 1 -Observation 0 -Evidence @('ExactService')
        $script:Win.FindName('ResultStatusText').Text | Should -Match '发现'
        $script:Win.FindName('ResultHeadlineCount').Text | Should -Be '1'
        $script:Win.FindName('ResultHeadlineSuffix').Text | Should -Not -BeNullOrEmpty
    }

    It '这次先不处理会安全返回起点且不保留 reviewed 授权快照' {
        Set-GuiState -Name results -Force
        $script:ReviewedPendingSnapshot = [pscustomobject]@{ marker='stale' }
        $script:ReviewedPendingGenerationSha256 = 'stale'

        Dismiss-GuiResults

        $script:GuiState | Should -Be 'idle'
        $script:ReviewedPendingSnapshot | Should -BeNullOrEmpty
        $script:ReviewedPendingGenerationSha256 | Should -BeNullOrEmpty
    }

    It 'results 只显示原设计的完成提示而不重复通用状态标题' {
        Set-GuiState -Name results -Force
        $script:Win.FindName('StateHeader').Visibility.ToString() | Should -Be 'Collapsed'
        $script:Win.FindName('ResultStatusText').Visibility.ToString() | Should -Be 'Visible'

        Set-GuiState -Name review -Force
        $script:Win.FindName('StateHeader').Visibility.ToString() | Should -Be 'Visible'
    }

    It '语言切换 zh/en 更新标题' {
        $script:Lang = 'zh'; Apply-Language
        $script:Win.FindName('TitleMain').Text | Should -Be '鼠鼠cleaner'
        $script:Lang = 'en'; Apply-Language
        $script:Win.FindName('TitleMain').Text | Should -Be 'Shushu Cleaner'
        $script:Lang = 'zh'; Apply-Language
    }

    It '语言切换会重绘当前可见状态和主要控件但不改变状态' {
        Set-GuiState -Name review -Force
        $script:Lang = 'en'; Apply-Language
        $script:GuiState | Should -Be 'review'
        $script:Win.FindName('StateTitle').Text | Should -Match 'Review'
        $script:Win.FindName('BtnExecute').Content | Should -Be 'Process selected items'
        $script:Win.FindName('ReviewBoundaryText').Text | Should -Match 'observation'
        $script:Lang = 'zh'; Apply-Language
        $script:GuiState | Should -Be 'review'
        $script:Win.FindName('StateTitle').Text | Should -Match '确认'
        $script:Win.FindName('BtnExecute').Content | Should -Match '处理'
    }

    It '主要操作支持 Enter 且审核列表保持连续键盘导航' {
        foreach ($name in @('BtnStartScan','BtnOpenReview','BtnExecute','BtnRescan','BtnRetry')) {
            $script:Win.FindName($name).IsDefault | Should -BeTrue
        }
        [System.Windows.Input.KeyboardNavigation]::GetTabNavigation($script:Win.FindName('PendingList')).ToString() | Should -Be 'Continue'
    }

    It '关键图片操作结果和错误控件都有读屏名称' {
        foreach ($name in @('ImgStage1','ImgStage2','ImgStage3','ImgStage4','BtnStartScan','BtnOpenReview','BtnExecute','BtnRescan','BtnRetry','BtnRestore','BtnLang','ResultSummaryText','CompletedSummaryText','ErrorSummaryText')) {
            [System.Windows.Automation.AutomationProperties]::GetName($script:Win.FindName($name)) | Should -Not -BeNullOrEmpty
        }
    }

    It '状态主体支持纵向滚动且结果列表没有固定高度' {
        $scroll = $script:Win.FindName('StateBodyScroll')
        $scroll | Should -Not -BeNullOrEmpty
        $scroll.VerticalScrollBarVisibility.ToString() | Should -Be 'Auto'
        $scroll.HorizontalScrollBarVisibility.ToString() | Should -Be 'Disabled'
        [double]::IsNaN($script:Win.FindName('CompletedList').Height) | Should -BeTrue
    }

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

    It 'preflights missing <ControlName> without mutating UI or model' -TestCases @(
        @{ ControlName='IdlePanel' }, @{ ControlName='ScanningPanel' }, @{ ControlName='ResultsPanel' },
        @{ ControlName='ReviewPanel' }, @{ ControlName='ExecutingPanel' }, @{ ControlName='CompletedPanel' },
        @{ ControlName='ErrorPanel' }, @{ ControlName='StateHeader' }, @{ ControlName='StageCard1' }, @{ ControlName='StageCard2' },
        @{ ControlName='StageCard3' }, @{ ControlName='StageCard4' }, @{ ControlName='StateTitle' },
        @{ ControlName='StateSubtitle' }
    ) {
        param($ControlName)
        $script:Lang = 'zh'
        Set-GuiState -Name 'idle' -Force
        $before = Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8
        $realWindow = $window
        $window = New-GuiWindowProxy -RealWindow $realWindow -MissingName $ControlName
        try {
            { Set-GuiState -Name 'review' -Force } | Should -Throw '*GUI control missing*'
        } finally {
            $window = $realWindow
        }
        (Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8) | Should -Be $before
    }

    It 'rolls back UI and model when assigning <ControlName>.<PropertyName> fails' -TestCases @(
        @{ ControlName='ReviewPanel'; PropertyName='Visibility' }
        @{ ControlName='StageCard3'; PropertyName='BorderThickness' }
        @{ ControlName='StateTitle'; PropertyName='Text' }
        @{ ControlName='StateSubtitle'; PropertyName='Text' }
    ) {
        param($ControlName, $PropertyName)
        $script:Lang = 'zh'
        Set-GuiState -Name 'idle' -Force
        $before = Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8
        $realWindow = $window
        $failingControl = New-OneShotFailingControl -RealControl $realWindow.FindName($ControlName) -PropertyName $PropertyName
        $window = New-GuiWindowProxy -RealWindow $realWindow -ReplacementName $ControlName -Replacement $failingControl
        try {
            { Set-GuiState -Name 'review' -Force } | Should -Throw '*Injected assignment failure*'
        } finally {
            $window = $realWindow
        }
        (Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8) | Should -Be $before
    }

    It 'fails explicitly when localized state text is missing' {
        $savedLang = $script:Lang
        $saved = $script:I18N['en']['State_review_Title']
        $script:Lang = 'en'
        $script:I18N['en'].Remove('State_review_Title')
        try {
            { Get-Text 'State_review_Title' } | Should -Throw '*Missing localized text*'
        } finally {
            $script:I18N['en']['State_review_Title'] = $saved
            $script:Lang = $savedLang
        }
    }

    It 'preflights missing localized <Key> without mutating UI or model' -TestCases @(
        @{ Key='State_review_Title' }
        @{ Key='State_review_Sub' }
    ) {
        param($Key)
        $script:Lang = 'zh'
        Set-GuiState -Name 'idle' -Force
        $before = Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8
        $saved = $script:I18N['zh'][$Key]
        $script:I18N['zh'].Remove($Key)
        try {
            { Set-GuiState -Name 'review' -Force } | Should -Throw '*Missing localized text*'
        } finally {
            $script:I18N['zh'][$Key] = $saved
        }
        (Get-GuiRenderSnapshot | ConvertTo-Json -Compress -Depth 8) | Should -Be $before
    }

    It 'renders <Name> truthfully in <Lang>' -TestCases @(
        @{ Name='idle'; Lang='zh'; Panel='IdlePanel'; Stage=1; Title='鼠鼠开始幻想'; Subtitle='先做只读扫描，不会修改系统。' }
        @{ Name='scanning'; Lang='zh'; Panel='ScanningPanel'; Stage=2; Title='正在看清现实'; Subtitle='只展示真实阶段，不伪造完成百分比。' }
        @{ Name='results'; Lang='zh'; Panel='ResultsPanel'; Stage=3; Title='扫描结论'; Subtitle='可处理项与观察项分开显示，目前尚未修改系统。' }
        @{ Name='review'; Lang='zh'; Panel='ReviewPanel'; Stage=3; Title='确认处理边界'; Subtitle='只有安全、已测试且窄匹配命中的项目可以选择。' }
        @{ Name='executing'; Lang='zh'; Panel='ExecutingPanel'; Stage=3; Title='鼠鼠正在谨慎整理'; Subtitle='每项都会重新验证、备份并记录结果。' }
        @{ Name='completed'; Lang='zh'; Panel='CompletedPanel'; Stage=4; Title='幻想落地'; Subtitle='结果按成功、失败和跳过逐项展示。' }
        @{ Name='error'; Lang='zh'; Panel='ErrorPanel'; Stage=1; Title='鼠鼠的幻想被打断了'; Subtitle='查看真实原因后可以安全重试。' }
        @{ Name='idle'; Lang='en'; Panel='IdlePanel'; Stage=1; Title='The fantasy begins'; Subtitle='Start with a read-only scan. No system settings will change.' }
        @{ Name='scanning'; Lang='en'; Panel='ScanningPanel'; Stage=2; Title='Looking at reality'; Subtitle='Showing real scan phases without a fabricated percentage.' }
        @{ Name='results'; Lang='en'; Panel='ResultsPanel'; Stage=3; Title='Scan result'; Subtitle='Safe actions and observations are separated. Nothing has changed yet.' }
        @{ Name='review'; Lang='en'; Panel='ReviewPanel'; Stage=3; Title='Review the safety boundary'; Subtitle='Only tested items produced by narrow matches can be selected.' }
        @{ Name='executing'; Lang='en'; Panel='ExecutingPanel'; Stage=3; Title='Cleaning carefully'; Subtitle='Every item is revalidated, backed up, and recorded.' }
        @{ Name='completed'; Lang='en'; Panel='CompletedPanel'; Stage=4; Title='Fantasy delivered'; Subtitle='Success, failure, and skipped results are shown item by item.' }
        @{ Name='error'; Lang='en'; Panel='ErrorPanel'; Stage=1; Title='The fantasy was interrupted'; Subtitle='Read the real cause, then retry safely.' }
    ) {
        param($Name, $Lang, $Panel, $Stage, $Title, $Subtitle)
        $script:Lang = $Lang
        Set-GuiState -Name 'idle' -Force
        Set-GuiState -Name $Name -Force

        $visiblePanels = @($script:StatePanels | Where-Object { $script:Win.FindName($_).Visibility.ToString() -eq 'Visible' })
        $visiblePanels.Count | Should -Be 1
        $visiblePanels[0] | Should -Be $Panel
        $script:GuiActiveStage | Should -Be $Stage
        for ($index = 1; $index -le 4; $index++) {
            $card = $script:Win.FindName("StageCard$index")
            $card.Opacity | Should -Be $(if ($index -le $Stage) { 1.0 } else { 0.46 })
            $card.BorderThickness.Left | Should -Be $(if ($index -eq $Stage) { 3 } else { 1 })
            $card.BorderBrush.ToString() | Should -Be $(if ($index -eq $Stage) { '#FFFFD21F' } else { '#FFD8CBAA' })
        }
        $script:Win.FindName('StateTitle').Text | Should -Be $Title
        $script:Win.FindName('StateSubtitle').Text | Should -Be $Subtitle
    }

    It 'preserves stage <Stage> when entering error from <Previous>' -TestCases @(
        @{ Previous='review'; Stage=3 }
        @{ Previous='completed'; Stage=4 }
    ) {
        param($Previous, $Stage)
        $script:Lang = 'zh'
        Set-GuiState -Name $Previous -Force
        Set-GuiState -Name 'error'
        $script:GuiActiveStage | Should -Be $Stage
        $script:Win.FindName("StageCard$Stage").BorderThickness.Left | Should -Be 3
        $script:Win.FindName('ErrorPanel').Visibility.ToString() | Should -Be 'Visible'
    }

    It 'starts a direct streaming scan job without fake numeric progress' {
        $source = Get-Content (Join-Path $script:GuiRoot 'gui-cleaner.ps1') -Raw -Encoding UTF8
        $source | Should -Match 'function Start-GuiScan'
        $source | Should -Match '& powershell\.exe -NoProfile -ExecutionPolicy Bypass -File \$scriptPath -Mode scan 2>&1'
        $source | Should -Match '\$script:ScanTranscript'
        $source | Should -Match '\$script:ScanJob = Start-Job'
        $source | Should -Match 'Invoke-GuiScanPoll -job \$script:ScanJob'
        $source | Should -Not -Match 'Get-Random'
        $source | Should -Not -Match 'Value\s*\+='
        $source | Should -Not -Match 'cmd\s+/c'
    }

    It 'native scanner exit 7 fails the job, enters error, and never loads stale pending' {
        if ($null -eq $script:ScanJobScript) {
            $script:ScanJobScript | Should -Not -BeNullOrEmpty
            return
        }
        $childScript = Join-Path $env:TEMP ('shushu_scan_exit_' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($childScript, "Write-Output 'child-output'`r`nexit 7", [System.Text.UTF8Encoding]::new($true))
        $job = $null
        try {
            $job = Start-Job -ScriptBlock $script:ScanJobScript -ArgumentList $childScript
            Wait-Job $job | Out-Null
            $job.State | Should -Be 'Failed'
            Mock Get-PendingViewItems { throw 'stale pending must not be loaded' }
            Set-GuiState scanning -Force
            $script:ScanTranscript = ''
            Complete-ScanPoll -job $job -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
            $script:GuiState | Should -Be 'error'
            $script:Win.FindName('ErrorDetailText').Text | Should -Match 'child-output'
            Should -Invoke Get-PendingViewItems -Times 0 -Exactly
        } finally {
            if ($job -and (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
        }
    }

    It 'job creation failure leaves no stranded scanning state' {
        Mock Start-Job { throw 'job creation failed' }
        Mock Invoke-GuiBackgroundJobStop {}
        Mock Invoke-GuiBackgroundJobRemoval {}
        Set-GuiState idle -Force
        Start-GuiScan | Should -BeFalse
        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('BtnStartScan').IsEnabled | Should -BeTrue
        $script:Win.FindName('ScanProgress').IsIndeterminate | Should -BeFalse
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '未修改'
        Should -Invoke Invoke-GuiBackgroundJobStop -Times 0 -Exactly
        Should -Invoke Invoke-GuiBackgroundJobRemoval -Times 0 -Exactly
    }

    It 'initial scanning render failure rolls back then enters recoverable error' {
        $realWindow = $window
        Set-GuiState idle -Force
        $failingScanningPanel = New-OneShotFailingControl -RealControl $realWindow.FindName('ScanningPanel') -PropertyName Visibility
        $window = New-GuiWindowProxy -RealWindow $realWindow -ReplacementName 'ScanningPanel' -Replacement $failingScanningPanel
        Mock Start-Job { throw 'job must not start' }
        try {
            Start-GuiScan | Should -BeFalse
            $script:GuiState | Should -Be 'error'
            $realWindow.FindName('BtnStartScan').IsEnabled | Should -BeTrue
            $realWindow.FindName('ScanProgress').IsIndeterminate | Should -BeFalse
            Should -Invoke Start-Job -Times 0 -Exactly
        } finally {
            $window = $realWindow
        }
    }

    It 'second timer creation failure stops the first timer and removes the running job' {
        $fakeJob = [pscustomobject]@{ State='Running' }
        $firstTimer = New-FakeTimer
        $script:GuiTimerFactoryCalls = 0
        Mock Start-Job { $fakeJob }
        Mock New-Object {
            $script:GuiTimerFactoryCalls++
            if ($script:GuiTimerFactoryCalls -eq 1) { return $firstTimer }
            throw 'timer creation failed'
        } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }
        Mock Invoke-GuiBackgroundJobStop {}
        Mock Invoke-GuiBackgroundJobRemoval {}
        Set-GuiState idle -Force
        Start-GuiScan | Should -BeFalse
        $firstTimer.Stopped | Should -BeTrue
        Should -Invoke Invoke-GuiBackgroundJobStop -Times 1 -Exactly
        Should -Invoke Invoke-GuiBackgroundJobRemoval -Times 1 -Exactly
        $script:GuiState | Should -Be 'error'
    }

    It 'output drain failure is not suppressed' {
        Mock Read-GuiBackgroundJob { throw 'drain failed' }
        { Receive-GuiScanOutput ([pscustomobject]@{State='Running'}) } | Should -Throw '*drain failed*'
    }

    It 'poll drain failure stops resources and enters recoverable error' {
        $job = [pscustomobject]@{ State='Running' }
        $checkTimer = New-FakeTimer
        $scanTimer = New-FakeTimer
        Mock Read-GuiBackgroundJob { throw 'drain failed' }
        Mock Invoke-GuiBackgroundJobStop {}
        Mock Invoke-GuiBackgroundJobRemoval {}
        Set-GuiState scanning -Force
        Invoke-GuiScanPoll -job $job -checkTimer $checkTimer -scanTimer $scanTimer | Should -BeTrue
        $checkTimer.Stopped | Should -BeTrue
        $scanTimer.Stopped | Should -BeTrue
        Should -Invoke Invoke-GuiBackgroundJobStop -Times 1 -Exactly
        Should -Invoke Invoke-GuiBackgroundJobRemoval -Times 1 -Exactly
        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorDetailText').Text | Should -Match 'drain failed'
    }

    It 'pending load failure cleans up and enters recoverable error' {
        Mock Read-GuiBackgroundJob { 'scan complete' }
        Mock Invoke-GuiBackgroundJobRemoval {}
        Mock Read-GuiPendingFile { [pscustomobject]@{actions=@(); observations=@()} }
        Mock Get-PendingViewItems { throw 'pending parse failed' }
        $checkTimer = New-FakeTimer
        $scanTimer = New-FakeTimer
        Set-GuiState scanning -Force
        Complete-ScanPoll -job ([pscustomobject]@{State='Completed'}) -checkTimer $checkTimer -scanTimer $scanTimer | Should -BeTrue
        $checkTimer.Stopped | Should -BeTrue
        $scanTimer.Stopped | Should -BeTrue
        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('BtnStartScan').IsEnabled | Should -BeTrue
        $script:Win.FindName('ScanProgress').IsIndeterminate | Should -BeFalse
        $script:Win.FindName('ErrorDetailText').Text | Should -Match 'pending parse failed'
    }

    It 'results rendering failure rolls back then enters recoverable error' {
        Mock Read-GuiBackgroundJob { 'scan complete' }
        Mock Invoke-GuiBackgroundJobRemoval {}
        Mock Read-GuiPendingFile { [pscustomobject]@{actions=@(); observations=@()} }
        Mock Get-PendingViewItems { @() }
        $realWindow = $window
        $failingSummary = New-OneShotFailingControl -RealControl $realWindow.FindName('ResultSummaryText') -PropertyName Text
        $window = New-GuiWindowProxy -RealWindow $realWindow -ReplacementName 'ResultSummaryText' -Replacement $failingSummary
        try {
            Set-GuiState scanning -Force
            Complete-ScanPoll -job ([pscustomobject]@{State='Completed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
            $script:GuiState | Should -Be 'error'
            $realWindow.FindName('ErrorDetailText').Text | Should -Match 'Injected assignment failure'
        } finally {
            $window = $realWindow
        }
    }

    It 'empty output poll leaves the visible transcript unchanged' {
        $script:ScanTranscript = 'existing output'
        $script:Win.FindName('ScanOutput').Text = 'visible sentinel'
        Add-GuiScanOutput -Lines @()
        $script:Win.FindName('ScanOutput').Text | Should -Be 'visible sentinel'
    }

    It 'localizes streamed phase text in English' {
        $oldLang = $script:Lang
        try {
            $script:Lang = 'en'
            $script:ScanTranscript = ''
            Add-GuiScanOutput -Lines @('==> 检查系统服务...')
            $script:Win.FindName('ScanPhaseText').Text | Should -Be 'Checking system services'
        } finally {
            $script:Lang = $oldLang
        }
    }

    It '语言切换会重绘已经显示的扫描阶段文案' {
        $script:Lang = 'zh'
        Set-GuiState scanning -Force
        Add-GuiScanOutput -Lines @('==> 检查系统服务...')
        $script:Win.FindName('ScanPhaseText').Text | Should -Be '检查系统服务'
        $script:Lang = 'en'; Apply-Language
        $script:Win.FindName('ScanPhaseText').Text | Should -Be 'Checking system services'
        $script:Lang = 'zh'; Apply-Language
    }

    It 'localizes completed result counts in English' {
        $oldLang = $script:Lang
        try {
            $script:Lang = 'en'
            Mock Read-GuiBackgroundJob { 'scan complete' }
            Mock Invoke-GuiBackgroundJobRemoval {}
            Mock Read-GuiPendingFile { [pscustomobject]@{actions=@(); observations=@()} }
            Mock Get-PendingViewItems {
                @([pscustomobject]@{CanExecute=$true},[pscustomobject]@{CanExecute=$false})
            }
            Set-GuiState scanning -Force
            Complete-ScanPoll -job ([pscustomobject]@{State='Completed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
            $script:Win.FindName('ResultSummaryText').Text | Should -Be '1 safe item(s), 1 observation(s)'
        } finally {
            $script:Lang = $oldLang
        }
    }

    It 'localizes scan failure and no-mutation wording in English' {
        $oldLang = $script:Lang
        try {
            $script:Lang = 'en'
            Mock Read-GuiBackgroundJob { 'scanner failed' }
            Mock Invoke-GuiBackgroundJobRemoval {}
            Set-GuiState scanning -Force
            Complete-ScanPoll -job ([pscustomobject]@{State='Failed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
            $script:Win.FindName('ErrorSummaryText').Text | Should -Be 'Scan failed: Failed'
            $script:Win.FindName('ErrorMutationText').Text | Should -Be 'The scan did not change any system settings.'
        } finally {
            $script:Lang = $oldLang
        }
    }

    It 'bounds the retained scan transcript' {
        $script:ScanTranscript = ''
        Add-GuiScanOutput -Lines @(('x' * 70000))
        $script:ScanTranscript.Length | Should -BeLessOrEqual 65536
        $script:Win.FindName('ScanOutput').Text.Length | Should -BeLessOrEqual 65536
    }

    It 'wires start, retry, and review navigation to shared functions' {
        $source = Get-Content (Join-Path $script:GuiRoot 'gui-cleaner.ps1') -Raw -Encoding UTF8
        $source | Should -Match "BtnStartScan'\)\.Add_Click\(\{\s*Start-GuiScan\s*\}\)"
        $source | Should -Match "BtnRetry'\)\.Add_Click\(\{\s*Start-GuiScan\s*\}\)"
        $source | Should -Match "BtnOpenReview'\)\.Add_Click"
        $source | Should -Match 'Get-PendingViewItems'
        $source | Should -Match 'Set-GuiState review'
    }

    It 'completed scan stops timers, loads result counts, and enters results' {
        Mock Read-GuiBackgroundJob { 'scan complete' }
        Mock Invoke-GuiBackgroundJobRemoval {}
        Mock Read-GuiPendingFile { [pscustomobject]@{actions=@(); observations=@()} }
        Mock Get-PendingViewItems {
            @([pscustomobject]@{CanExecute=$true},[pscustomobject]@{CanExecute=$false})
        }
        Set-GuiState scanning -Force
        $checkTimer = New-FakeTimer
        $scanTimer = New-FakeTimer
        $done = Complete-ScanPoll -job ([pscustomobject]@{State='Completed'}) -checkTimer $checkTimer -scanTimer $scanTimer
        $done | Should -BeTrue
        $checkTimer.Stopped | Should -BeTrue
        $scanTimer.Stopped | Should -BeTrue
        $script:GuiState | Should -Be 'results'
        $script:Win.FindName('ScanProgress').IsIndeterminate | Should -BeFalse
        $script:Win.FindName('ResultSummaryText').Text | Should -Match '1'
    }

    It 'failed scan enters error and states that no mutation occurred' {
        Mock Read-GuiBackgroundJob { 'scanner failed' }
        Mock Invoke-GuiBackgroundJobRemoval {}
        Set-GuiState scanning -Force
        Complete-ScanPoll -job ([pscustomobject]@{State='Failed'}) -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '未修改'
    }

    It '失败扫描把 JobStateInfo.Reason 原样附加到技术详情' {
        $reason = [System.InvalidOperationException]::new('injected scan job reason')
        $job = [pscustomobject]@{ State='Failed'; JobStateInfo=[pscustomobject]@{ Reason=$reason } }
        Mock Read-GuiBackgroundJob { @('partial transcript') }
        Mock Invoke-GuiBackgroundJobRemoval {}
        Complete-ScanPoll -job $job -checkTimer (New-FakeTimer) -scanTimer (New-FakeTimer) | Should -BeTrue
        $script:Win.FindName('ErrorDetailText').Text | Should -Match 'partial transcript'
        $script:Win.FindName('ErrorDetailText').Text | Should -Match 'injected scan job reason'
    }

    It 'stopped scan enters error and stops both timers' {
        Mock Read-GuiBackgroundJob { 'scanner stopped' }
        Mock Invoke-GuiBackgroundJobRemoval {}
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        Set-GuiState scanning -Force
        $done = Complete-ScanPoll -job ([pscustomobject]@{State='Stopped'}) -checkTimer $t1 -scanTimer $t2
        $done | Should -BeTrue
        $t1.Stopped | Should -BeTrue
        $t2.Stopped | Should -BeTrue
        $script:GuiState | Should -Be 'error'
    }

    It 'running scan remains scanning and leaves timers active' {
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        Set-GuiState scanning -Force
        $done = Complete-ScanPoll -job ([pscustomobject]@{State='Running'}) -checkTimer $t1 -scanTimer $t2
        $done | Should -BeFalse
        $script:GuiState | Should -Be 'scanning'
        $t1.Stopped | Should -BeFalse
        $t2.Stopped | Should -BeFalse
    }

    It 'clean 结果统计 success/failed/skipped/manual' {
        $tmpRoot = Join-Path $env:TEMP ("gui_sum_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $payload = [pscustomobject]@{
            generated = '2026-01-01 00:00:00'
            actions = @(
                [pscustomobject]@{ id='a'; status='success' },
                [pscustomobject]@{ id='b'; status='failed' },
                [pscustomobject]@{ id='c'; status='skipped' },
                [pscustomobject]@{ id='d'; status='manual_required' }
            )
            suspicious = @()
        }
        $payload | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try { $sum = Get-CleanResultSummary } finally { $script:Root = $oldRoot }
        $sum.success | Should -Be 1
        $sum.failed | Should -Be 1
        $sum.skipped | Should -Be 1
        $sum.manual_required | Should -Be 1
        $sum.pending | Should -Be 0
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }
}

Describe '勾选视图 (v1.5.5)' {
    BeforeAll {
        $env:SHUSHU_CLEANER_TEST = '1'
        $script:GuiRoot = Split-Path $PSScriptRoot -Parent
        . (Join-Path $script:GuiRoot 'gui-cleaner.ps1')
        $script:Win = $window

        function New-GuiReviewPendingFixture {
            param(
                [string]$Marker = 'fixture',
                [string]$ActionMatchedType = 'contains',
                [string]$ObservationMatchedType = 'exact',
                [string]$ActionServiceName = 'ActionService'
            )
            return [pscustomobject]@{
                pending_schema_version = [int64]2
                review_marker = $Marker
                actions = @([pscustomobject]@{
                    id='action-row'; name_cn='可执行分支'; hit_type='service'; action='disable_service'; status='pending'
                    service_name=$ActionServiceName; matched_pattern='Action'; matched_type=$ActionMatchedType; matched_field='service_name'; reason_cn='action reason'
                })
                observations = @([pscustomobject]@{
                    id='observation-row'; name_cn='观察分支'; hit_type='service'; action='investigate'; status='观察'
                    service_name='ObservationService'; matched_pattern='ObservationService'; matched_type=$ObservationMatchedType; matched_field='service_name'; reason_cn='observation reason'; obs_reason='只观察'
                })
                suspicious = @()
            }
        }

        function Invoke-GuiOpenReviewClick {
            $script:Win.FindName('BtnOpenReview').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
        }

        function Set-GuiReviewedExecutionFixture {
            param([string]$ActionServiceName = 'ActionService')
            Set-GuiState review -Force
            $pending = New-GuiReviewPendingFixture -ActionServiceName $ActionServiceName
            $script:ReviewedPendingSnapshot = $pending
            $keys = [System.Collections.Generic.List[string]]::new()
            foreach ($key in @(Get-GuiValidatedActionIdentityKeys -Pending $pending)) { $keys.Add($key) }
            $script:ReviewedActionIdentityKeys = $keys.AsReadOnly()
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = $null
            $list.Items.Clear()
            foreach ($item in @(Get-PendingViewItems -Pending $pending)) { [void]$list.Items.Add($item) }
            return [pscustomobject]@{ Pending=$pending; List=$list }
        }

        function New-ExecutionFakeTimer {
            $timer = [pscustomobject]@{ Stopped=$false; Started=$false; TickHandler=$null; Interval=$null }
            $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true }
            $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Started = $true }
            $timer | Add-Member -MemberType ScriptMethod -Name Add_Tick -Value { param($handler); $this.TickHandler = $handler }
            return $timer
        }

        function Set-GuiReviewedGenerationFromFile {
            param([Parameter(Mandatory=$true)][string]$Path)
            $script:ReviewedPendingGenerationSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }

        function Merge-GuiPendingStatusFromFile {
            param([Parameter(Mandatory=$true)][string]$Path)
            $pending = Read-GuiPendingFile -Path $Path
            $script:ExecutionActions = @($pending.actions)
            $pairs = [System.Collections.Generic.List[System.Tuple[string,string]]]::new()
            foreach ($action in @($pending.actions)) {
                $pairs.Add([System.Tuple[string,string]]::new((Get-PendingIdentityKey $action), [string]$action.status))
            }
            $result = [pscustomobject]@{ Items=$pairs.AsReadOnly() }
            Merge-PendingStatus $result
        }
    }

    AfterEach {
        if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) {
            Remove-Item -LiteralPath $script:ExecutionTempPath -Force -ErrorAction SilentlyContinue
        }
        $script:ExecutionProcess = $null
        $script:ExecutionTimer = $null
        $script:ExecutionTempPath = $null
        $script:ExecutionActions = @()
        $script:ExecutionInProgress = $false
        $script:ExecutionLifecycle = 'idle'
        $script:ExecutionUnknownProbeCount = 0
    }

    It '动作中文标签映射' {
        Get-ActionLabel 'disable_service'  | Should -Be '禁用服务'
        Get-ActionLabel 'remove_autostart' | Should -Be '删除自启'
        Get-ActionLabel 'disable_task'     | Should -Be '禁用任务'
        Get-ActionLabel 'uninstall'        | Should -Be '手动卸载'
        Get-ActionLabel 'investigate'      | Should -Be '仅观察'
        Get-ActionLabel 'none'             | Should -Be '不处理'
    }

    It '勾选视图: actions 可勾选 / observations disabled (v1.5.6 数据模型)' {
        $tmpRoot = Join-Path $env:TEMP ("gui_view_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $profiles = [pscustomobject]@{
            schema_version = 2
            profiles = @(
                [pscustomobject]@{ id='t1'; vendor='T'; name_cn='测试高风险'; risk='high'; safe=$true; reason_cn='r1'
                    detect=[pscustomobject]@{ services=@('S1'); processes=@(); autostarts=@(); tasks=@() }
                    actions=[pscustomobject]@{ service='disable_service' }
                    evidence=[pscustomobject]@{ tested=$true; tested_count=1; tested_models=@('X'); last_verified='2026-01-01' } },
                [pscustomobject]@{ id='t2'; vendor='T'; name_cn='测试未实测'; risk='medium'; safe=$true; reason_cn='r2'
                    detect=[pscustomobject]@{ services=@('S2'); processes=@(); autostarts=@(); tasks=@() }
                    actions=[pscustomobject]@{ service='investigate' }
                    evidence=[pscustomobject]@{ tested=$false; tested_count=0; tested_models=@(); last_verified=$null } }
            )
            keep_notes_cn = @()
        }
        $profiles | ConvertTo-Json -Depth 6 | Out-File (Join-Path $tmpRoot 'bloatware-profiles.json') -Encoding utf8
        $pending = [pscustomobject]@{
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='t1'; vendor='T'; name_cn='测试高风险'; action='disable_service'; hit_type='service'; detail=''; reason_cn='r1'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; status='pending' },
                [pscustomobject]@{ id='t3'; vendor='T'; name_cn='已完成项'; action='disable_service'; hit_type='service'; detail=''; reason_cn='r3'; service_name='S3'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; status='success' }
            )
            observations = @(
                [pscustomobject]@{ id='t2'; vendor='T'; name_cn='测试未实测'; action='investigate'; hit_type='service'; detail=''; reason_cn='r2'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true; obs_reason='未实测 (tested=false), 仅观察' }
            )
            suspicious = @()
        }
        $pending | ConvertTo-Json -Depth 6 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try { $view = @(Get-PendingViewItems -Pending $pending) } finally { $script:Root = $oldRoot }

        # t3 success 被过滤; 剩下 t1 (actions) + t2 (observations)
        $view.Count | Should -Be 2
        $v1 = $view | Where-Object { $_.name_cn -eq '测试高风险' }
        $v2 = $view | Where-Object { $_.name_cn -eq '测试未实测' }
        # actions: 可执行 → 默认勾选 + CanExecute=true, 标签正确
        $v1.IsChecked | Should -Be $true
        $v1.CanExecute | Should -Be $true
        $v1.risk_label | Should -Be '高风险'
        $v1.evidence_label | Should -Be '实测 1 台'
        $v1.action_label | Should -Be '禁用服务'
        $v1.restorable_label | Should -Be '可恢复'
        # observations: 仅观察 → checkbox disabled (CanExecute=false), 默认不勾选
        $v2.IsChecked | Should -Be $false
        $v2.CanExecute | Should -Be $false
        $v2.risk_label | Should -Be '中风险'
        $v2.evidence_label | Should -Be '未实测'
        $v2.action_label | Should -Be '仅观察'
        $v2.status | Should -Be '观察'
        $v2.restorable_label | Should -Be '不可自动'
        $v2.reason_cn | Should -Match '未实测'

        [System.IO.Directory]::Delete($tmpRoot, $true)
    }

    It '混合 matcher 按 pending v2 provenance 展示且观察项保持不可执行' {
        $tmpRoot = Join-Path $TestDrive ('gui-mixed-view-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pending = [pscustomobject]@{
            pending_schema_version = [int64]2
            actions = @([pscustomobject]@{
                id='mixed'; name_cn='精确服务'; hit_type='service'; action='disable_service'; status='pending'
                service_name='ExactService'; matched_pattern='ExactService'; matched_type='exact'; matched_field='service_name'; reason_cn='narrow'
            })
            observations = @([pscustomobject]@{
                id='mixed'; name_cn='联想观察项'; hit_type='service'; action='investigate'; status='观察'
                service_name='LenovoOtherService'; matched_pattern='Lenovo'; matched_type='contains'; matched_field='service_name'; obs_reason='宽匹配，只观察'
            })
            suspicious = @()
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            (ConvertTo-Json -InputObject $pending -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            $items = @(Get-PendingViewItems -Pending $pending)
            $items.Count | Should -Be 2
            $items[0].CanExecute | Should -BeTrue
            $items[0].IsChecked | Should -BeTrue
            $items[0].matcher_detail | Should -Match 'exact'
            $items[1].CanExecute | Should -BeFalse
            $items[1].IsChecked | Should -BeFalse
            $items[1].matcher_detail | Should -Match 'contains'

            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = $items
            Set-AllChecked $list $true
            @($list.Items | Where-Object { -not $_.CanExecute -and $_.IsChecked }).Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'actions 中 contains 仍可执行而 observations 中 exact 仍不可执行' {
        $pending = New-GuiReviewPendingFixture

        $items = @(Get-PendingViewItems -Pending $pending)

        $items.Count | Should -Be 2
        $items[0].matched_type | Should -Be 'contains'
        $items[0].CanExecute | Should -BeTrue
        $items[0].IsChecked | Should -BeTrue
        $items[1].matched_type | Should -Be 'exact'
        $items[1].CanExecute | Should -BeFalse
        $items[1].IsChecked | Should -BeFalse
    }

    It 'Get-PendingViewItems 强制要求显式 validated Pending object' {
        { Get-PendingViewItems } | Should -Throw '*Pending*'
    }

    It 'action status 只接受大小写精确的 truthful known set' {
        foreach ($status in @('PENDING','unknown')) {
            $pending = New-GuiReviewPendingFixture
            $pending.actions[0].status = $status
            { Assert-GuiPendingPresentationShape -Pending $pending } |
                Should -Throw '*pending review shape*status*'
        }

        foreach ($status in @('pending','failed','success','skipped','manual_required')) {
            $pending = New-GuiReviewPendingFixture
            $pending.actions[0].status = $status
            { Assert-GuiPendingPresentationShape -Pending $pending } | Should -Not -Throw
        }
    }

    It 'projection 仅大小写精确选择 pending 和 failed actions' {
        $pending = New-GuiReviewPendingFixture
        $base = $pending.actions[0]
        $pending.actions = @()
        foreach ($status in @('pending','failed','success','skipped','manual_required','PENDING')) {
            $row = $base.PSObject.Copy()
            $row.id = "action-$status"
            $row.service_name = "Service-$status"
            $row.status = $status
            $pending.actions += $row
        }

        $items = @(Get-PendingViewItems -Pending $pending)
        $actionItems = @($items | Where-Object CanExecute)

        @($actionItems.status) | Should -Be @('pending','failed')
    }

    It 'review presentation shape 拒绝 null、数组标量和缺失 concrete identity' {
        $cases = @(
            @{ Label='actions container null'; Mutate={ param($p) $p.actions = $null } },
            @{ Label='observations container null'; Mutate={ param($p) $p.observations = $null } },
            @{ Label='action id null'; Mutate={ param($p) $p.actions[0].id = $null } },
            @{ Label='action hit_type array'; Mutate={ param($p) $p.actions[0].hit_type = @('service') } },
            @{ Label='action action array'; Mutate={ param($p) $p.actions[0].action = @('disable_service') } },
            @{ Label='action status null'; Mutate={ param($p) $p.actions[0].status = $null } },
            @{ Label='action pattern array'; Mutate={ param($p) $p.actions[0].matched_pattern = @('Action') } },
            @{ Label='action type null'; Mutate={ param($p) $p.actions[0].matched_type = $null } },
            @{ Label='action field array'; Mutate={ param($p) $p.actions[0].matched_field = @('service_name') } },
            @{ Label='action target null'; Mutate={ param($p) $p.actions[0].service_name = $null } },
            @{ Label='observation row null'; Mutate={ param($p) $p.observations = @($null) } },
            @{ Label='observation id array'; Mutate={ param($p) $p.observations[0].id = @('observation-row') } },
            @{ Label='observation reason null'; Mutate={ param($p) $p.observations[0].obs_reason = $null } }
        )

        foreach ($case in $cases) {
            $pending = New-GuiReviewPendingFixture
            & $case.Mutate $pending
            { Assert-GuiPendingPresentationShape -Pending $pending } |
                Should -Throw '*pending review shape*' -Because $case.Label
        }
    }

    It 'review 从同一文件字节快照投影并固化主 pending generation SHA-256' {
        $tmpRoot = Join-Path $TestDrive ('gui-one-read-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pendingPath = Join-Path $tmpRoot 'pending_actions.json'
        $firstJson = ConvertTo-Json -InputObject (New-GuiReviewPendingFixture -Marker 'first' -ActionServiceName 'FirstService') -Depth 6
        [System.IO.File]::WriteAllText($pendingPath, $firstJson, [System.Text.UTF8Encoding]::new($false))
        $expectedGeneration = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            $script:ReviewedPendingSnapshot.review_marker | Should -Be 'first'
            $script:ReviewedPendingGenerationSha256 | Should -BeExactly $expectedGeneration
            (,$script:ReviewedActionIdentityKeys) | Should -BeOfType ([System.Collections.ObjectModel.ReadOnlyCollection[string]])
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 1
            $script:Win.FindName('PendingList').Items[0]._raw.service_name | Should -Be 'FirstService'
        } finally {
            $script:Root = $oldRoot
        }
    }

    It '成功 review 会替换先前 snapshot 和 identity keys' {
        $tmpRoot = Join-Path $TestDrive ('gui-review-replace-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pendingPath = Join-Path $tmpRoot 'pending_actions.json'
        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            $first = New-GuiReviewPendingFixture -Marker 'first' -ActionServiceName 'FirstService'
            [System.IO.File]::WriteAllText($pendingPath, (ConvertTo-Json -InputObject $first -Depth 6), [System.Text.UTF8Encoding]::new($false))
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick
            $firstSnapshot = $script:ReviewedPendingSnapshot
            $firstKeys = @($script:ReviewedActionIdentityKeys)

            $second = New-GuiReviewPendingFixture -Marker 'second' -ActionServiceName 'SecondService'
            [System.IO.File]::WriteAllText($pendingPath, (ConvertTo-Json -InputObject $second -Depth 6), [System.Text.UTF8Encoding]::new($false))
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            [object]::ReferenceEquals($firstSnapshot, $script:ReviewedPendingSnapshot) | Should -BeFalse
            $script:ReviewedPendingSnapshot.review_marker | Should -Be 'second'
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 1
            $script:ReviewedActionIdentityKeys[0] | Should -Not -Be $firstKeys[0]
            $script:Win.FindName('PendingList').Items[0]._raw.service_name | Should -Be 'SecondService'
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'review allowlist 仅含 selectable action key 且 observation view 篡改不能提升权限' {
        $tmpRoot = Join-Path $TestDrive ('gui-action-allowlist-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pending = New-GuiReviewPendingFixture
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            (ConvertTo-Json -InputObject $pending -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            $list = $script:Win.FindName('PendingList')
            $selectedAction = @($list.Items | Where-Object { $_.CanExecute -and $_.IsChecked })[0]
            $observation = @($list.Items | Where-Object { -not $_.CanExecute })[0]
            $actionKey = Get-PendingIdentityKey $selectedAction._raw
            $observationKey = Get-PendingIdentityKey $observation._raw
            $allowlist = $script:ReviewedActionIdentityKeys

            (,$allowlist) | Should -BeOfType ([System.Collections.ObjectModel.ReadOnlyCollection[string]])
            $allowlist.Contains($actionKey) | Should -BeTrue
            $allowlist.Contains($observationKey) | Should -BeFalse
            $observation.CanExecute = $true
            $observation.IsChecked = $true
            $allowlist.Contains((Get-PendingIdentityKey $observation._raw)) | Should -BeFalse
            $genericList = [System.Collections.Generic.IList[string]]$allowlist
            $genericList.IsReadOnly | Should -BeTrue
            { $genericList.Add('promoted-observation') } | Should -Throw
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'duplicate action identities 使 review 失败并清空 stale state' {
        $tmpRoot = Join-Path $TestDrive ('gui-duplicate-action-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pending = New-GuiReviewPendingFixture
        $duplicate = $pending.actions[0].PSObject.Copy()
        $duplicate.status = 'failed'
        $pending.actions = @($pending.actions[0], $duplicate)
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            (ConvertTo-Json -InputObject $pending -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = @([pscustomobject]@{ name_cn='stale' })
            $script:ReviewedPendingSnapshot = [pscustomobject]@{ review_marker='stale' }
            $script:ReviewedActionIdentityKeys = @('stale-key')
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            $script:GuiState | Should -Be 'error'
            $script:Win.FindName('ErrorDetailText').Text | Should -Match 'duplicate action identity'
            $list.ItemsSource | Should -BeNullOrEmpty
            @($list.Items).Count | Should -Be 0
            $script:ReviewedPendingSnapshot | Should -BeNullOrEmpty
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'observation identity 与 action collision 使 review 在绑定前失败关闭' {
        $tmpRoot = Join-Path $TestDrive ('gui-cross-branch-collision-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pending = New-GuiReviewPendingFixture
        $collision = $pending.actions[0].PSObject.Copy()
        $collision.name_cn = '伪装观察分支'
        $collision.status = '观察'
        $collision | Add-Member -NotePropertyName obs_reason -NotePropertyValue '只观察'
        $pending.observations = @($collision)

        $projected = @(Get-PendingViewItems -Pending $pending)
        $projectedObservation = @($projected | Where-Object { -not $_.CanExecute })[0]
        $projectedObservation.CanExecute = $true
        $projectedObservation.IsChecked = $true
        (Get-PendingIdentityKey $projectedObservation._raw) |
            Should -Be (Get-PendingIdentityKey $pending.actions[0])

        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            (ConvertTo-Json -InputObject $pending -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $oldLang = $script:Lang
        $script:Root = $tmpRoot
        $script:Lang = 'zh'
        try {
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = $projected
            $script:ReviewedPendingSnapshot = [pscustomobject]@{ review_marker='stale' }
            $script:ReviewedActionIdentityKeys = @('stale-key')
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            $script:GuiState | Should -Be 'error'
            $script:Win.FindName('ErrorSummaryText').Text | Should -Be '待处理清单已过期，必须重新扫描。'
            $script:Win.FindName('ErrorMutationText').Text | Should -Be '没有执行任何系统修改。'
            $script:Win.FindName('ErrorDetailText').Text | Should -Match 'observation identity.*action identity'
            $list.ItemsSource | Should -BeNullOrEmpty
            @($list.Items).Count | Should -Be 0
            $script:ReviewedPendingSnapshot | Should -BeNullOrEmpty
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
            $script:Lang = $oldLang
        }
    }

    It 'malformed review 清空 stale list、snapshot 和 identity keys' {
        $tmpRoot = Join-Path $TestDrive ('gui-malformed-review-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $pending = New-GuiReviewPendingFixture
        $pending.actions[0].matched_pattern = @('Action')
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            (ConvertTo-Json -InputObject $pending -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try {
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = @([pscustomobject]@{ name_cn='stale' })
            $script:ReviewedPendingSnapshot = [pscustomobject]@{ review_marker='stale' }
            $script:ReviewedActionIdentityKeys = @('stale-key')
            Set-GuiState results -Force
            Invoke-GuiOpenReviewClick

            $script:GuiState | Should -Be 'error'
            $list.ItemsSource | Should -BeNullOrEmpty
            @($list.Items).Count | Should -Be 0
            $script:ReviewedPendingSnapshot | Should -BeNullOrEmpty
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'review 加载非 v2 pending 时按 <Lang> 本地化失败并清空 stale state' -TestCases @(
        @{ Lang='zh'; Summary='待处理清单已过期，必须重新扫描。'; Mutation='没有执行任何系统修改。' }
        @{ Lang='en'; Summary='The pending review is stale and must be rescanned.'; Mutation='No system settings were changed.' }
    ) {
        param($Lang, $Summary, $Mutation)
        $tmpRoot = Join-Path $TestDrive ('gui-stale-review-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpRoot 'pending_actions.json'),
            '{"pending_schema_version":1,"actions":[],"observations":[],"suspicious":[]}',
            [System.Text.UTF8Encoding]::new($false)
        )

        $oldRoot = $script:Root
        $oldLang = $script:Lang
        $script:Root = $tmpRoot
        try {
            $script:Lang = $Lang
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = @([pscustomobject]@{ name_cn='旧数据' })
            $script:ReviewedPendingSnapshot = [pscustomobject]@{ review_marker='stale' }
            $script:ReviewedActionIdentityKeys = @('stale-key')
            Set-GuiState results -Force

            Invoke-GuiOpenReviewClick

            $script:GuiState | Should -Be 'error'
            $script:Win.FindName('ErrorSummaryText').Text | Should -Be $Summary
            $script:Win.FindName('ErrorMutationText').Text | Should -Be $Mutation
            $script:Win.FindName('ErrorDetailText').Text | Should -Match '重新运行 scan'
            $list.ItemsSource | Should -BeNullOrEmpty
            @($list.Items).Count | Should -Be 0
            $script:ReviewedPendingSnapshot | Should -BeNullOrEmpty
            @($script:ReviewedActionIdentityKeys).Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
            $script:Lang = $oldLang
        }
    }

    It '全选跳过 CanExecute=false (观察项不被全选勾上, v1.5.6)' {
        $items = @(
            [pscustomobject]@{ CanExecute = $true;  IsChecked = $false },
            [pscustomobject]@{ CanExecute = $false; IsChecked = $false }
        )
        $list = [pscustomobject]@{ Items = $items }
        Set-AllChecked $list $true
        $items[0].IsChecked | Should -Be $true
        $items[1].IsChecked | Should -Be $false
        # 清空: 全部取消
        Set-AllChecked $list $false
        $items[0].IsChecked | Should -Be $false
    }

    It 'Get-CleanResultSummary 支持自定义路径 (-Path)' {
        $tmpRoot = Join-Path $env:TEMP ("gui_sum2_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $tmpFile = Join-Path $tmpRoot 'subset.json'
        $pending = [pscustomobject]@{
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='a'; status='success' },
                [pscustomobject]@{ id='b'; status='failed' }
            )
            suspicious = @()
        }
        $pending | ConvertTo-Json -Depth 5 | Out-File $tmpFile -Encoding utf8
        $sum = Get-CleanResultSummary -Path $tmpFile
        $sum.success | Should -Be 1
        $sum.failed | Should -Be 1
        $sum.pending | Should -Be 0
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }

    It '勾选子集保留完整 v2 action provenance 和进程身份' {
        $raw = [pscustomobject]@{
            id='process-v2'; vendor='T'; name_cn='Process'; action='uninstall'; hit_type='process'; detail='P1 PID=101'; reason_cn='r'
            service_name=''; service_display_name=''; autostart_source=''; autostart_name=''; autostart_value=''; task_name=''; task_path=''
            process_name='P1'; process_id=101; process_path='C:\Apps\P1.exe'; safe=$true; status='failed'
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path'; future_v2_property='preserve-me'
        }
        $checked = @([pscustomobject]@{ _raw=$raw })
        $source = [pscustomobject]@{ pending_schema_version=2; generated='scan'; actions=@($raw); observations=@([pscustomobject]@{ id='observe'; obs_reason='keep' }); suspicious=@([pscustomobject]@{ PID=9; Name='Other' }); safety_nonce='keep-envelope' }

        $payload = New-PendingSubsetPayload -Checked $checked -SourcePending $source

        $payload.pending_schema_version | Should -Be 2
        @($payload.actions).Count | Should -Be 1
        $action = $payload.actions[0]
        $action.status | Should -Be 'pending'
        $action.matched_pattern | Should -Be 'C:\Apps'
        $action.matched_type | Should -Be 'path'
        $action.matched_field | Should -Be 'process_path'
        $action.process_id | Should -Be 101
        $action.process_path | Should -Be 'C:\Apps\P1.exe'
        $action.future_v2_property | Should -Be 'preserve-me'
        $raw.status | Should -Be 'failed'
        @($payload.suspicious).Count | Should -Be 1
        @($payload.observations).Count | Should -Be 1
        $payload.observations[0].obs_reason | Should -Be 'keep'
        $payload.safety_nonce | Should -Be 'keep-envelope'
        $json = ConvertTo-Json -InputObject $payload -Depth 6
        $json | Should -Match '"actions"\s*:\s*\[\s*\{'
        $json | Should -Match '"observations"\s*:\s*\[\s*\{'
    }

    It '缺失 pending schema marker 时拒绝生成勾选子集并要求重新 scan' {
        $raw = [pscustomobject]@{ id='service-v2'; action='disable_service'; hit_type='service'; status='pending'; matched_pattern='S1'; matched_type='exact'; matched_field='service_name'; process_id=0; process_path='' }
        { New-PendingSubsetPayload -Checked @([pscustomobject]@{ _raw=$raw }) -SourcePending ([pscustomobject]@{ suspicious=@() }) } |
            Should -Throw '*重新运行 scan*'
    }

    It '缺失、旧版及非整数标量 pending schema 均失败关闭' {
        $raw = [pscustomobject]@{ id='service-v2'; action='disable_service'; hit_type='service'; status='pending' }
        $invalidSources = @(
            [pscustomobject]@{ suspicious=@() },
            [pscustomobject]@{ pending_schema_version=[int32]1; suspicious=@() },
            [pscustomobject]@{ pending_schema_version='2'; suspicious=@() },
            [pscustomobject]@{ pending_schema_version=@([int32]2); suspicious=@() },
            [pscustomobject]@{ pending_schema_version=[double]2.0; suspicious=@() }
        )

        foreach ($source in $invalidSources) {
            { New-PendingSubsetPayload -Checked @([pscustomobject]@{ _raw=$raw }) -SourcePending $source } |
                Should -Throw '*重新运行 scan*'
        }
    }

    It '合法 Int64 pending schema v2 原样保留' {
        $raw = [pscustomobject]@{ id='service-v2'; action='disable_service'; hit_type='service'; status='pending' }
        $payload = New-PendingSubsetPayload -Checked @([pscustomobject]@{ _raw=$raw }) -SourcePending ([pscustomobject]@{ pending_schema_version=[int64]2; suspicious=@() })

        $payload.pending_schema_version | Should -Be 2
        $payload.pending_schema_version.GetType() | Should -Be ([int64])
    }

    It 'GUI subset JSON 无损保留 <Levels> 层扩展字段' -TestCases @(
        @{ Levels = 12 }
        @{ Levels = 55 }
    ) {
        param($Levels)
        $deep = [pscustomobject]@{ terminal = "subset-$Levels" }
        for ($i = 0; $i -lt $Levels; $i++) { $deep = [pscustomobject]@{ next = $deep } }
        $raw = [pscustomobject]@{ id='deep'; action='disable_service'; hit_type='service'; status='pending' }
        $source = [pscustomobject]@{
            pending_schema_version=2; generated='x'; actions=@($raw); observations=@(); suspicious=@(); extension=$deep
        }

        $payload = New-PendingSubsetPayload -Checked @([pscustomobject]@{ _raw=$raw }) -SourcePending $source
        $roundTrip = ConvertTo-GuiPendingJson -InputObject $payload | ConvertFrom-Json
        $cursor = $roundTrip.extension
        for ($i = 0; $i -lt $Levels; $i++) { $cursor = $cursor.next }
        $cursor | Should -BeOfType ([pscustomobject])
        $cursor.terminal | Should -Be "subset-$Levels"
    }

    It '异步执行路径遇到非法 reviewed pending schema 不启动管理员 clean 且不写临时 subset' {
        $oldRoot = $script:Root
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('invalid-chain-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $script:Root = $tempRoot
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            $script:ReviewedPendingSnapshot.pending_schema_version = [int32]1
            Mock Start-Process { throw 'Start-Process must not run' }

            Start-GuiExecution -List $fixture.List | Should -BeFalse

            Assert-MockCalled Start-Process -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $tempRoot -Filter 'shushu_pending_*.json').Count | Should -Be 0
            $script:Win.FindName('ErrorDetailText').Text | Should -Match 'scan'
        } finally {
            $script:Root = $oldRoot
            $env:TEMP = $oldTemp
            if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
        }
    }

    It '异步管理员启动异常后仅清理本次临时 subset 并明确未授权未开始' {
        $oldRoot = $script:Root
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('cleanup-chain-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $script:Root = $tempRoot
        $env:TEMP = $tempRoot
        $sentinel = Join-Path $tempRoot 'shushu_pending_keep.json'
        try {
            [System.IO.File]::WriteAllText($sentinel, 'keep', [System.Text.UTF8Encoding]::new($false))
            $fixture = Set-GuiReviewedExecutionFixture
            Mock Start-Process { throw 'simulated UAC failure' }

            Start-GuiExecution -List $fixture.List | Should -BeFalse

            Assert-MockCalled Start-Process -Times 1 -Exactly
            Test-Path -LiteralPath $sentinel | Should -BeTrue
            @(Get-ChildItem -LiteralPath $tempRoot -Filter 'shushu_pending_*.json' | Where-Object { $_.FullName -ne $sentinel }).Count | Should -Be 0
            $script:Win.FindName('ErrorSummaryText').Text | Should -Match '未授权'
            $script:Win.FindName('ErrorMutationText').Text | Should -Match '未开始处理'
        } finally {
            $script:Root = $oldRoot
            $env:TEMP = $oldTemp
            if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
        }
    }

    It 'UAC 等待阶段门闩阻止重入且取得进程前不启动 timer' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('starting-latch-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            $script:ReentrantStartResult = $null
            $script:StartingPathSeen = $null
            Mock Start-Process {
                $script:ExecutionInProgress | Should -BeTrue
                $script:ExecutionLifecycle | Should -Be 'starting'
                $script:ExecutionTimer | Should -BeNullOrEmpty
                $script:StartingPathSeen = $script:ExecutionTempPath
                $script:ReentrantStartResult = Start-GuiExecution -List $fixture.List
                return [pscustomobject]@{ HasExited=$false; ExitCode=0 }
            }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $fixture.List | Should -BeTrue

            $script:ReentrantStartResult | Should -BeFalse
            $script:ExecutionTempPath | Should -BeExactly $script:StartingPathSeen
            $script:ExecutionTimer.Started | Should -BeTrue
            Assert-MockCalled Start-Process -Times 1 -Exactly
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $script:ExecutionProcess = $null
            $script:ExecutionTimer = $null
            $script:ExecutionTempPath = $null
            $script:ExecutionActions = @()
            $script:ExecutionInProgress = $false
            $script:ExecutionLifecycle = 'idle'
            $env:TEMP = $oldTemp
        }
    }

    It '管理员进程启动后 timer <FailurePoint> 失败立即安全脱离且保留进程和 subset' -TestCases @(
        @{ FailurePoint='construct'; FailureMessage='injected timer construction failure' }
        @{ FailurePoint='start'; FailureMessage='injected timer start failure' }
    ) {
        param($FailurePoint, $FailureMessage)
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ("timer-$FailurePoint-" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            $process = [pscustomobject]@{ HasExited=$false; ExitCode=0 }
            Mock Start-Process { return $process }
            Mock New-Object {
                if ($FailurePoint -eq 'construct') { throw $FailureMessage }
                $timer = [pscustomobject]@{ Stopped=$false; Started=$false; TickHandler=$null; Interval=$null }
                $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true }
                $timer | Add-Member -MemberType ScriptMethod -Name Add_Tick -Value { param($handler); $this.TickHandler = $handler }
                $timer | Add-Member -MemberType ScriptMethod -Name Start -Value { throw 'injected timer start failure' }
                return $timer
            } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $fixture.List | Should -BeFalse
            $path = $script:ExecutionTempPath
            $timer = $script:ExecutionTimer
            Start-GuiExecution -List $fixture.List | Should -BeFalse
            $closing = [pscustomobject]@{ Cancel=$false }
            Protect-GuiExecutionWindowClose -EventArgs $closing | Should -BeTrue

            Assert-MockCalled Start-Process -Times 1 -Exactly
            $script:ExecutionProcess | Should -Be $process
            $script:ExecutionTempPath | Should -BeExactly $path
            Test-Path -LiteralPath $path | Should -BeTrue
            $script:ExecutionLifecycle | Should -Be 'detached'
            $script:ExecutionInProgress | Should -BeFalse
            $closing.Cancel | Should -BeFalse
            if ($FailurePoint -eq 'construct') {
                $timer | Should -BeNullOrEmpty
            } else {
                $timer.Stopped | Should -BeTrue
            }
            $script:Win.FindName('ErrorSummaryText').Text | Should -Match '未知'
            $script:Win.FindName('ErrorMutationText').Text | Should -Match '部分'
            $script:Win.FindName('ErrorMutationText').Text | Should -Not -Match '未开始'
            $script:Win.FindName('ErrorDetailText').Text | Should -Match ([regex]::Escape($FailureMessage))
            $script:Win.FindName('ErrorDetailText').Text | Should -Match ([regex]::Escape($path))
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $script:ExecutionProcess = $null
            $script:ExecutionTimer = $null
            $script:ExecutionTempPath = $null
            $script:ExecutionActions = @()
            $script:ExecutionInProgress = $false
            $script:ExecutionLifecycle = 'idle'
            $script:ExecutionUnknownProbeCount = 0
            $env:TEMP = $oldTemp
        }
    }

    It '运行中第二次启动不停止旧 timer、不清旧 subset 且不启动第二个 clean' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('running-latch-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            $oldProcess = [pscustomobject]@{ HasExited=$false; ExitCode=0 }
            Mock Start-Process { return $oldProcess }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }
            Start-GuiExecution -List $fixture.List | Should -BeTrue
            $oldPath = $script:ExecutionTempPath
            $oldTimer = $script:ExecutionTimer

            Start-GuiExecution -List $fixture.List | Should -BeFalse

            $script:ExecutionProcess | Should -Be $oldProcess
            $script:ExecutionTempPath | Should -BeExactly $oldPath
            $script:ExecutionTimer | Should -Be $oldTimer
            $oldTimer.Stopped | Should -BeFalse
            Test-Path -LiteralPath $oldPath | Should -BeTrue
            Assert-MockCalled Start-Process -Times 1 -Exactly
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $script:ExecutionProcess = $null
            $script:ExecutionTimer = $null
            $script:ExecutionTempPath = $null
            $script:ExecutionActions = @()
            $script:ExecutionInProgress = $false
            $script:ExecutionLifecycle = 'idle'
            $env:TEMP = $oldTemp
        }
    }

    It '状态未知时资源清理与窗口 Closing 均保留进程、timer 和诊断 subset' {
        $tempRoot = Join-Path $TestDrive ('unknown-close-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $path = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, '{}', [System.Text.UTF8Encoding]::new($false))
        $process = [pscustomobject]@{ HasExited=$null; ExitCode=$null }
        $timer = New-ExecutionFakeTimer
        $script:ExecutionProcess = $process
        $script:ExecutionTimer = $timer
        $script:ExecutionTempPath = $path
        $script:ExecutionInProgress = $true
        $script:ExecutionLifecycle = 'unknown'

        Clear-GuiExecutionResources -RemoveTemp
        $closing = [pscustomobject]@{ Cancel=$false }
        Protect-GuiExecutionWindowClose -EventArgs $closing | Should -BeFalse

        $closing.Cancel | Should -BeTrue
        $script:ExecutionProcess | Should -Be $process
        $script:ExecutionTimer | Should -Be $timer
        $timer.Stopped | Should -BeFalse
        $script:ExecutionTempPath | Should -BeExactly $path
        Test-Path -LiteralPath $path | Should -BeTrue
        $script:Win.FindName('StateSubtitle').Text | Should -Match '仍在|未知|关闭'

        Remove-Item -LiteralPath $path -Force
        $script:ExecutionProcess = $null
        $script:ExecutionTimer = $null
        $script:ExecutionTempPath = $null
        $script:ExecutionActions = @()
        $script:ExecutionInProgress = $false
        $script:ExecutionLifecycle = 'idle'
    }

    It '异步 subset payload helper 返回 false 时不启动管理员 clean 且不写临时文件' {
        $oldRoot = $script:Root
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('false-payload-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $script:Root = $tempRoot
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            Mock New-PendingSubsetPayload { return $false }
            Mock Start-Process { throw 'Start-Process must not run' }

            Start-GuiExecution -List $fixture.List | Should -BeFalse

            Assert-MockCalled Start-Process -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $tempRoot -Filter 'shushu_pending_*.json').Count | Should -Be 0
        } finally {
            $script:Root = $oldRoot
            $env:TEMP = $oldTemp
            if ([System.IO.Directory]::Exists($tempRoot)) { [System.IO.Directory]::Delete($tempRoot, $true) }
        }
    }

    It '执行授权只用 reviewed allowlist 并从 reviewed snapshot actions 解析原始 action' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('reviewed-source-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture -ActionServiceName 'ReviewedService'
            $selected = @($fixture.List.Items | Where-Object IsChecked)[0]
            $selected.CanExecute = $false
            $viewRawCopy = $selected._raw.PSObject.Copy()
            $viewRawCopy | Add-Member -NotePropertyName injected_from_view -NotePropertyValue 'must-not-copy'
            $selected._raw = $viewRawCopy
            $fakeProcess = [pscustomobject]@{ HasExited=$false; ExitCode=0 }
            Mock Start-Process { return $fakeProcess }
            Mock New-Object {
                $timer = New-ExecutionFakeTimer
                return $timer
            } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $fixture.List | Should -BeTrue

            $payload = Get-Content -LiteralPath $script:ExecutionTempPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($payload.actions).Count | Should -Be 1
            $payload.actions[0].service_name | Should -Be 'ReviewedService'
            $payload.actions[0].PSObject.Properties['injected_from_view'] | Should -BeNullOrEmpty
            @($payload.observations).Count | Should -Be 0
            $script:ExecutionTimer.Interval.TotalMilliseconds | Should -Be 500
            $script:GuiState | Should -Be 'executing'
            Complete-ExecutionPoll | Should -BeFalse
            Test-Path -LiteralPath $script:ExecutionTempPath | Should -BeTrue
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $env:TEMP = $oldTemp
        }
    }

    It 'GUI 将 subset 文件字节 SHA-256 绑定到管理员 clean 参数' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('subset-hash-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            $script:CapturedExecutionArguments = $null
            Mock Start-Process {
                $script:CapturedExecutionArguments = @($ArgumentList)
                return [pscustomobject]@{ HasExited=$false; ExitCode=0 }
            }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $fixture.List | Should -BeTrue

            $hashIndex = [array]::IndexOf($script:CapturedExecutionArguments, '-PendingSha256Arg')
            $hashIndex | Should -BeGreaterOrEqual 0
            $passedHash = $script:CapturedExecutionArguments[$hashIndex + 1]
            $passedHash | Should -Match '^[0-9a-fA-F]{64}$'
            $expectedHash = (Get-FileHash -LiteralPath $script:ExecutionTempPath -Algorithm SHA256).Hash
            $passedHash | Should -BeExactly $expectedHash
        } finally {
            $env:TEMP = $oldTemp
        }
    }

    It '篡改 observation 的 IsChecked 和 CanExecute 不能进入异步执行' {
        $fixture = Set-GuiReviewedExecutionFixture
        foreach ($item in @($fixture.List.Items)) { $item.IsChecked = $false }
        $observation = @($fixture.List.Items | Where-Object { -not $_.CanExecute })[0]
        $observation.IsChecked = $true
        $observation.CanExecute = $true
        Mock Start-Process { throw 'Start-Process must not run' }

        Start-GuiExecution -List $fixture.List | Should -BeFalse

        Assert-MockCalled Start-Process -Times 0 -Exactly
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '未开始处理'
    }

    It '大小写不同的 reviewed identity 以 Ordinal 精确解析原始 action' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('ordinal-actions-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            Set-GuiState review -Force
            $upper = (New-GuiReviewPendingFixture -ActionServiceName 'CaseService').actions[0]
            $lower = $upper.PSObject.Copy(); $lower.service_name = 'caseservice'; $lower.name_cn = 'lower action'
            $pending = [pscustomobject]@{ pending_schema_version=[int64]2; actions=@($upper,$lower); observations=@(); suspicious=@() }
            $script:ReviewedPendingSnapshot = $pending
            $keys = [System.Collections.Generic.List[string]]::new()
            foreach ($key in @(Get-GuiValidatedActionIdentityKeys -Pending $pending)) { $keys.Add($key) }
            $script:ReviewedActionIdentityKeys = $keys.AsReadOnly()
            $list = $script:Win.FindName('PendingList')
            $list.ItemsSource = $null; $list.Items.Clear()
            foreach ($item in @(Get-PendingViewItems -Pending $pending)) { [void]$list.Items.Add($item) }
            $list.Items[0].IsChecked = $true
            $list.Items[1].IsChecked = $false
            Mock Start-Process { return [pscustomobject]@{ HasExited=$false; ExitCode=0 } }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $list | Should -BeTrue

            $payload = Get-Content -LiteralPath $script:ExecutionTempPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($payload.actions).Count | Should -Be 1
            $payload.actions[0].service_name | Should -BeExactly 'CaseService'
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $env:TEMP = $oldTemp
        }
    }

    It '异步执行不重新读取 pending_actions.json 作为授权来源' {
        $oldRoot = $script:Root
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('no-reread-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $script:Root = $tempRoot
        $env:TEMP = $tempRoot
        try {
            [System.IO.File]::WriteAllText((Join-Path $tempRoot 'pending_actions.json'), '{broken json', [System.Text.UTF8Encoding]::new($false))
            $fixture = Set-GuiReviewedExecutionFixture
            Mock Start-Process { return [pscustomobject]@{ HasExited=$false; ExitCode=0 } }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }

            Start-GuiExecution -List $fixture.List | Should -BeTrue
            Assert-MockCalled Start-Process -Times 1 -Exactly
        } finally {
            if ($script:ExecutionTempPath -and (Test-Path -LiteralPath $script:ExecutionTempPath)) { Remove-Item -LiteralPath $script:ExecutionTempPath -Force }
            $script:Root = $oldRoot
            $env:TEMP = $oldTemp
        }
    }

    It '运行中轮询从 subset 刷新逐项真实状态且暂时读失败保留旧显示' {
        $oldTemp = $env:TEMP
        $tempRoot = Join-Path $TestDrive ('running-refresh-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $env:TEMP = $tempRoot
        try {
            $fixture = Set-GuiReviewedExecutionFixture
            Mock Start-Process { return [pscustomobject]@{ HasExited=$false; ExitCode=0 } }
            Mock New-Object { return (New-ExecutionFakeTimer) } -ParameterFilter { $TypeName -eq 'System.Windows.Threading.DispatcherTimer' }
            Start-GuiExecution -List $fixture.List | Should -BeTrue
            @($script:Win.FindName('ExecutionList').ItemsSource)[0].State | Should -Be 'running'

            $payload = Get-Content -LiteralPath $script:ExecutionTempPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $payload.actions[0].status = 'failed'
            [System.IO.File]::WriteAllText($script:ExecutionTempPath, (ConvertTo-GuiPendingJson $payload), [System.Text.UTF8Encoding]::new($false))

            Complete-ExecutionPoll | Should -BeFalse
            $rows = @($script:Win.FindName('ExecutionList').ItemsSource)
            $rows.Count | Should -Be 1
            $rows[0].State | Should -Be 'failed'
            $rows[0].StateLabel | Should -Be '失败'
            $script:GuiState | Should -Be 'executing'

            [System.IO.File]::WriteAllText($script:ExecutionTempPath, '{temporarily incomplete', [System.Text.UTF8Encoding]::new($false))
            Complete-ExecutionPoll | Should -BeFalse
            @($script:Win.FindName('ExecutionList').ItemsSource)[0].State | Should -Be 'failed'
            $script:GuiState | Should -Be 'executing'
        } finally {
            Clear-GuiExecutionResources -RemoveTemp -ProcessExitConfirmed
            $env:TEMP = $oldTemp
        }
    }

    It 'WaitForExit(0) 单次探测异常保留 timer 并在重试恢复后完成 exit 0' {
        $tempRoot = Join-Path $TestDrive ('probe-method-error-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $oldRoot = $script:Root; $script:Root = $tempRoot
        $action = (New-GuiReviewPendingFixture).actions[0]
        $resultAction = $action.PSObject.Copy(); $resultAction.status = 'success'
        $subset = [pscustomobject]@{ pending_schema_version=2; actions=@($resultAction); observations=@(); suspicious=@() }
        $path = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, (ConvertTo-GuiPendingJson $subset), [System.Text.UTF8Encoding]::new($false))
        $mainPath = Join-Path $tempRoot 'pending_actions.json'
        [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($action); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
        Set-GuiReviewedGenerationFromFile $mainPath
        $process = [pscustomobject]@{ ExitCode=0; ProbeCalls=0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds); $this.ProbeCalls++; if ($this.ProbeCalls -eq 1) { throw 'probe method failed' }; return $true }
        $timer = New-ExecutionFakeTimer
        $script:ExecutionProcess = $process; $script:ExecutionTimer = $timer; $script:ExecutionTempPath = $path
        $script:ExecutionActions = @($action); $script:ExecutionInProgress = $true; $script:ExecutionLifecycle = 'running'
        $script:Win.FindName('CompletedSummaryText').Text = ''
        Set-GuiState executing -Force

        Complete-ExecutionPoll | Should -BeFalse

        $script:GuiState | Should -Be 'error'
        $script:ExecutionLifecycle | Should -Be 'unknown'
        $script:ExecutionProcess | Should -Be $process
        $script:ExecutionTempPath | Should -BeExactly $path
        $timer.Stopped | Should -BeFalse
        $timer.Interval.TotalMilliseconds | Should -Be 1000
        Test-Path -LiteralPath $path | Should -BeTrue
        $script:Win.FindName('ErrorSummaryText').Text | Should -Match '未知'
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '部分'

        Complete-ExecutionPoll | Should -BeTrue
        $script:GuiState | Should -Be 'completed'
        $process.ProbeCalls | Should -Be 2
        Test-Path -LiteralPath $path | Should -BeFalse
        $script:Root = $oldRoot
    }

    It 'unknown 重试恢复为非零 exit 时进入 error 而不误报 completed' {
        $tempRoot = Join-Path $TestDrive ('probe-recover-error-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $action = (New-GuiReviewPendingFixture).actions[0]; $action.status = 'failed'
        $path = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($action); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
        $process = [pscustomobject]@{ ExitCode=7; ProbeCalls=0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds); $this.ProbeCalls++; if ($this.ProbeCalls -eq 1) { throw 'transient getter failure' }; return $true }
        $timer = New-ExecutionFakeTimer
        $script:ExecutionProcess = $process; $script:ExecutionTimer = $timer; $script:ExecutionTempPath = $path
        $script:ExecutionActions = @($action); $script:ExecutionInProgress = $true; $script:ExecutionLifecycle = 'running'
        $script:Win.FindName('CompletedSummaryText').Text = ''
        Set-GuiState executing -Force

        Complete-ExecutionPoll | Should -BeFalse
        Complete-ExecutionPoll | Should -BeTrue

        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorSummaryText').Text | Should -Match '7'
        $script:Win.FindName('CompletedSummaryText').Text | Should -Not -Match 'Done|执行完成'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'unknown 达到重试上限后安全脱离并允许关闭但保留进程与原 temp' {
        $tempRoot = Join-Path $TestDrive ('probe-detached-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $path = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($path, '{}', [System.Text.UTF8Encoding]::new($false))
        $process = [pscustomobject]@{ ExitCode=$null }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds); return $true }
        $timer = New-ExecutionFakeTimer
        $script:ExecutionProcess = $process; $script:ExecutionTimer = $timer; $script:ExecutionTempPath = $path
        $script:ExecutionActions = @(); $script:ExecutionInProgress = $true; $script:ExecutionLifecycle = 'running'
        $script:Win.FindName('CompletedSummaryText').Text = ''
        Set-GuiState executing -Force

        Complete-ExecutionPoll | Should -BeFalse
        Complete-ExecutionPoll | Should -BeFalse
        Complete-ExecutionPoll | Should -BeTrue
        Start-GuiExecution -List $script:Win.FindName('PendingList') | Should -BeFalse
        $closing = [pscustomobject]@{ Cancel=$false }
        Protect-GuiExecutionWindowClose -EventArgs $closing | Should -BeTrue

        $script:GuiState | Should -Be 'error'
        $script:ExecutionLifecycle | Should -Be 'detached'
        $script:ExecutionInProgress | Should -BeFalse
        $script:ExecutionProcess | Should -Be $process
        $timer.Stopped | Should -BeTrue
        $closing.Cancel | Should -BeFalse
        Test-Path -LiteralPath $path | Should -BeTrue
        $script:Win.FindName('ErrorSummaryText').Text | Should -Match '未知'
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '部分'
        $script:Win.FindName('ErrorDetailText').Text | Should -Match ([regex]::Escape($path))
        $script:Win.FindName('CompletedSummaryText').Text | Should -Not -Match 'Done|执行完成'
    }

    It 'exit 0 即使有失败跳过和手动项也进入 completed 并逐项展示真实状态' {
        $oldRoot = $script:Root
        $tempRoot = Join-Path $TestDrive ('partial-zero-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $script:Root = $tempRoot
        try {
            $success = (New-GuiReviewPendingFixture -ActionServiceName 'S1').actions[0]
            $failed = (New-GuiReviewPendingFixture -ActionServiceName 'S2').actions[0].PSObject.Copy(); $failed.id='failed-row'; $failed.status='failed'
            $skipped = (New-GuiReviewPendingFixture -ActionServiceName 'S3').actions[0].PSObject.Copy(); $skipped.id='skipped-row'; $skipped.status='skipped'
            $manual = (New-GuiReviewPendingFixture -ActionServiceName 'S4').actions[0].PSObject.Copy(); $manual.id='manual-row'; $manual.status='manual_required'
            $success.status='success'
            $subset = [pscustomobject]@{ pending_schema_version=2; actions=@($success,$failed,$skipped,$manual); observations=@(); suspicious=@() }
            $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
            [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson $subset), [System.Text.UTF8Encoding]::new($false))
            $mainPath = Join-Path $tempRoot 'pending_actions.json'
            $main = $subset.PSObject.Copy(); [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson $main), [System.Text.UTF8Encoding]::new($false))
            Set-GuiReviewedGenerationFromFile $mainPath
            $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
            $script:ExecutionTimer = New-ExecutionFakeTimer
            $script:ExecutionTempPath = $subsetPath
            $script:ExecutionActions = @($success,$failed,$skipped,$manual)
            Set-GuiState executing -Force

            Complete-ExecutionPoll | Should -BeTrue

            $script:GuiState | Should -Be 'completed'
            @($script:Win.FindName('CompletedList').ItemsSource).Count | Should -Be 4
            @($script:Win.FindName('CompletedList').ItemsSource | Where-Object State -eq 'failed').Count | Should -Be 1
            @($script:Win.FindName('CompletedList').ItemsSource | Where-Object State -eq 'manual_required').Count | Should -Be 1
            $script:Win.FindName('CompletedSummaryText').Text | Should -Match 'success 1.*failed 1.*skipped 1.*manual 1'
            Test-Path -LiteralPath $subsetPath | Should -BeFalse
        } finally { $script:Root = $oldRoot }
    }

    It 'exit 0 验证结果只读一次且显示与主清单合并使用同一快照' {
        $tempRoot = Join-Path $TestDrive ('single-result-read-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $oldRoot = $script:Root; $script:Root = $tempRoot
        try {
            $expected = (New-GuiReviewPendingFixture -ActionServiceName 'SingleReadService').actions[0]
            $mainPath = Join-Path $tempRoot 'pending_actions.json'
            [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($expected); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
            Set-GuiReviewedGenerationFromFile $mainPath
            $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
            [System.IO.File]::WriteAllText($subsetPath, '{}', [System.Text.UTF8Encoding]::new($false))
            $script:ExecutionResultReadCount = 0
            Mock Read-GuiPendingFile {
                $script:ExecutionResultReadCount++
                $action = $expected.PSObject.Copy()
                $action.status = if ($script:ExecutionResultReadCount -eq 1) { 'success' } else { 'pending' }
                return [pscustomobject]@{ pending_schema_version=2; actions=@($action); observations=@(); suspicious=@() }
            }
            $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
            $script:ExecutionTimer = New-ExecutionFakeTimer
            $script:ExecutionTempPath = $subsetPath
            $script:ExecutionActions = @($expected)
            $script:ExecutionInProgress = $true; $script:ExecutionLifecycle = 'running'
            Set-GuiState executing -Force

            Complete-ExecutionPoll | Should -BeTrue

            $script:ExecutionResultReadCount | Should -Be 1
            $script:GuiState | Should -Be 'completed'
            @($script:Win.FindName('CompletedList').ItemsSource)[0].State | Should -Be 'success'
            $merged = Get-Content -LiteralPath $mainPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $merged.actions[0].status | Should -Be 'success'
        } finally { $script:Root = $oldRoot }
    }

    It '非零 exit 进入 error 并提示可能已有部分动作执行且尽量展示状态' {
        $tempRoot = Join-Path $TestDrive ('partial-error-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $action = (New-GuiReviewPendingFixture).actions[0]; $action.status='success'
        $subset = [pscustomobject]@{ pending_schema_version=2; actions=@($action); observations=@(); suspicious=@() }
        $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson $subset), [System.Text.UTF8Encoding]::new($false))
        $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=7 }
        $script:ExecutionTimer = New-ExecutionFakeTimer
        $script:ExecutionTempPath = $subsetPath
        $script:ExecutionActions = @($action)
        Set-GuiState executing -Force

        Complete-ExecutionPoll | Should -BeTrue

        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '部分'
        $script:Win.FindName('ErrorDetailText').Text | Should -Match 'success'
        Test-Path -LiteralPath $subsetPath | Should -BeFalse
    }

    It 'exit 0 结果文件不可读时进入 error 并把原字节保全到 diagnostics' {
        $tempRoot = Join-Path $TestDrive ('zero-unreadable-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $oldRoot = $script:Root
        $script:Root = $tempRoot
        $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
        $brokenBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{broken json')
        [System.IO.File]::WriteAllBytes($subsetPath, $brokenBytes)
        $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
        $script:ExecutionTimer = New-ExecutionFakeTimer
        $script:ExecutionTempPath = $subsetPath
        $script:ExecutionActions = @()
        Set-GuiState executing -Force

        Complete-ExecutionPoll | Should -BeTrue

        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorMutationText').Text | Should -Match '部分'
        $diagnostics = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'diagnostics') -File)
        $diagnostics.Count | Should -Be 1
        [System.IO.File]::ReadAllBytes($diagnostics[0].FullName) | Should -Be $brokenBytes
        $script:Win.FindName('ErrorDetailText').Text | Should -Match ([regex]::Escape($diagnostics[0].FullName))
        Test-Path -LiteralPath $subsetPath | Should -BeFalse
    }

    It 'exit 0 结果身份漂移或仍为非终态时拒绝 completed 并保全诊断证据' -TestCases @(
        @{ label='identity'; mutate={ param($a); $a.service_name='DifferentService'; $a.status='success' } }
        @{ label='nonterminal'; mutate={ param($a); $a.status='pending' } }
    ) {
        param($label, $mutate)
        $tempRoot = Join-Path $TestDrive ("zero-invalid-$label-" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $oldRoot = $script:Root
        $script:Root = $tempRoot
        try {
            $expected = (New-GuiReviewPendingFixture).actions[0]
            $actual = $expected.PSObject.Copy()
            & $mutate $actual
            $subset = [pscustomobject]@{ pending_schema_version=2; actions=@($actual); observations=@(); suspicious=@() }
            $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
            [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson $subset), [System.Text.UTF8Encoding]::new($false))
            $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
            $script:ExecutionTimer = New-ExecutionFakeTimer
            $script:ExecutionTempPath = $subsetPath
            $script:ExecutionActions = @($expected)
            $script:ExecutionInProgress = $true
            $script:ExecutionLifecycle = 'running'
            Set-GuiState executing -Force

            Complete-ExecutionPoll | Should -BeTrue

            $script:GuiState | Should -Be 'error'
            @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'diagnostics') -File).Count | Should -Be 1
            Test-Path -LiteralPath $subsetPath | Should -BeFalse
        } finally {
            $script:Root = $oldRoot
        }
    }

    It 'exit 0 主 pending generation 已变化时进入 error、保全结果且不覆盖新 scan' {
        $tempRoot = Join-Path $TestDrive ('zero-merge-conflict-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempRoot)
        $oldRoot = $script:Root; $script:Root = $tempRoot
        try {
            $expected = (New-GuiReviewPendingFixture -ActionServiceName 'ReviewedService').actions[0]
            $reviewedMain = [pscustomobject]@{ pending_schema_version=2; generated='reviewed'; actions=@($expected); observations=@(); suspicious=@() }
            $mainPath = Join-Path $tempRoot 'pending_actions.json'
            [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson $reviewedMain), [System.Text.UTF8Encoding]::new($false))
            Set-GuiReviewedGenerationFromFile $mainPath

            $resultAction = $expected.PSObject.Copy(); $resultAction.status='success'
            $subsetPath = Join-Path $tempRoot ('shushu_pending_' + [guid]::NewGuid().ToString('N') + '.json')
            [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($resultAction); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
            $newAction = (New-GuiReviewPendingFixture -ActionServiceName 'NewScanService').actions[0]
            $newMainBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; generated='new'; actions=@($newAction); observations=@(); suspicious=@(); marker='keep-new-scan' })))
            [System.IO.File]::WriteAllBytes($mainPath, $newMainBytes)
            $script:ExecutionProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
            $script:ExecutionTimer = New-ExecutionFakeTimer
            $script:ExecutionTempPath = $subsetPath
            $script:ExecutionActions = @($expected)
            $script:ExecutionInProgress = $true; $script:ExecutionLifecycle = 'running'
            Set-GuiState executing -Force

            Complete-ExecutionPoll | Should -BeTrue

            $script:GuiState | Should -Be 'error'
            [System.IO.File]::ReadAllBytes($mainPath) | Should -Be $newMainBytes
            @(Get-ChildItem -LiteralPath (Join-Path $tempRoot 'diagnostics') -File).Count | Should -Be 1
            Test-Path -LiteralPath $subsetPath | Should -BeFalse
        } finally { $script:Root = $oldRoot }
    }

    It 'clean 异步路径源码不调用 WaitForExit 且旧阻塞函数已移除' {
        $source = Get-Content -LiteralPath (Join-Path $script:GuiRoot 'gui-cleaner.ps1') -Raw -Encoding UTF8
        $executionSection = [regex]::Match($source, '(?s)# ---------- 异步处理已选择项目.*?# ---------- 查看最近结果').Value
        $executionSection | Should -Not -BeNullOrEmpty
        $executionSection | Should -Match '\.WaitForExit\(0\)'
        $executionSection | Should -Not -Match '\.WaitForExit\(\s*\)'
        $source | Should -Not -Match 'function\s+Invoke-GuiCheckedExecution'
    }

    It 'pending identity 区分 action、PID/path 和 matcher provenance' {
        $base = [ordered]@{ id='p'; hit_type='process'; action='uninstall'; service_name=''; service_display_name=''; autostart_source=''; autostart_name=''; autostart_value=''; task_name=''; task_path=''; process_name='P1'; process_id=101; process_path='C:\Apps\P1.exe'; matched_pattern='P1'; matched_type='exact'; matched_field='process_name' }
        $same = [pscustomobject]$base
        $differentAction = $same.PSObject.Copy(); $differentAction.action = 'investigate'
        $differentPid = $same.PSObject.Copy(); $differentPid.process_id = 202
        $differentPath = $same.PSObject.Copy(); $differentPath.process_path = 'D:\Apps\P1.exe'
        $differentEvidence = $same.PSObject.Copy(); $differentEvidence.matched_field = 'process_path'
        $key = Get-PendingIdentityKey $same
        Get-PendingIdentityKey $same | Should -Be $key
        Get-PendingIdentityKey $differentAction | Should -Not -Be $key
        Get-PendingIdentityKey $differentPid | Should -Not -Be $key
        Get-PendingIdentityKey $differentPath | Should -Not -Be $key
        Get-PendingIdentityKey $differentEvidence | Should -Not -Be $key
    }

    It 'Merge-PendingStatus: 子集状态合并回主清单, 未勾选条目不动' {
        $tmpRoot = Join-Path $env:TEMP ("gui_merge_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $main = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='t1'; hit_type='service'; service_name='S1'; autostart_name=''; task_path=''; process_name=''; status='pending' },
                [pscustomobject]@{ id='t2'; hit_type='service'; service_name='S2'; autostart_name=''; task_path=''; process_name=''; status='pending' }
            )
            suspicious = @()
            observations = @()
        }
        $main | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $subset = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='t1'; hit_type='service'; service_name='S1'; autostart_name=''; task_path=''; process_name=''; status='success' }
            )
            suspicious = @()
            observations = @()
        }
        $subsetFile = Join-Path $tmpRoot 'subset.json'
        $subset | ConvertTo-Json -Depth 5 | Out-File $subsetFile -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        Set-GuiReviewedGenerationFromFile (Join-Path $tmpRoot 'pending_actions.json')
        try { Merge-GuiPendingStatusFromFile $subsetFile } finally { $script:Root = $oldRoot }

        $after = Get-Content (Join-Path $tmpRoot 'pending_actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($after.actions | Where-Object { $_.id -eq 't1' })[0].status | Should -Be 'success'
        @($after.actions | Where-Object { $_.id -eq 't2' })[0].status | Should -Be 'pending'
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }

    It 'Merge-PendingStatus: 同 id 不同 target 不误合并' {
        $tmpRoot = Join-Path $env:TEMP ("gui_merge2_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        # 同 id lenovo-serviceas 两条: 服务 + 自启, target 不同
        $main = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name=''; status='pending' },
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='autostart'; service_name=''; autostart_name='LenovoAppStore'; task_path=''; process_name=''; status='pending' }
            )
            suspicious = @()
            observations = @()
        }
        $main | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $subset = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name=''; status='failed' }
            )
            suspicious = @()
            observations = @()
        }
        $subsetFile = Join-Path $tmpRoot 'subset.json'
        $subset | ConvertTo-Json -Depth 5 | Out-File $subsetFile -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        Set-GuiReviewedGenerationFromFile (Join-Path $tmpRoot 'pending_actions.json')
        try { Merge-GuiPendingStatusFromFile $subsetFile } finally { $script:Root = $oldRoot }

        $after = Get-Content (Join-Path $tmpRoot 'pending_actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($after.actions | Where-Object { $_.hit_type -eq 'service' })[0].status | Should -Be 'failed'
        @($after.actions | Where-Object { $_.hit_type -eq 'autostart' })[0].status | Should -Be 'pending'
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }

    It 'Merge-PendingStatus: 大小写不同 identity 仅 Ordinal 精确合并' {
        $tmpRoot = Join-Path $TestDrive ('gui-merge-ordinal-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $upper = (New-GuiReviewPendingFixture -ActionServiceName 'CaseService').actions[0]
        $lower = $upper.PSObject.Copy(); $lower.service_name='caseservice'; $lower.name_cn='lower action'
        $main = [pscustomobject]@{ pending_schema_version=2; actions=@($upper,$lower); observations=@(); suspicious=@() }
        $subsetUpper = $upper.PSObject.Copy(); $subsetUpper.status='success'
        $subset = [pscustomobject]@{ pending_schema_version=2; actions=@($subsetUpper); observations=@(); suspicious=@() }
        $mainPath = Join-Path $tmpRoot 'pending_actions.json'
        $subsetPath = Join-Path $tmpRoot 'subset.json'
        [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson $main), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson $subset), [System.Text.UTF8Encoding]::new($false))
        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        Set-GuiReviewedGenerationFromFile $mainPath
        try { Merge-GuiPendingStatusFromFile $subsetPath } finally { $script:Root = $oldRoot }

        $after = Get-Content -LiteralPath $mainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($after.actions | Where-Object service_name -CEQ 'CaseService')[0].status | Should -Be 'success'
        @($after.actions | Where-Object service_name -CEQ 'caseservice')[0].status | Should -Be 'pending'
    }

    It 'Merge-PendingStatus 无损保留 <Levels> 层主 envelope 扩展字段' -TestCases @(
        @{ Levels = 12 }
        @{ Levels = 55 }
    ) {
        param($Levels)
        $tmpRoot = Join-Path $TestDrive ("gui-deep-merge-$Levels-" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $deep = [pscustomobject]@{ terminal = "merge-$Levels" }
        for ($i = 0; $i -lt $Levels; $i++) { $deep = [pscustomobject]@{ next = $deep } }
        $action = [pscustomobject]@{ id='deep'; hit_type='service'; action='disable_service'; service_name='Svc'; status='pending' }
        $main = [pscustomobject]@{ pending_schema_version=2; generated='x'; actions=@($action); observations=@(); suspicious=@(); extension=$deep }
        $mainPath = Join-Path $tmpRoot 'pending_actions.json'
        [System.IO.File]::WriteAllText($mainPath, (ConvertTo-Json -InputObject $main -Depth 100), [System.Text.UTF8Encoding]::new($false))
        $subsetAction = $action.PSObject.Copy(); $subsetAction.status = 'success'
        $subset = [pscustomobject]@{ pending_schema_version=2; generated='x'; actions=@($subsetAction); observations=@(); suspicious=@() }
        $subsetPath = Join-Path $tmpRoot 'subset.json'
        [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-Json -InputObject $subset -Depth 100), [System.Text.UTF8Encoding]::new($false))
        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        Set-GuiReviewedGenerationFromFile $mainPath
        try { Merge-GuiPendingStatusFromFile $subsetPath } finally { $script:Root = $oldRoot }

        $roundTrip = Get-Content -LiteralPath $mainPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cursor = $roundTrip.extension
        for ($i = 0; $i -lt $Levels; $i++) { $cursor = $cursor.next }
        $cursor | Should -BeOfType ([pscustomobject])
        $cursor.terminal | Should -Be "merge-$Levels"
    }

    It 'Merge-PendingStatus: 同进程名按 PID/path/provenance 精确合并' {
        $tmpRoot = Join-Path $env:TEMP ("gui_merge_process_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $common = [ordered]@{ id='same-process'; hit_type='process'; action='uninstall'; service_name=''; service_display_name=''; autostart_source=''; autostart_name=''; autostart_value=''; task_name=''; task_path=''; process_name='P1'; process_path='C:\Apps\P1.exe'; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'; status='pending' }
        $pid101 = [pscustomobject]$common; $pid101 | Add-Member process_id 101
        $pid202 = $pid101.PSObject.Copy(); $pid202.process_id = 202
        $pathEvidence = $pid101.PSObject.Copy(); $pathEvidence.matched_pattern='C:\Apps'; $pathEvidence.matched_type='path'; $pathEvidence.matched_field='process_path'
        $main = [pscustomobject]@{ pending_schema_version=2; generated='x'; actions=@($pid101,$pid202,$pathEvidence); observations=@(); suspicious=@() }
        $main | ConvertTo-Json -Depth 6 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $subsetAction = [pscustomobject]@{}
        $pid101.PSObject.Properties | ForEach-Object { $subsetAction | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value }
        $subsetAction.status = 'success'
        $subset = [pscustomobject]@{ pending_schema_version=2; generated='x'; actions=@($subsetAction); observations=@(); suspicious=@() }
        $subsetFile = Join-Path $tmpRoot 'subset.json'
        $subset | ConvertTo-Json -Depth 6 | Out-File $subsetFile -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        Set-GuiReviewedGenerationFromFile (Join-Path $tmpRoot 'pending_actions.json')
        try { Merge-GuiPendingStatusFromFile $subsetFile } finally { $script:Root = $oldRoot }

        $after = Get-Content (Join-Path $tmpRoot 'pending_actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($after.actions | Where-Object { $_.process_id -eq 101 -and $_.matched_field -eq 'process_name' })[0].status | Should -Be 'success'
        @($after.actions | Where-Object { $_.process_id -eq 202 })[0].status | Should -Be 'pending'
        @($after.actions | Where-Object { $_.process_id -eq 101 -and $_.matched_field -eq 'process_path' })[0].status | Should -Be 'pending'
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }

    It 'Merge-PendingStatus 在 review 后主文件被替换时拒绝且不覆盖新 scan' {
        $tmpRoot = Join-Path $TestDrive ('gui-merge-generation-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $reviewedAction = (New-GuiReviewPendingFixture -ActionServiceName 'ReviewedService').actions[0]
        $reviewed = [pscustomobject]@{ pending_schema_version=2; generated='reviewed'; actions=@($reviewedAction); observations=@(); suspicious=@() }
        $mainPath = Join-Path $tmpRoot 'pending_actions.json'
        [System.IO.File]::WriteAllText($mainPath, (ConvertTo-GuiPendingJson $reviewed), [System.Text.UTF8Encoding]::new($false))
        Set-GuiReviewedGenerationFromFile $mainPath

        $newAction = (New-GuiReviewPendingFixture -ActionServiceName 'NewScanService').actions[0]
        $replacement = [pscustomobject]@{ pending_schema_version=2; generated='new-scan'; actions=@($newAction); observations=@(); suspicious=@(); marker='must-survive' }
        $replacementBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-GuiPendingJson $replacement))
        [System.IO.File]::WriteAllBytes($mainPath, $replacementBytes)
        $subsetAction = $reviewedAction.PSObject.Copy(); $subsetAction.status='success'
        $subsetPath = Join-Path $tmpRoot 'subset.json'
        [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($subsetAction); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
        $oldRoot = $script:Root; $script:Root = $tmpRoot
        try {
            { Merge-GuiPendingStatusFromFile $subsetPath } | Should -Throw '*generation*'
            [System.IO.File]::ReadAllBytes($mainPath) | Should -Be $replacementBytes
        } finally { $script:Root = $oldRoot }
    }

    It 'Merge-PendingStatus 遇到主清单并发占用时拒绝且不改原字节' {
        $tmpRoot = Join-Path $TestDrive ('gui-merge-occupied-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $action = (New-GuiReviewPendingFixture).actions[0]
        $mainPath = Join-Path $tmpRoot 'pending_actions.json'
        $mainBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($action); observations=@(); suspicious=@() })))
        [System.IO.File]::WriteAllBytes($mainPath, $mainBytes)
        Set-GuiReviewedGenerationFromFile $mainPath
        $subsetAction = $action.PSObject.Copy(); $subsetAction.status='success'
        $subsetPath = Join-Path $tmpRoot 'subset.json'
        [System.IO.File]::WriteAllText($subsetPath, (ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; actions=@($subsetAction); observations=@(); suspicious=@() })), [System.Text.UTF8Encoding]::new($false))
        $lock = [System.IO.File]::Open($mainPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $oldRoot = $script:Root; $script:Root = $tmpRoot
        try {
            { Merge-GuiPendingStatusFromFile $subsetPath } | Should -Throw
        } finally {
            $lock.Dispose(); $script:Root = $oldRoot
        }
        [System.IO.File]::ReadAllBytes($mainPath) | Should -Be $mainBytes
    }

    It 'Merge-PendingStatus 写回中途失败时在同一独占锁内恢复原始 JSON 字节' {
        $tmpRoot = Join-Path $TestDrive ('gui-merge-write-rollback-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tmpRoot)
        $action = (New-GuiReviewPendingFixture -ActionServiceName 'RollbackService').actions[0]
        $mainPath = Join-Path $tmpRoot 'pending_actions.json'
        $mainBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-GuiPendingJson ([pscustomobject]@{ pending_schema_version=2; generated='original'; actions=@($action); observations=@(); suspicious=@(); marker='restore-me' })))
        [System.IO.File]::WriteAllBytes($mainPath, $mainBytes)
        Set-GuiReviewedGenerationFromFile $mainPath
        $resultAction = $action.PSObject.Copy(); $resultAction.status = 'success'
        $pairs = [System.Collections.Generic.List[System.Tuple[string,string]]]::new()
        $pairs.Add([System.Tuple[string,string]]::new((Get-PendingIdentityKey $resultAction), 'success'))
        $script:ExecutionActions = @($action)
        $result = [pscustomobject]@{ Items=$pairs.AsReadOnly() }
        Mock Write-GuiPendingBytesToLockedStream {
            param($Stream, $Bytes)
            $Stream.Position = 0
            $Stream.SetLength(0)
            $Stream.Write($Bytes, 0, [Math]::Min(7, $Bytes.Length))
            throw 'injected write failure after truncation'
        }
        $oldRoot = $script:Root; $script:Root = $tmpRoot
        try {
            { Merge-PendingStatus $result } | Should -Throw '*injected write failure*'
        } finally { $script:Root = $oldRoot }

        [System.IO.File]::ReadAllBytes($mainPath) | Should -Be $mainBytes
    }

    It '恢复 exit 0 在单页 completed 状态展示成功且不弹成功模态框' {
        $tmpRoot = Join-Path $TestDrive ('restore-ok-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $tmpRoot 'backups\20260811_010101'
        [void][System.IO.Directory]::CreateDirectory($backup)
        [System.IO.File]::WriteAllText((Join-Path $backup 'manifest.json'), '[{"type":"service","name":"DemoService","verified":true}]', [System.Text.UTF8Encoding]::new($false))
        $process = [pscustomobject]@{ ExitCode=0; Waited=$false }
        $process | Add-Member ScriptMethod WaitForExit { $this.Waited=$true }
        Mock Start-Process { $process }
        Mock Show-GuiMessage {}
        $oldRoot=$script:Root; $script:Root=$tmpRoot
        try { Invoke-GuiRestoreLatest | Should -BeTrue } finally { $script:Root=$oldRoot }

        $process.Waited | Should -BeTrue
        $script:GuiState | Should -Be 'completed'
        $script:Win.FindName('CompletedSummaryText').Text | Should -Match '已恢复'
        Assert-MockCalled Show-GuiMessage -Times 0 -Exactly
    }

    It 'completed 摘要在存在失败项时使用危险色强调' {
        Set-GuiCompletedSummary -Success 1 -Failed 1 -Skipped 1 -Manual 0

        $summary = $script:Win.FindName('CompletedSummaryText')
        $summary.Text | Should -Match 'failed 1|失败 1'
        $summary.Foreground.ToString() | Should -Be $script:Win.Resources['Danger'].ToString()
    }

    It '恢复 exit 2 在单页 completed 状态如实展示部分失败与 manifest 明细' {
        $tmpRoot = Join-Path $TestDrive ('restore-partial-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $tmpRoot 'backups\20260811_020202'
        [void][System.IO.Directory]::CreateDirectory($backup)
        [System.IO.File]::WriteAllText((Join-Path $backup 'manifest.json'), '[{"type":"service","name":"GoodService","verified":true},{"type":"task","name":"FailedTask","verified":false}]', [System.Text.UTF8Encoding]::new($false))
        $process = [pscustomobject]@{ ExitCode=2 }
        $process | Add-Member ScriptMethod WaitForExit {}
        Mock Start-Process { $process }
        Mock Show-GuiMessage {}
        $oldRoot=$script:Root; $script:Root=$tmpRoot
        try { Invoke-GuiRestoreLatest | Should -BeTrue } finally { $script:Root=$oldRoot }

        $script:GuiState | Should -Be 'completed'
        $script:Win.FindName('CompletedSummaryText').Text | Should -Match '部分'
        @($script:Win.FindName('CompletedList').ItemsSource | Where-Object { $_.State -eq 'failed' -and $_.Name -eq 'FailedTask' }).Count | Should -Be 1
        Assert-MockCalled Show-GuiMessage -Times 0 -Exactly
    }

    It '恢复非零错误进入 error 且只显示警告模态框' {
        $tmpRoot = Join-Path $TestDrive ('restore-error-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $tmpRoot 'backups\20260811_030303'
        [void][System.IO.Directory]::CreateDirectory($backup)
        $process = [pscustomobject]@{ ExitCode=7 }
        $process | Add-Member ScriptMethod WaitForExit {}
        Mock Start-Process { $process }
        Mock Show-GuiMessage {}
        $oldRoot=$script:Root; $script:Root=$tmpRoot
        try { Invoke-GuiRestoreLatest | Should -BeFalse } finally { $script:Root=$oldRoot }

        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorSummaryText').Text | Should -Match '7'
        Assert-MockCalled Show-GuiMessage -Times 1 -Exactly
    }

    It '恢复 UAC 取消进入 error 且不宣称恢复成功' {
        $tmpRoot = Join-Path $TestDrive ('restore-uac-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $tmpRoot 'backups\20260811_040404'
        [void][System.IO.Directory]::CreateDirectory($backup)
        Mock Start-Process { throw 'simulated UAC cancellation' }
        Mock Show-GuiMessage {}
        $oldRoot=$script:Root; $script:Root=$tmpRoot
        try { Invoke-GuiRestoreLatest | Should -BeFalse } finally { $script:Root=$oldRoot }

        $script:GuiState | Should -Be 'error'
        $script:Win.FindName('ErrorSummaryText').Text | Should -Match '恢复|Restore'
        $script:Win.FindName('CompletedSummaryText').Text | Should -Not -Match '已恢复|Restored'
        Assert-MockCalled Show-GuiMessage -Times 1 -Exactly
    }
}
