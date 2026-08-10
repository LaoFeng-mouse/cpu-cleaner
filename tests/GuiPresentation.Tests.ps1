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
