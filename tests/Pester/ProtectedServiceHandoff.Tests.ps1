BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $modulePath = Join-Path $projectRoot 'src\Core\ProtectedServiceHandoff.ps1'
    if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
        . $modulePath
    }

    if (-not (Get-Command Get-ServiceLaunchProtectedState -ErrorAction SilentlyContinue)) {
        function Get-ServiceLaunchProtectedState { throw 'Get-ServiceLaunchProtectedState is not implemented.' }
    }
    if (-not (Get-Command ConvertFrom-StrictOfficialUninstallString -ErrorAction SilentlyContinue)) {
        function ConvertFrom-StrictOfficialUninstallString { throw 'ConvertFrom-StrictOfficialUninstallString is not implemented.' }
    }
    if (-not (Get-Command Initialize-ServiceProtectionNativeApi -ErrorAction SilentlyContinue)) {
        function Initialize-ServiceProtectionNativeApi { throw 'Initialize-ServiceProtectionNativeApi is not implemented.' }
    }
}

Describe 'service LaunchProtected state normalization' {
    It 'returns complete with an integer level for native level <Level>' -TestCases @(
        @{ Level = 0 }
        @{ Level = 1 }
        @{ Level = 2 }
        @{ Level = 3 }
    ) {
        param($Level)
        $nativeQuery = { param($ServiceName) $Level }.GetNewClosure()

        $result = Get-ServiceLaunchProtectedState -ServiceName 'LenovoProtectionService' -NativeQuery $nativeQuery

        @($result.PSObject.Properties.Name) | Should -Be @('Status', 'Level')
        $result.Status | Should -BeExactly 'complete'
        $result.Level | Should -BeOfType ([int])
        $result.Level | Should -Be $Level
    }

    It 'passes only the requested service name to the injectable native boundary' {
        $script:queriedServiceName = $null
        $nativeQuery = { param($ServiceName) $script:queriedServiceName = $ServiceName; 2 }

        $result = Get-ServiceLaunchProtectedState -ServiceName 'LenovoProtectionService' -NativeQuery $nativeQuery

        $script:queriedServiceName | Should -BeExactly 'LenovoProtectionService'
        $result.Status | Should -BeExactly 'complete'
        $result.Level | Should -Be 2
    }

    It 'normalizes unavailable native result <Label> to unavailable/-1' -TestCases @(
        @{ Label = 'missing service'; Query = { param($ServiceName) $null } }
        @{ Label = 'access failure'; Query = { param($ServiceName) throw [System.UnauthorizedAccessException]::new('access denied') } }
        @{ Label = 'native exception'; Query = { param($ServiceName) throw [System.DllNotFoundException]::new('native API unavailable') } }
        @{ Label = 'negative level'; Query = { param($ServiceName) -1 } }
        @{ Label = 'array result'; Query = { param($ServiceName) 1, 2 } }
        @{ Label = 'level above maximum'; Query = { param($ServiceName) 4 } }
    ) {
        param($Label, $Query)

        $result = Get-ServiceLaunchProtectedState -ServiceName 'LenovoProtectionService' -NativeQuery $Query

        @($result.PSObject.Properties.Name) | Should -Be @('Status', 'Level')
        $result.Status | Should -BeExactly 'unavailable'
        $result.Level | Should -BeOfType ([int])
        $result.Level | Should -Be -1
    }

    It 'initializes the safe-handle native API idempotently without querying SCM' {
        { Initialize-ServiceProtectionNativeApi; Initialize-ServiceProtectionNativeApi } | Should -Not -Throw
        $nativeType = 'ShushuCleaner.ServiceProtectionNativeV1' -as [type]
        $nativeType | Should -Not -BeNullOrEmpty
        $nativeType.GetMethod('QueryLaunchProtected') | Should -Not -BeNullOrEmpty
    }
}

Describe 'strict official uninstall string parsing' {
    It 'accepts exact zero-argument rooted EXE command <Label>' -TestCases @(
        @{ Label = 'unquoted'; Command = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe' }
        @{ Label = 'quoted'; Command = '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe"' }
    ) {
        param($Label, $Command)

        ConvertFrom-StrictOfficialUninstallString -Command $Command |
            Should -BeExactly 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
    }

    It 'rejects non-exact or unsafe command <Label>' -TestCases @(
        @{ Label = 'arguments'; Command = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe /S' }
        @{ Label = 'msiexec'; Command = 'msiexec /x {00000000-0000-0000-0000-000000000000}' }
        @{ Label = 'cmd shell'; Command = 'cmd /c C:\Temp\uninst.exe' }
        @{ Label = 'PowerShell'; Command = 'powershell -File C:\Temp\uninstall.ps1' }
        @{ Label = 'Windows Script Host'; Command = 'wscript C:\Temp\uninstall.vbs' }
        @{ Label = 'environment variable'; Command = '%ProgramFiles%\Lenovo\uninst.exe' }
        @{ Label = 'relative traversal'; Command = '..\uninst.exe' }
        @{ Label = 'file URI'; Command = 'file:///C:/Lenovo/uninst.exe' }
        @{ Label = 'batch file'; Command = 'C:\Lenovo\uninstall.bat' }
        @{ Label = 'unclosed quote'; Command = '"C:\Lenovo\uninst.exe' }
        @{ Label = 'quoted trailing whitespace'; Command = '"C:\Lenovo\uninst.exe" ' }
        @{ Label = 'rooted command processor'; Command = 'C:\Windows\System32\cmd.exe' }
        @{ Label = 'UNC executable'; Command = '\\server\share\uninst.exe' }
    ) {
        param($Label, $Command)

        ConvertFrom-StrictOfficialUninstallString -Command $Command | Should -BeNullOrEmpty
    }
}

Describe 'ProtectedServiceHandoff module loading order' {
    It 'loads the module after Utils and before ProfileEngine in <Script>' -TestCases @(
        @{ Script = 'cpu-cleaner.ps1' }
        @{ Script = 'tests\run-unit.ps1' }
    ) {
        param($Script)
        $content = Get-Content -LiteralPath (Join-Path $projectRoot $Script) -Raw

        $content | Should -Match "'Utils','ProtectedServiceHandoff','ProfileEngine'"
    }

    It 'dot-sources the module before ProfileEngine in gui-cleaner.ps1' {
        $content = Get-Content -LiteralPath (Join-Path $projectRoot 'gui-cleaner.ps1') -Raw
        $handoffIndex = $content.IndexOf("src\Core\ProtectedServiceHandoff.ps1")
        $profileIndex = $content.IndexOf("src\Core\ProfileEngine.ps1")

        $handoffIndex | Should -BeGreaterOrEqual 0
        $profileIndex | Should -BeGreaterThan $handoffIndex
    }
}
