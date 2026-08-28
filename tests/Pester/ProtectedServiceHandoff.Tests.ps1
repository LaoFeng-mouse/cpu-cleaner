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
    if (-not (Get-Command Get-LenovoOfficialUninstallEvidence -ErrorAction SilentlyContinue)) {
        function Get-LenovoOfficialUninstallEvidence { throw 'Get-LenovoOfficialUninstallEvidence is not implemented.' }
    }
    if (-not (Get-Command Initialize-ServiceProtectionNativeApi -ErrorAction SilentlyContinue)) {
        function Initialize-ServiceProtectionNativeApi { throw 'Initialize-ServiceProtectionNativeApi is not implemented.' }
    }

    function New-LenovoUninstallRegistryItem {
        param(
            [object]$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager',
            [object]$DisplayName = '联想电脑管家 5.1',
            [object]$Publisher = '联想（北京）有限公司',
            [object]$DisplayVersion = '5.1.0.0',
            [object]$InstallLocation = 'C:\Program Files (x86)\Lenovo\PCManager\5.1',
            [object]$UninstallString = '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe"'
        )

        [pscustomobject]@{
            RegistryPath = $RegistryPath
            DisplayName = $DisplayName
            Publisher = $Publisher
            DisplayVersion = $DisplayVersion
            InstallLocation = $InstallLocation
            UninstallString = $UninstallString
        }
    }

    function Assert-UnavailableLenovoUninstallEvidence {
        param([Parameter(Mandatory=$true)]$Result)

        @($Result.PSObject.Properties.Name) | Should -Be @(
            'UninstallEvidenceStatus',
            'UninstallRegistryPath',
            'UninstallDisplayName',
            'UninstallPublisher',
            'UninstallDisplayVersion',
            'UninstallInstallLocation',
            'UninstallString',
            'UninstallExecutablePath'
        )
        $Result.UninstallEvidenceStatus | Should -BeExactly 'unavailable'
        @($Result.PSObject.Properties.Value)[1..7] | Should -Be @('', '', '', '', '', '', '')
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
        @{ Label = 'wildcard asterisk'; Command = 'C:\Lenovo\*.exe' }
        @{ Label = 'wildcard question mark'; Command = 'C:\Lenovo\u?.exe' }
        @{ Label = 'bracket metacharacters'; Command = 'C:\Lenovo\u[1].exe' }
        @{ Label = 'Unicode control character'; Command = ("C:\Lenovo\u{0}.exe" -f [char]0x85) }
        @{ Label = 'less-than character'; Command = 'C:\Lenovo\a<b.exe' }
        @{ Label = 'greater-than character'; Command = 'C:\Lenovo\a>b.exe' }
        @{ Label = 'pipe character'; Command = 'C:\Lenovo\a|b.exe' }
        @{ Label = 'alternate data stream'; Command = 'C:\Lenovo\base.txt:payload.exe' }
        @{ Label = 'NT object-manager path'; Command = '\??\C:\Lenovo\uninst.exe' }
        @{ Label = 'forward slash path'; Command = 'C:/Lenovo/uninst.exe' }
    ) {
        param($Label, $Command)

        ConvertFrom-StrictOfficialUninstallString -Command $Command | Should -BeNullOrEmpty
    }
}

Describe 'strict Lenovo official uninstall registry discovery' {
    It 'returns the exact complete snapshot for accepted publisher <Publisher>' -TestCases @(
        @{ Publisher = '联想（北京）有限公司'; RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager' }
        @{ Publisher = '联想(北京)有限公司'; RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager' }
        @{ Publisher = 'Lenovo (Beijing) Limited'; RegistryPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager' }
    ) {
        param($Publisher, $RegistryPath)
        $item = New-LenovoUninstallRegistryItem -Publisher $Publisher -RegistryPath $RegistryPath -DisplayVersion ''
        $registryReader = { param($Paths) $item }.GetNewClosure()

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        @($result.PSObject.Properties.Name) | Should -Be @(
            'UninstallEvidenceStatus',
            'UninstallRegistryPath',
            'UninstallDisplayName',
            'UninstallPublisher',
            'UninstallDisplayVersion',
            'UninstallInstallLocation',
            'UninstallString',
            'UninstallExecutablePath'
        )
        $result.UninstallEvidenceStatus | Should -BeExactly 'complete'
        $result.UninstallRegistryPath | Should -BeExactly $RegistryPath
        $result.UninstallDisplayName | Should -BeExactly '联想电脑管家 5.1'
        $result.UninstallPublisher | Should -BeExactly $Publisher
        $result.UninstallDisplayVersion | Should -BeExactly ''
        $result.UninstallInstallLocation | Should -BeExactly 'C:\Program Files (x86)\Lenovo\PCManager\5.1'
        $result.UninstallString | Should -BeExactly '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe"'
        $result.UninstallExecutablePath | Should -BeExactly 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
    }

    It 'passes only the two exact HKLM uninstall wildcard paths to the injected reader' {
        $script:registryQueryPaths = $null
        $registryReader = { param($Paths) $script:registryQueryPaths = @($Paths); @() }

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        $script:registryQueryPaths | Should -Be @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'uses only the two exact HKLM uninstall wildcard paths in the production reader' {
        Mock Get-ItemProperty { @() }

        $result = Get-LenovoOfficialUninstallEvidence

        Assert-MockCalled Get-ItemProperty -Times 2 -Exactly -Scope It
        Assert-MockCalled Get-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -ceq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
        Assert-MockCalled Get-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -ceq 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }
        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'returns unavailable for malformed registry item <Label>' -TestCases @(
        @{ Label = 'wrong hive'; Changes = @{ RegistryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager' } }
        @{ Label = 'wrong HKLM root'; Changes = @{ RegistryPath = 'HKLM:\SOFTWARE\Lenovo\Uninstall\LenovoPcManager' } }
        @{ Label = 'empty source key'; Changes = @{ RegistryPath = '' } }
        @{ Label = 'array source key'; Changes = @{ RegistryPath = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\A', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\B') } }
        @{ Label = 'wrong display name'; Changes = @{ DisplayName = 'Lenovo PC Manager' } }
        @{ Label = 'non-Lenovo publisher'; Changes = @{ Publisher = 'Lenovo Group Limited' } }
        @{ Label = 'publisher case drift'; Changes = @{ Publisher = 'lenovo (Beijing) Limited' } }
        @{ Label = 'missing install location'; Changes = @{ InstallLocation = '' } }
        @{ Label = 'rootless install location'; Changes = @{ InstallLocation = 'Lenovo\PCManager\5.1' } }
        @{ Label = 'non-canonical install location'; Changes = @{ InstallLocation = 'C:\Program Files (x86)\Lenovo\PCManager\5.0\..\5.1' } }
        @{ Label = 'array display version'; Changes = @{ DisplayVersion = @('5.1', '5.2') } }
        @{ Label = 'executable outside install location'; Changes = @{ UninstallString = 'C:\Temp\uninst.exe' } }
        @{ Label = 'textual prefix without separator boundary'; Changes = @{ UninstallString = 'C:\Program Files (x86)\Lenovo\PCManager\5.10\uninst.exe' } }
        @{ Label = 'command arguments'; Changes = @{ UninstallString = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe /S' } }
        @{ Label = 'malformed uninstall string'; Changes = @{ UninstallString = '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe' } }
    ) {
        param($Label, $Changes)
        $parameters = @{}
        foreach ($key in $Changes.Keys) { $parameters[$key] = $Changes[$key] }
        $item = New-LenovoUninstallRegistryItem @parameters
        $registryReader = { param($Paths) $item }.GetNewClosure()

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'returns unavailable when the reader returns the same valid candidate twice' {
        $item = New-LenovoUninstallRegistryItem
        $registryReader = { param($Paths) $item, $item }.GetNewClosure()

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'returns unavailable when the reader returns multiple distinct valid candidates' {
        $first = New-LenovoUninstallRegistryItem
        $second = New-LenovoUninstallRegistryItem `
            -RegistryPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager2' `
            -DisplayName '联想电脑管家 5.2' `
            -DisplayVersion '5.2.0.0' `
            -InstallLocation 'D:\Lenovo\PCManager\5.2' `
            -UninstallString 'D:\Lenovo\PCManager\5.2\uninst.exe'
        $registryReader = { param($Paths) $first, $second }.GetNewClosure()

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'returns unavailable when the registry reader throws' {
        $registryReader = { param($Paths) throw 'registry unavailable' }

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        Assert-UnavailableLenovoUninstallEvidence -Result $result
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
