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

    function New-TestRegistryKey {
        param(
            [string[]]$SubKeyNames = @(),
            [hashtable]$SubKeys = @{},
            [hashtable]$Values = @{},
            [string]$ThrowOnValueName = ''
        )

        $key = [pscustomobject]@{
            SubKeyNames = @($SubKeyNames)
            SubKeys = $SubKeys
            Values = $Values
            ThrowOnValueName = $ThrowOnValueName
            GetSubKeyNamesCallCount = 0
            DisposeCallCount = 0
        }
        $key | Add-Member -MemberType ScriptMethod -Name GetSubKeyNames -Value {
            [void]($this.GetSubKeyNamesCallCount++)
            return @($this.SubKeyNames)
        }
        $key | Add-Member -MemberType ScriptMethod -Name OpenSubKey -Value {
            param($Name, $Writable)
            if ($this.SubKeys.ContainsKey($Name)) { return $this.SubKeys[$Name] }
            return $null
        }
        $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
            param($Name, $DefaultValue, $Options)
            if ($this.ThrowOnValueName -ceq $Name) { throw "failed to read $Name" }
            if ($this.Values.ContainsKey($Name)) { return $this.Values[$Name] }
            return $DefaultValue
        }
        $key | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            [void]($this.DisposeCallCount++)
        }
        return $key
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

    It 'maps Registry64 and Registry32 values to the two approved source path forms exactly once' {
        $values64 = @{
            DisplayName = '联想电脑管家 6.0'
            Publisher = 'Lenovo (Beijing) Limited'
            DisplayVersion = '6.0.1'
            InstallLocation = 'C:\Program Files\Lenovo\PCManager\6.0'
            UninstallString = '"C:\Program Files\Lenovo\PCManager\6.0\uninst.exe"'
        }
        $values32 = @{
            DisplayName = '联想电脑管家 5.1'
            Publisher = '联想（北京）有限公司'
            DisplayVersion = '5.1.0'
            InstallLocation = 'C:\Program Files (x86)\Lenovo\PCManager\5.1'
            UninstallString = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
        }
        $child64 = New-TestRegistryKey -Values $values64
        $child32 = New-TestRegistryKey -Values $values32
        $uninstall64 = New-TestRegistryKey -SubKeyNames @('Lenovo64') -SubKeys @{ Lenovo64 = $child64 }
        $uninstall32 = New-TestRegistryKey -SubKeyNames @('Lenovo32') -SubKeys @{ Lenovo32 = $child32 }
        $relativePath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $base64 = New-TestRegistryKey -SubKeys @{ $relativePath = $uninstall64 }
        $base32 = New-TestRegistryKey -SubKeys @{ $relativePath = $uninstall32 }
        $openedViews = [System.Collections.ArrayList]::new()
        $openBaseKey = {
            param($View)
            [void]$openedViews.Add($View.ToString())
            if ($View -eq [Microsoft.Win32.RegistryView]::Registry64) { return $base64 }
            if ($View -eq [Microsoft.Win32.RegistryView]::Registry32) { return $base32 }
            throw "unexpected registry view $View"
        }.GetNewClosure()

        $items = @(Read-LenovoOfficialUninstallRegistryItems -OpenBaseKey $openBaseKey)

        @($openedViews) | Should -Be @(
            'Registry64',
            'Registry32'
        )
        $items.Count | Should -Be 2
        $items[0].RegistryPath | Should -BeExactly 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Lenovo64'
        $items[0].DisplayName | Should -BeExactly $values64.DisplayName
        $items[0].Publisher | Should -BeExactly $values64.Publisher
        $items[0].DisplayVersion | Should -BeExactly $values64.DisplayVersion
        $items[0].InstallLocation | Should -BeExactly $values64.InstallLocation
        $items[0].UninstallString | Should -BeExactly $values64.UninstallString
        $items[1].RegistryPath | Should -BeExactly 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Lenovo32'
        $items[1].DisplayName | Should -BeExactly $values32.DisplayName
        $uninstall64.GetSubKeyNamesCallCount | Should -Be 1
        $uninstall32.GetSubKeyNamesCallCount | Should -Be 1
        foreach ($key in @($child64, $child32, $uninstall64, $uninstall32, $base64, $base32)) {
            $key.DisposeCallCount | Should -Be 1
        }
    }

    It 'preserves registry value arrays for strict scalar rejection' {
        $arrayValue = @('5.1.0', '5.2.0')
        $child = New-TestRegistryKey -Values @{
            DisplayName = '联想电脑管家'
            Publisher = '联想(北京)有限公司'
            DisplayVersion = $arrayValue
            InstallLocation = 'C:\Lenovo'
            UninstallString = 'C:\Lenovo\uninst.exe'
        }
        $uninstall = New-TestRegistryKey -SubKeyNames @('Lenovo') -SubKeys @{ Lenovo = $child }
        $relativePath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $base64 = New-TestRegistryKey -SubKeys @{ $relativePath = $uninstall }
        $empty32 = New-TestRegistryKey
        $openBaseKey = {
            param($View)
            if ($View -eq [Microsoft.Win32.RegistryView]::Registry64) { return $base64 }
            return $empty32
        }.GetNewClosure()

        $items = @(Read-LenovoOfficialUninstallRegistryItems -OpenBaseKey $openBaseKey)

        @($items[0].DisplayVersion) | Should -Be $arrayValue
    }

    It 'throws after disposing opened keys when registry value reading fails' {
        $child = New-TestRegistryKey -Values @{ DisplayName = '联想电脑管家' } -ThrowOnValueName 'Publisher'
        $uninstall = New-TestRegistryKey -SubKeyNames @('Lenovo') -SubKeys @{ Lenovo = $child }
        $relativePath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        $base64 = New-TestRegistryKey -SubKeys @{ $relativePath = $uninstall }
        $openBaseKey = { param($View) return $base64 }.GetNewClosure()

        { Read-LenovoOfficialUninstallRegistryItems -OpenBaseKey $openBaseKey } |
            Should -Throw '*failed to read Publisher*'

        $child.DisposeCallCount | Should -Be 1
        $uninstall.DisposeCallCount | Should -Be 1
        $base64.DisposeCallCount | Should -Be 1
    }

    It 'returns unavailable for malformed registry item <Label>' -TestCases @(
        @{ Label = 'wrong hive'; Changes = @{ RegistryPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager' } }
        @{ Label = 'wrong HKLM root'; Changes = @{ RegistryPath = 'HKLM:\SOFTWARE\Lenovo\Uninstall\LenovoPcManager' } }
        @{ Label = 'empty source key'; Changes = @{ RegistryPath = '' } }
        @{ Label = 'array source key'; Changes = @{ RegistryPath = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\A', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\B') } }
        @{ Label = 'wrong display name'; Changes = @{ DisplayName = 'Lenovo PC Manager' } }
        @{ Label = 'array display name'; Changes = @{ DisplayName = @('联想电脑管家', '联想电脑管家 5.1') } }
        @{ Label = 'non-Lenovo publisher'; Changes = @{ Publisher = 'Lenovo Group Limited' } }
        @{ Label = 'publisher case drift'; Changes = @{ Publisher = 'lenovo (Beijing) Limited' } }
        @{ Label = 'array publisher'; Changes = @{ Publisher = @('联想（北京）有限公司', '联想(北京)有限公司') } }
        @{ Label = 'missing install location'; Changes = @{ InstallLocation = '' } }
        @{ Label = 'rootless install location'; Changes = @{ InstallLocation = 'Lenovo\PCManager\5.1' } }
        @{ Label = 'non-canonical install location'; Changes = @{ InstallLocation = 'C:\Program Files (x86)\Lenovo\PCManager\5.0\..\5.1' } }
        @{ Label = 'array install location'; Changes = @{ InstallLocation = @('C:\Lenovo', 'D:\Lenovo') } }
        @{ Label = 'array display version'; Changes = @{ DisplayVersion = @('5.1', '5.2') } }
        @{ Label = 'array uninstall string'; Changes = @{ UninstallString = @('C:\Lenovo\uninst.exe', 'D:\Lenovo\uninst.exe') } }
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

    It 'returns unavailable when install location is volume root <InstallLocation>' -TestCases @(
        @{ InstallLocation = 'C:\'; UninstallString = 'C:\uninst.exe' }
        @{ InstallLocation = 'D:\'; UninstallString = 'D:\uninst.exe' }
    ) {
        param($InstallLocation, $UninstallString)
        $item = New-LenovoUninstallRegistryItem `
            -InstallLocation $InstallLocation `
            -UninstallString $UninstallString
        $registryReader = { param($Paths) $item }.GetNewClosure()

        $result = Get-LenovoOfficialUninstallEvidence -RegistryReader $registryReader

        Assert-UnavailableLenovoUninstallEvidence -Result $result
    }

    It 'returns unavailable for malformed reader output <Label>' -TestCases @(
        @{ Label = 'null'; Output = $null }
        @{ Label = 'string'; Output = 'not a registry item' }
        @{ Label = 'integer'; Output = 42 }
        @{ Label = 'boolean'; Output = $true }
    ) {
        param($Label, $Output)
        $registryReader = { param($Paths) $Output }.GetNewClosure()

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
