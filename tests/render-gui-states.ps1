param(
    [ValidateSet(1.0,1.25,1.5)][double]$Scale = 1.0,
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
$env:SHUSHU_CLEANER_TEST = '1'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'gui-cleaner.ps1')

$window = $script:TestWindow
$script:Lang = 'zh'
$window.ShowInTaskbar = $false
$window.Left = -32000
$window.Top = -32000
$window.Show()
$scaleLabel = [string][int]($Scale * 100)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot ("artifacts\gui-states\$scaleLabel")
}
[void][System.IO.Directory]::CreateDirectory($OutputRoot)

$reviewRows = @(
    [pscustomobject]@{
        IsChecked=$true; CanExecute=$true; name_cn='Exact safe service'; action_label='disable service';
        reason_cn='Tested and reversible'; matcher_detail="field: service_name`r`ntype: exact`r`npattern: ExactService"
    },
    [pscustomobject]@{
        IsChecked=$false; CanExecute=$false; name_cn='Broad-match observation'; action_label='observe only';
        reason_cn='Broad matches cannot execute automatically'; matcher_detail="field: service_name`r`ntype: contains`r`npattern: Lenovo"
    }
)
$executionRows = @(
    [pscustomobject]@{ Name='Safe service'; State='success'; StateLabel='success - Safe service' },
    [pscustomobject]@{ Name='Scheduled task'; State='failed'; StateLabel='failed - Scheduled task' },
    [pscustomobject]@{ Name='Startup item'; State='skipped'; StateLabel='skipped - Startup item' }
)

function Save-WindowPng {
    param([Parameter(Mandatory=$true)][string]$Path)
    $logicalWidth = 1040
    $logicalHeight = 760
    $pixelWidth = [int]($logicalWidth * $Scale)
    $pixelHeight = [int]($logicalHeight * $Scale)
    $window.Width = $logicalWidth
    $window.Height = $logicalHeight
    $window.Measure([System.Windows.Size]::new($logicalWidth,$logicalHeight))
    $window.Arrange([System.Windows.Rect]::new(0,0,$logicalWidth,$logicalHeight))
    $window.UpdateLayout()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $pixelWidth,$pixelHeight,96*$Scale,96*$Scale,[System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($window)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

foreach ($state in Get-GuiStateNames) {
    $window.FindName('ScanProgress').IsIndeterminate = $true
    $window.FindName('ScanPhaseText').Text = Get-Text 'ScanPhaseServices'
    $window.FindName('ScanOutput').Text = "system information`r`nprocess scan`r`nservice scan"
    Set-GuiResultSummary -Executable 2 -Observation 4 -Evidence @('Exact safe service | exact | ExactService', 'Broad-match observation | contains | Lenovo')
    $window.FindName('PendingList').ItemsSource = $reviewRows
    $window.FindName('ExecutionList').ItemsSource = $executionRows
    $window.FindName('CompletedList').ItemsSource = $executionRows
    Set-GuiCompletedSummary -Success 1 -Failed 1 -Skipped 1 -Manual 0
    $window.FindName('ErrorSummaryText').Text = (Get-Text 'ScanErrorSummary') -f 'fixture error'
    $window.FindName('ErrorMutationText').Text = Get-Text 'ScanNoMutation'
    $window.FindName('ErrorDetailText').Text = 'fixture_error: deterministic visual state'
    Set-GuiState -Name $state -Force
    Apply-Language
    Save-WindowPng -Path (Join-Path $OutputRoot "$state.png")
}

$window.Close()

$files = @(Get-GuiStateNames | ForEach-Object { Get-Item -LiteralPath (Join-Path $OutputRoot "$_.png") })
if ($files.Count -ne 7 -or @($files | Where-Object Length -le 0).Count -gt 0) {
    throw "Visual rendering did not produce seven non-empty PNG files in $OutputRoot"
}
[pscustomobject]@{ Scale=$Scale; OutputRoot=$OutputRoot; Files=$files.Count }
