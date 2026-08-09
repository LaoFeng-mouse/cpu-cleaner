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

Describe '勾选视图 (v1.5.5)' {
    BeforeAll {
        $env:SHUSHU_CLEANER_TEST = '1'
        $script:GuiRoot = Split-Path $PSScriptRoot -Parent
        . (Join-Path $script:GuiRoot 'gui-cleaner.ps1')
        $script:Win = $window
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
        try { $view = @(Get-PendingViewItems) } finally { $script:Root = $oldRoot }

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

    It 'Merge-PendingStatus: 子集状态合并回主清单, 未勾选条目不动' {
        $tmpRoot = Join-Path $env:TEMP ("gui_merge_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        $main = [pscustomobject]@{
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='t1'; hit_type='service'; service_name='S1'; autostart_name=''; task_path=''; process_name=''; status='pending' },
                [pscustomobject]@{ id='t2'; hit_type='service'; service_name='S2'; autostart_name=''; task_path=''; process_name=''; status='pending' }
            )
            suspicious = @()
        }
        $main | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $subset = [pscustomobject]@{
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='t1'; hit_type='service'; service_name='S1'; autostart_name=''; task_path=''; process_name=''; status='success' }
            )
            suspicious = @()
        }
        $subsetFile = Join-Path $tmpRoot 'subset.json'
        $subset | ConvertTo-Json -Depth 5 | Out-File $subsetFile -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try { Merge-PendingStatus $subsetFile } finally { $script:Root = $oldRoot }

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
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name=''; status='pending' },
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='autostart'; service_name=''; autostart_name='LenovoAppStore'; task_path=''; process_name=''; status='pending' }
            )
            suspicious = @()
        }
        $main | ConvertTo-Json -Depth 5 | Out-File (Join-Path $tmpRoot 'pending_actions.json') -Encoding utf8
        $subset = [pscustomobject]@{
            generated = 'x'
            actions = @(
                [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name=''; status='failed' }
            )
            suspicious = @()
        }
        $subsetFile = Join-Path $tmpRoot 'subset.json'
        $subset | ConvertTo-Json -Depth 5 | Out-File $subsetFile -Encoding utf8

        $oldRoot = $script:Root
        $script:Root = $tmpRoot
        try { Merge-PendingStatus $subsetFile } finally { $script:Root = $oldRoot }

        $after = Get-Content (Join-Path $tmpRoot 'pending_actions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($after.actions | Where-Object { $_.hit_type -eq 'service' })[0].status | Should -Be 'failed'
        @($after.actions | Where-Object { $_.hit_type -eq 'autostart' })[0].status | Should -Be 'pending'
        [System.IO.Directory]::Delete($tmpRoot, $true)
    }
}
