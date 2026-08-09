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
            $t | Add-Member -MemberType ScriptMethod -Name Stop -Value { $this.Stopped = $true }
            return $t
        }
    }

    It 'XAML 加载成功且关键控件存在' {
        $script:Win | Should -Not -Be $null
        foreach ($n in @('TabScan','TabPending','TabExec','TabResult','BtnScan','BtnLoadPending','BtnExec','BtnResult','BtnRestore','ScanProgress','ScanOutput','PendingList','ExecOutput','ResultOutput')) {
            $script:Win.FindName($n) | Should -Not -Be $null
        }
    }

    It '鼠鼠图片资源存在' {
        foreach ($imgName in $script:ImgMap.Keys) {
            Test-Path (Join-Path $script:GuiRoot $script:ImgMap[$imgName]) | Should -Be $true
        }
    }

    It '语言切换 zh/en 更新标题' {
        $script:Lang = 'zh'; Apply-Language
        $script:Win.FindName('TitleMain').Text | Should -Be '鼠鼠cleaner'
        $script:Lang = 'en'; Apply-Language
        $script:Win.FindName('TitleMain').Text | Should -Be 'Shushu Cleaner'
        $script:Lang = 'zh'; Apply-Language
    }

    It '扫描轮询: Completed 恢复按钮并置进度 100' {
        $btn = [pscustomobject]@{ IsEnabled = $false }
        $prog = [pscustomobject]@{ Value = 0 }
        $out = [pscustomobject]@{ Text = '' }
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        $job = [pscustomobject]@{ State = 'Completed' }
        $done = Complete-ScanPoll -job $job -checkTimer $t1 -scanTimer $t2 -btn $btn -prog $prog -out $out
        $done | Should -Be $true
        $btn.IsEnabled | Should -Be $true
        $prog.Value | Should -Be 100
        $t1.Stopped | Should -Be $true
        $t2.Stopped | Should -Be $true
    }

    It '扫描轮询: Failed 恢复按钮并提示失败 (v1.5.3 修复)' {
        $btn = [pscustomobject]@{ IsEnabled = $false }
        $prog = [pscustomobject]@{ Value = 0 }
        $out = [pscustomobject]@{ Text = '' }
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        $job = [pscustomobject]@{ State = 'Failed' }
        $done = Complete-ScanPoll -job $job -checkTimer $t1 -scanTimer $t2 -btn $btn -prog $prog -out $out
        $done | Should -Be $true
        $btn.IsEnabled | Should -Be $true
        ($out.Text -match '扫描失败') | Should -Be $true
    }

    It '扫描轮询: Stopped 同样收尾' {
        $btn = [pscustomobject]@{ IsEnabled = $false }
        $prog = [pscustomobject]@{ Value = 0 }
        $out = [pscustomobject]@{ Text = '' }
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        $job = [pscustomobject]@{ State = 'Stopped' }
        $done = Complete-ScanPoll -job $job -checkTimer $t1 -scanTimer $t2 -btn $btn -prog $prog -out $out
        $done | Should -Be $true
        $btn.IsEnabled | Should -Be $true
    }

    It '扫描轮询: Running 不处理 (按钮保持禁用)' {
        $btn = [pscustomobject]@{ IsEnabled = $false }
        $prog = [pscustomobject]@{ Value = 0 }
        $out = [pscustomobject]@{ Text = '' }
        $t1 = New-FakeTimer
        $t2 = New-FakeTimer
        $job = [pscustomobject]@{ State = 'Running' }
        $done = Complete-ScanPoll -job $job -checkTimer $t1 -scanTimer $t2 -btn $btn -prog $prog -out $out
        $done | Should -Be $false
        $btn.IsEnabled | Should -Be $false
        $t1.Stopped | Should -Be $false
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
