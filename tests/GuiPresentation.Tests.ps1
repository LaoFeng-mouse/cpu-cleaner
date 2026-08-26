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
        Test-GuiStateTransition idle error | Should -BeTrue
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

    It 'matches the full approved transition matrix' {
        $states = @('idle','scanning','results','review','executing','completed','error')
        $approved = @{
            idle      = @('scanning','error')
            scanning  = @('results','error')
            results   = @('review','scanning','idle','error')
            review    = @('executing','results','idle','error')
            executing = @('completed','error')
            completed = @('scanning','review','idle','error')
            error     = @('scanning','review','idle')
        }

        foreach ($from in $states) {
            foreach ($to in $states) {
                $actual = Test-GuiStateTransition $from $to
                $actual | Should -Be ($to -in @($approved[$from])) -Because "$from -> $to must match the approved map"
            }
        }
    }

    It 'defines every presentation property for all seven states' {
        $expected = @{
            idle      = @{ Panel='IdlePanel';      ActiveStage=1; Busy=$false; PrimaryKey='BtnStartScan' }
            scanning  = @{ Panel='ScanningPanel';  ActiveStage=2; Busy=$true;  PrimaryKey='' }
            results   = @{ Panel='ResultsPanel';   ActiveStage=3; Busy=$false; PrimaryKey='BtnOpenReview' }
            review    = @{ Panel='ReviewPanel';    ActiveStage=3; Busy=$false; PrimaryKey='BtnExecute' }
            executing = @{ Panel='ExecutingPanel'; ActiveStage=3; Busy=$true;  PrimaryKey='' }
            completed = @{ Panel='CompletedPanel'; ActiveStage=4; Busy=$false; PrimaryKey='BtnRescan' }
            error     = @{ Panel='ErrorPanel';     ActiveStage=0; Busy=$false; PrimaryKey='BtnRetry' }
        }

        foreach ($state in @('idle','scanning','results','review','executing','completed','error')) {
            $definition = Get-GuiStateDefinition $state
            $definition.Panel | Should -Be $expected[$state].Panel -Because "$state Panel must match"
            $definition.ActiveStage | Should -Be $expected[$state].ActiveStage -Because "$state ActiveStage must match"
            $definition.Busy | Should -Be $expected[$state].Busy -Because "$state Busy must match"
            $definition.PrimaryKey | Should -Be $expected[$state].PrimaryKey -Because "$state PrimaryKey must match"
        }
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

    It 'returns zero counts for null and empty item collections' {
        $summaries = @(
            Get-GuiItemSummary -Items $null
            Get-GuiItemSummary -Items @()
        )

        foreach ($summary in $summaries) {
            $summary.executable | Should -Be 0
            $summary.observation | Should -Be 0
            $summary.total | Should -Be 0
        }
    }

    It 'counts the four review groups and formats their stable review summary' {
        $counts = Get-GuiReviewCounts @(
            [pscustomobject]@{ GroupKey='automatic' },
            [pscustomobject]@{ GroupKey='manual' },
            [pscustomobject]@{ GroupKey='manual' },
            [pscustomobject]@{ GroupKey='resolved' },
            [pscustomobject]@{ GroupKey='observation' },
            [pscustomobject]@{ GroupKey='observation' }
        )

        $counts.automatic | Should -Be 1
        $counts.manual | Should -Be 2
        $counts.resolved | Should -Be 1
        $counts.observation | Should -Be 2
        (Format-GuiReviewCountsText $counts) | Should -Be '建议清理 1 项 · 可选清理 2 项 · 已处理 1 项 · 仅观察 2 项'
    }

    It 'uses the approved recommendation labels for executable review groups' {
        $automatic = Get-GuiReviewPresentation -Branch actions -Name '自动项' -ExecutionClass automatic_safe -Necessity recommended -ImpactCn '低影响' -CleanupReasonCn '减少后台'
        $manual = Get-GuiReviewPresentation -Branch actions -Name '手动项' -ExecutionClass manual_impact -Necessity optional -ImpactCn '有功能影响' -CleanupReasonCn '按需处理'

        $automatic.GroupLabel | Should -BeExactly '建议清理'
        $manual.GroupLabel | Should -BeExactly '可选清理'
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

    It 'formats matcher provenance with platform newlines instead of literal escapes' {
        $raw = [pscustomobject]@{
            hit_type='service'; action='disable_service'; matched_field='service_name'
            matched_type='exact'; matched_pattern='ExactSvc'
        }
        $text = Format-GuiMatcherDetail $raw

        $text | Should -Match ([regex]::Escape([Environment]::NewLine))
        $text | Should -Not -Match ([regex]::Escape('`r`n'))
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

    It 'labels manual, running, and pending execution rows' {
        $rows = @(ConvertTo-GuiExecutionRows @(
            [pscustomobject]@{ name_cn='A'; action='disable_service'; status='manual_required'; reason_cn='manual' },
            [pscustomobject]@{ name_cn='B'; action='disable_task'; status='running'; reason_cn='running' },
            [pscustomobject]@{ name_cn='C'; action='remove_autostart'; status='pending'; reason_cn='pending' }
        ))

        $rows[0].StateLabel | Should -Be '需要手动处理'
        $rows[1].StateLabel | Should -Be '执行中'
        $rows[2].StateLabel | Should -Be '等待执行'
    }

    It '逐项展示终态目标、结果和经验证的 result_reason' {
        $rows = @(ConvertTo-GuiExecutionRows @(
            [pscustomobject]@{ name_cn='服务 A'; action='disable_service'; status='success'; result_reason='服务已停止'; reason_cn='不应显示的旧原因' },
            [pscustomobject]@{ name_cn='服务 B'; action='stop_service_process'; status='failed'; result_reason='当前实例已结束，但服务已自动重新拉起 PID 4321'; failure_stage='verification'; reason_cn='失败' },
            [pscustomobject]@{ name_cn='服务 C'; action='disable_task'; status='skipped'; result_reason='目标状态已变化，请重新扫描' },
            [pscustomobject]@{ name_cn='项目 D'; action='uninstall'; status='manual_required'; result_reason='请在应用设置中手动卸载' }
        ))

        @($rows.Name) | Should -Be @('服务 A','服务 B','服务 C','项目 D')
        @($rows.StateLabel) | Should -Be @('成功','失败','已跳过','需要手动处理')
        $rows[0].Reason | Should -BeExactly '服务已停止'
        $rows[1].Reason | Should -BeExactly '当前实例已结束，但服务已自动重新拉起 PID 4321'
        $rows[1].Reason | Should -Not -BeExactly '失败'
        $rows[1].FailureStage | Should -BeExactly 'verification'
        $rows[1].FailureStageLabel | Should -BeExactly '失败阶段：结果复核'
    }

    It '按可信动作类型生成非空且精确区分的 TargetLabel' {
        $rows = @(ConvertTo-GuiExecutionRows @(
            [pscustomobject]@{ name_cn='服务规则'; hit_type='service'; service_name='Svc.One'; action='disable_service'; status='success'; result_reason='完成' },
            [pscustomobject]@{ name_cn='服务规则'; hit_type='service'; service_name='Svc.Two'; action='disable_service'; status='success'; result_reason='完成' },
            [pscustomobject]@{ name_cn='任务规则'; hit_type='task'; task_path='\Vendor\Task One'; action='disable_task'; status='success'; result_reason='完成' },
            [pscustomobject]@{ name_cn='任务规则'; hit_type='task'; task_path='\Vendor\Task Two'; action='disable_task'; status='success'; result_reason='完成' },
            [pscustomobject]@{ name_cn='启动项'; hit_type='autostart'; autostart_source='HKCU Run'; autostart_name='MouseAgent'; action='remove_autostart'; status='success'; result_reason='完成' },
            [pscustomobject]@{ name_cn='进程'; hit_type='process'; process_name='mouse.exe'; process_id=4321; action='investigate'; status='success'; result_reason='完成' }
        ))

        @($rows.TargetLabel) | Should -Be @('Svc.One','Svc.Two','\Vendor\Task One','\Vendor\Task Two','HKCU Run / MouseAgent','mouse.exe（PID 4321）')
        @($rows.TargetLabel | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
    }

    It '为所有合法失败阶段提供友好中文' -ForEach @(
        @{ Stage='authorization'; Label='权限授权' }
        @{ Stage='backup'; Label='安全备份' }
        @{ Stage='mutation'; Label='系统修改' }
        @{ Stage='verification'; Label='结果复核' }
        @{ Stage='result_persistence'; Label='结果保存' }
    ) {
        $row = @(ConvertTo-GuiExecutionRows @([pscustomobject]@{
            name_cn='目标'; action='disable_service'; status='failed'
            result_reason='安全失败说明'; failure_stage=$Stage
        }))[0]

        $row.FailureStageLabel | Should -BeExactly ("失败阶段：$Label")
    }

    It 'presents limited scan health as a warning and never as a clean empty state' {
        $presentation = Get-GuiScanHealthPresentation -ScanHealth ([pscustomobject]@{
            system_info='complete'
            services='degraded'
            tasks='unavailable'
        }) -Warnings @() -Language zh

        $presentation.Degraded | Should -BeTrue
        $presentation.CanDeclareClean | Should -BeFalse
        $presentation.StatusKey | Should -Be 'ResultStatusDegraded'
        $presentation.EmptyHeadlineKey | Should -Be 'ResultHeadlineDegraded'
        ($presentation.Warnings -join "`n") | Should -Match '不能判断电脑是否干净'
        $presentation.EmptyHeadlineKey | Should -Not -Be 'ResultHeadlineEmpty'
    }

    It 'fails closed when scan health is missing null or not a structured object' -ForEach @(
        @{ Health=$null; Name='null' }
        @{ Health='complete'; Name='scalar string' }
        @{ Health=@('complete'); Name='array' }
        @{ Health=[pscustomobject]@{system_info='complete';services='complete'}; Name='missing category' }
    ) {
        $presentation = Get-GuiScanHealthPresentation -ScanHealth $Health -Warnings @() -Language en

        $presentation.Degraded | Should -BeTrue -Because $Name
        $presentation.CanDeclareClean | Should -BeFalse -Because $Name
        $presentation.EmptyHeadlineKey | Should -Be 'ResultHeadlineDegraded' -Because $Name
    }
}
