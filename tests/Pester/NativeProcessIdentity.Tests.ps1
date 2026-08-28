Describe 'native read-only process identity helper' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        . (Join-Path $projectRoot 'src\Core\Utils.ps1')
        foreach ($name in @('Get-NativeProcessIdentity','Invoke-NativeOpenProcessQueryLimited','Invoke-NativeQueryFullProcessImageName','Invoke-NativeGetProcessCreationTimeFileTime','Invoke-NativeCloseProcessHandle')) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                Set-Item -Path ("Function:" + $name) -Value { param($Value) return $null }
            }
        }
        $script:nativePath = Join-Path $TestDrive 'wsctrl11.exe'
        [System.IO.File]::WriteAllBytes($script:nativePath, [byte[]](1))
        $script:nativeFileTime = ([datetime]::ParseExact('2026-08-24T01:02:03.1234567Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToFileTimeUtc()
        Mock Invoke-NativeOpenProcessQueryLimited { [intptr]123 }
        Mock Invoke-NativeQueryFullProcessImageName { $script:nativePath }
        Mock Invoke-NativeGetProcessCreationTimeFileTime { [int64]$script:nativeFileTime }
        Mock Invoke-NativeCloseProcessHandle { $true }
    }

    It 'returns one strict canonical identity from a query-limited process handle' {
        $identity = Get-NativeProcessIdentity -ProcessId ([uint32]4321)

        @($identity.PSObject.Properties.Name) | Should -Be @('PID','Name','Path','StartTimeUtc')
        $identity.PID | Should -Be 4321
        $identity.Name | Should -BeExactly 'wsctrl11.exe'
        $identity.Path | Should -BeExactly $script:nativePath
        $identity.StartTimeUtc | Should -BeExactly '2026-08-24T01:02:03.1234567Z'
        Should -Invoke Invoke-NativeOpenProcessQueryLimited -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 4321 }
        Should -Invoke Invoke-NativeCloseProcessHandle -Times 1 -Exactly -ParameterFilter { $Handle -eq [intptr]123 }
    }

    It 'initializes the native API idempotently across repeated calls' {
        { Initialize-NativeProcessIdentityApi; Initialize-NativeProcessIdentityApi } | Should -Not -Throw
        ('ShushuCleaner.ProcessIdentityNativeV1' -as [type]) | Should -Not -BeNullOrEmpty
    }

    It 'closes the handle and returns null when any native identity field fails' -TestCases @(
        @{ Stage='path'; Path=$null; FileTime=0 }
        @{ Stage='time'; Path='valid'; FileTime=0 }
    ) {
        param($Stage, $Path, $FileTime)
        if ($Stage -ceq 'path') { Mock Invoke-NativeQueryFullProcessImageName { $null } }
        if ($Stage -ceq 'time') { Mock Invoke-NativeGetProcessCreationTimeFileTime { [int64]0 } }

        Get-NativeProcessIdentity -ProcessId 4321 | Should -BeNullOrEmpty

        Should -Invoke Invoke-NativeCloseProcessHandle -Times 1 -Exactly -ParameterFilter { $Handle -eq [intptr]123 }
    }

    It 'fails before opening a handle for a non-Int32-safe PID' {
        Get-NativeProcessIdentity -ProcessId ([uint64][int]::MaxValue + 1) | Should -BeNullOrEmpty

        Should -Invoke Invoke-NativeOpenProcessQueryLimited -Times 0 -Exactly
        Should -Invoke Invoke-NativeCloseProcessHandle -Times 0 -Exactly
    }
}

Describe 'WMI and native process start precision reconciliation' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        . (Join-Path $projectRoot 'src\Core\Utils.ps1')
    }

    It 'accepts only canonical UTC values in the same WMI microsecond' {
        Test-WmiNativeProcessStartTimeEqual `
            -WmiStartTimeUtc '2026-08-25T01:51:29.5408150Z' `
            -NativeStartTimeUtc '2026-08-25T01:51:29.5408156Z' | Should -BeTrue
    }

    It 'rejects the next WMI microsecond' {
        Test-WmiNativeProcessStartTimeEqual `
            -WmiStartTimeUtc '2026-08-25T01:51:29.5408150Z' `
            -NativeStartTimeUtc '2026-08-25T01:51:29.5408160Z' | Should -BeFalse
    }

    It 'rejects invalid, noncanonical, and future values' -TestCases @(
        @{ Wmi='invalid'; Native='2026-08-25T01:51:29.5408156Z'; Label='invalid WMI value' }
        @{ Wmi='2026-08-25T01:51:29.540815Z'; Native='2026-08-25T01:51:29.5408156Z'; Label='six-digit WMI value' }
        @{ Wmi='2026-08-25T01:51:29.5408150+00:00'; Native='2026-08-25T01:51:29.5408156Z'; Label='offset WMI value' }
        @{ Wmi='2026-08-25T01:51:29.5408150Z'; Native='2026-08-25T01:51:29.5408156'; Label='non-UTC native value' }
        @{ Wmi='2999-01-01T00:00:00.0000000Z'; Native='2999-01-01T00:00:00.0000006Z'; Label='future values' }
    ) {
        param($Wmi, $Native, $Label)

        Test-WmiNativeProcessStartTimeEqual -WmiStartTimeUtc $Wmi -NativeStartTimeUtc $Native |
            Should -BeFalse -Because $Label
    }
}
