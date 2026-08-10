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

    It 'matches the full approved transition matrix' {
        $states = @('idle','scanning','results','review','executing','completed','error')
        $approved = @{
            idle      = @('scanning')
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
            results   = @{ Panel='ResultsPanel';   ActiveStage=2; Busy=$false; PrimaryKey='BtnOpenReview' }
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
}
