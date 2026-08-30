function New-TestSignerCertificate {
    param([Parameter(Mandatory=$true)][string]$Subject)
    [pscustomobject]@{
        SubjectName = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)
    }
}

BeforeAll {
    function New-TestRawX500OrganizationAttribute {
        param(
            [Parameter(Mandatory=$true)][byte]$ValueTag,
            [Parameter(Mandatory=$true)][string]$Organization
        )
        $encodedValue = switch ($ValueTag) {
            0x0C { [System.Text.UTF8Encoding]::new($false, $true).GetBytes($Organization) }
            0x13 { [System.Text.ASCIIEncoding]::new().GetBytes($Organization) }
            0x1E { [System.Text.UnicodeEncoding]::new($true, $false, $true).GetBytes($Organization) }
            default { throw "Unsupported value tag 0x$($ValueTag.ToString('X2'))" }
        }

        if ($encodedValue.Length -ge 128) { throw "Encoded value too long for this test helper: $($encodedValue.Length)" }
        $oid = [byte[]]@(
            0x06, 0x03, 0x55, 0x04, 0x0A
        )
        $value = [byte[]]@(
            $ValueTag, [byte]$encodedValue.Length
        ) + $encodedValue
        $attribute = [byte[]]@(
            0x30, [byte]($oid.Length + $value.Length)
        ) + $oid + $value
        $set = [byte[]]@(
            0x31, [byte]$attribute.Length
        ) + $attribute
        return [byte[]]([byte[]]@(
            0x30, [byte]$set.Length
        ) + $set
        )
    }

    function New-TestSignerCertificate {
        param([Parameter(Mandatory=$true)][string]$Subject)
        [pscustomobject]@{
            SubjectName = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Subject)
        }
    }

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
    if (-not (Get-Command Test-ReviewedLenovoUninstaller -ErrorAction SilentlyContinue)) {
        function Test-ReviewedLenovoUninstaller { throw 'Test-ReviewedLenovoUninstaller is not implemented.' }
    }
    if (-not (Get-Command Invoke-ReviewedLenovoUninstallerHandoff -ErrorAction SilentlyContinue)) {
        function Invoke-ReviewedLenovoUninstallerHandoff { throw 'Invoke-ReviewedLenovoUninstallerHandoff is not implemented.' }
    }
    if (-not (Get-Command Get-StableLenovoUninstallerFileSnapshot -ErrorAction SilentlyContinue)) {
        function Get-StableLenovoUninstallerFileSnapshot { throw 'Get-StableLenovoUninstallerFileSnapshot is not implemented.' }
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

    function New-ReviewedLenovoUninstallerAction {
        [pscustomobject][ordered]@{
            action = 'open_official_uninstaller'
            uninstall_evidence_status = 'complete'
            uninstall_registry_path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager'
            uninstall_display_name = '联想电脑管家 5.1'
            uninstall_publisher = '联想（北京）有限公司'
            uninstall_display_version = '5.1.0.0'
            uninstall_install_location = 'C:\Program Files (x86)\Lenovo\PCManager\5.1'
            uninstall_string = '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe"'
            uninstall_executable_path = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
        }
    }

    function New-StableUninstallerSnapshot {
        [pscustomobject][ordered]@{
            VolumeSerialNumber = [uint32]123
            FileIndexHigh = [uint32]456
            FileIndexLow = [uint32]789
            NumberOfLinks = [uint32]1
            Length = [int64]4096
            LastWriteTimeUtc = [datetime]'2026-08-28T01:02:03Z'
            FinalPath = 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
            Sha256 = '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
        }
    }

    function Copy-TestObject {
        param([Parameter(Mandatory=$true)]$InputObject)
        return $InputObject.PSObject.Copy()
    }

    function Assert-SkippedValidationResult {
        param([Parameter(Mandatory=$true)]$Result)
        @($Result.PSObject.Properties.Name) | Should -Be @('Status', 'ExecutablePath', 'Code')
        $Result.Status | Should -BeExactly 'skipped'
        $Result.ExecutablePath | Should -BeNullOrEmpty
        $Result.Code | Should -Match '^[a-z0-9_]+$'
        $Result.Code | Should -Not -Match '[\\/:\s]'
    }
}

Describe 'reviewed Lenovo official uninstaller launch-time validation' {
    It 'returns only the canonical executable when every launch-time binding is unchanged' {
        $action = New-ReviewedLenovoUninstallerAction
        $registryItem = New-LenovoUninstallRegistryItem
        $snapshot = New-StableUninstallerSnapshot
        $registryReader = { param($Paths) $registryItem }.GetNewClosure()
        $fileSnapshotReader = { param($Path) $snapshot }.GetNewClosure()
        $signatureReader = {
            param($Path)
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = New-TestSignerCertificate 'CN=Lenovo Setup, O=LENOVO (BEIJING) LIMITED, C=CN'
            }
        }

        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader $registryReader -FileSnapshotReader $fileSnapshotReader -SignatureReader $signatureReader

        @($result.PSObject.Properties.Name) | Should -Be @('Status', 'ExecutablePath', 'Code')
        $result.Status | Should -BeExactly 'validated' -Because "validation code was '$($result.Code)'"
        $result.ExecutablePath | Should -BeExactly 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
        $result.Code | Should -BeNullOrEmpty
    }

    It 'reads only the exact reviewed Lenovo uninstall subkey once during launch revalidation <Label>' -TestCases @(
        @{
            Label = 'Registry64';
            RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager';
            ExpectedView = [Microsoft.Win32.RegistryView]::Registry64;
            ExpectedSubKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager';
            ExpectedSourcePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager'
        },
        @{
            Label = 'Registry32';
            RegistryPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager';
            ExpectedView = [Microsoft.Win32.RegistryView]::Registry32;
            ExpectedSubKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager';
            ExpectedSourcePath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\LenovoPcManager'
        }
    ) {
        param($Label, $RegistryPath, $ExpectedView, $ExpectedSubKeyPath, $ExpectedSourcePath)
        $action = New-ReviewedLenovoUninstallerAction
        $action.uninstall_registry_path = $RegistryPath
        $item = New-LenovoUninstallRegistryItem
        $item.RegistryPath = $RegistryPath
        $snapshot = New-StableUninstallerSnapshot
        $exactRegistryCalls = [System.Collections.ArrayList]::new()
        $exactRegistryReader = {
            param($View, $SubKeyPath, $SourcePath)
            [void]$exactRegistryCalls.Add([pscustomobject]@{
                View = $View
                SubKeyPath = $SubKeyPath
                SourcePath = $SourcePath
            })
            return $item
        }.GetNewClosure()

        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader $exactRegistryReader `
            -FileSnapshotReader ({ param($Path) $snapshot }.GetNewClosure()) `
            -SignatureReader { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=联想（北京）有限公司')} }

        $result.Status | Should -BeExactly 'validated' -Because "validation code was '$($result.Code)'"
        @($exactRegistryCalls) | Should -HaveCount 1
        $exactRegistryCalls[0].View | Should -Be $ExpectedView
        $exactRegistryCalls[0].SubKeyPath | Should -BeExactly $ExpectedSubKeyPath
        $exactRegistryCalls[0].SourcePath | Should -BeExactly $ExpectedSourcePath
    }

    It 'rejects registry source missing or drift and every reviewed bound-field drift <Label>' -TestCases @(
        @{ Label='source missing'; Field='RegistryPath'; Value='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Other' }
        @{ Label='source case is path-equivalent'; Field='RegistryPath'; Value='hklm:\software\microsoft\windows\currentversion\uninstall\lenovopcmanager'; ExpectedValidated=$true }
        @{ Label='display name'; Field='DisplayName'; Value='联想电脑管家 5.2' }
        @{ Label='publisher'; Field='Publisher'; Value='Lenovo (Beijing) Limited' }
        @{ Label='version'; Field='DisplayVersion'; Value='5.1.0.1' }
        @{ Label='install location'; Field='InstallLocation'; Value='C:\Program Files (x86)\Lenovo\PCManager\5.2'; UninstallString='C:\Program Files (x86)\Lenovo\PCManager\5.2\uninst.exe' }
        @{ Label='uninstall string'; Field='UninstallString'; Value='C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe' }
    ) {
        param($Label, $Field, $Value, $UninstallString, $ExpectedValidated)
        $action = New-ReviewedLenovoUninstallerAction
        $parameters = @{}
        $parameters[$Field] = $Value
        if ($UninstallString) { $parameters.UninstallString = $UninstallString }
        $item = New-LenovoUninstallRegistryItem @parameters
        $snapshot = New-StableUninstallerSnapshot
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $item }.GetNewClosure()) `
            -FileSnapshotReader ({ param($Path) $snapshot }.GetNewClosure()) `
            -SignatureReader { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=联想（北京）有限公司')} }

        if ($ExpectedValidated) { $result.Status | Should -BeExactly 'validated' }
        else { Assert-SkippedValidationResult $result }
    }

    It 'rejects malformed current registry entries without using a fallback candidate' {
        $action = New-ReviewedLenovoUninstallerAction
        $malformed = New-LenovoUninstallRegistryItem -DisplayName @('联想电脑管家', '联想电脑管家 5.1')
        $fallback = New-LenovoUninstallRegistryItem `
            -RegistryPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\LenovoOther'
        $script:malformedFallbackFileCalls = 0
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $malformed, $fallback }.GetNewClosure()) `
            -FileSnapshotReader { $script:malformedFallbackFileCalls++; throw 'must not read file' } `
            -SignatureReader { throw 'must not read signature' }

        Assert-SkippedValidationResult $result
        $script:malformedFallbackFileCalls | Should -Be 0
    }

    It 'rejects malformed reviewed action scalar fields' {
        $action = New-ReviewedLenovoUninstallerAction
        $action.uninstall_executable_path = @($action.uninstall_executable_path)
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader { throw 'must not read registry' } -FileSnapshotReader { throw 'must not read file' } `
            -SignatureReader { throw 'must not read signature' }

        Assert-SkippedValidationResult $result
    }

    It 'rejects invalid stable snapshot data <Label>' -TestCases @(
        @{ Label='directory or malformed reader result'; Mutate={ param($s) $s.PSObject.Properties.Remove('Length') } }
        @{ Label='multiple hard links'; Mutate={ param($s) $s.NumberOfLinks=[uint32]2 } }
        @{ Label='resolved path outside reviewed root'; Mutate={ param($s) $s.FinalPath='C:\Windows\System32\notepad.exe' } }
        @{ Label='lower-case digest'; Mutate={ param($s) $s.Sha256=$s.Sha256.ToLowerInvariant() } }
    ) {
        param($Label, $Mutate)
        $action = New-ReviewedLenovoUninstallerAction
        $item = New-LenovoUninstallRegistryItem
        $snapshot = New-StableUninstallerSnapshot
        & $Mutate $snapshot
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $item }.GetNewClosure()) `
            -FileSnapshotReader ({ param($Path) $snapshot }.GetNewClosure()) `
            -SignatureReader { throw 'must not read signature' }

        Assert-SkippedValidationResult $result
    }

    It 'rejects pre/post file identity, metadata, final path, or SHA256 drift <Label>' -TestCases @(
        @{ Label='volume serial'; Field='VolumeSerialNumber'; Value=[uint32]124 }
        @{ Label='file index high'; Field='FileIndexHigh'; Value=[uint32]457 }
        @{ Label='file index low'; Field='FileIndexLow'; Value=[uint32]790 }
        @{ Label='length'; Field='Length'; Value=[int64]4097 }
        @{ Label='last write'; Field='LastWriteTimeUtc'; Value=[datetime]'2026-08-28T01:02:04Z' }
        @{ Label='final path'; Field='FinalPath'; Value='C:\Program Files (x86)\Lenovo\PCManager\5.1\other.exe' }
        @{ Label='SHA256'; Field='Sha256'; Value='1123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF' }
    ) {
        param($Label, $Field, $Value)
        $action = New-ReviewedLenovoUninstallerAction
        $item = New-LenovoUninstallRegistryItem
        $before = New-StableUninstallerSnapshot
        $after = Copy-TestObject $before
        $after.$Field = $Value
        $queue = [System.Collections.Queue]::new(); $queue.Enqueue($before); $queue.Enqueue($after)
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $item }.GetNewClosure()) `
            -FileSnapshotReader ({ param($Path) $queue.Dequeue() }.GetNewClosure()) `
            -SignatureReader { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=Lenovo (Beijing) Limited')} }

        Assert-SkippedValidationResult $result
    }

    It 'rejects invalid signature status, absent certificate, and non-O Lenovo text <Label>' -TestCases @(
        @{ Label='invalid status'; Signature=[pscustomobject]@{Status='NotSigned';SignerCertificate=(New-TestSignerCertificate 'O=Lenovo (Beijing) Limited')} }
        @{ Label='status case drift'; Signature=[pscustomobject]@{Status='valid';SignerCertificate=(New-TestSignerCertificate 'O=Lenovo (Beijing) Limited')} }
        @{ Label='absent certificate'; Signature=[pscustomobject]@{Status='Valid';SignerCertificate=$null} }
        @{ Label='wrong organization'; Signature=[pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=Lenovo Group Limited')} }
        @{ Label='Lenovo only in OU'; Signature=[pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'OU=Lenovo (Beijing) Limited, O=Other Company')} }
        @{ Label='Lenovo only in CN'; Signature=[pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'CN=LENOVO (BEIJING) LIMITED, O=Other Company')} }
    ) {
        param($Label, $Signature)
        $action = New-ReviewedLenovoUninstallerAction
        $item = New-LenovoUninstallRegistryItem
        $snapshot = New-StableUninstallerSnapshot
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $item }.GetNewClosure()) `
            -FileSnapshotReader ({ param($Path) $snapshot }.GetNewClosure()) `
            -SignatureReader ({ param($Path) $Signature }.GetNewClosure())

        Assert-SkippedValidationResult $result
    }

    It 'accepts only the exact allowed signer organization <Organization>' -TestCases @(
        @{ Organization='LENOVO (BEIJING) LIMITED' }
        @{ Organization='lenovo (beijing) limited' }
        @{ Organization=' Lenovo (Beijing) Limited ' }
        @{ Organization='联想（北京）有限公司' }
    ) {
        param($Organization)
        $action = New-ReviewedLenovoUninstallerAction
        $item = New-LenovoUninstallRegistryItem
        $snapshot = New-StableUninstallerSnapshot
        $signature = [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate "CN=Setup, O=$Organization, C=CN")}
        $result = Test-ReviewedLenovoUninstaller -Action $action `
            -RegistryReader ({ param($Paths) $item }.GetNewClosure()) `
            -FileSnapshotReader ({ param($Path) $snapshot }.GetNewClosure()) `
            -SignatureReader ({ param($Path) $signature }.GetNewClosure())
        $result.Status | Should -BeExactly 'validated'
    }

    It 'accepts explicit UTF8String Organization after DER extraction <Organization>' -TestCases @(
        @{ Organization = 'Lenovo (Beijing) Limited' }
        @{ Organization = '联想（北京）有限公司' }
    ) {
        param($Organization)
        $certificate = [pscustomobject]@{
            SubjectName = [pscustomobject]@{ RawData = New-TestRawX500OrganizationAttribute -ValueTag 0x0C -Organization $Organization }
        }
        Test-LenovoSignerOrganization $certificate | Should -BeTrue
    }

    It 'accepts explicit PrintableString Organization after DER extraction <Organization>' -TestCases @(
        @{ Organization = 'LENOVO (BEIJING) LIMITED' }
    ) {
        param($Organization)
        $certificate = [pscustomobject]@{
            SubjectName = [pscustomobject]@{ RawData = New-TestRawX500OrganizationAttribute -ValueTag 0x13 -Organization $Organization }
        }
        Test-LenovoSignerOrganization $certificate | Should -BeTrue
    }

    It 'accepts explicit BMPString Organization after DER extraction <Organization>' -TestCases @(
        @{ Organization = '联想（北京）有限公司' }
    ) {
        param($Organization)
        $certificate = [pscustomobject]@{
            SubjectName = [pscustomobject]@{ RawData = New-TestRawX500OrganizationAttribute -ValueTag 0x1E -Organization $Organization }
        }
        Test-LenovoSignerOrganization $certificate | Should -BeTrue
    }

    It 'rejects formatted subject text when encoded SubjectName evidence is absent' {
        Test-LenovoSignerOrganization ([pscustomobject]@{
            Subject = 'O=Lenovo (Beijing) Limited'
        }) | Should -BeFalse
    }

    It 'rejects duplicate encoded Organization attributes' {
        $certificate = New-TestSignerCertificate 'O=Lenovo (Beijing) Limited, O=Lenovo (Beijing) Limited'
        Test-LenovoSignerOrganization $certificate | Should -BeFalse
    }

    It 'rejects malformed or unsupported encoded SubjectName DER <Label>' -TestCases @(
        @{ Label='indefinite length'; Raw=[byte[]](0x30,0x80,0x00,0x00) }
        @{ Label='truncated long length'; Raw=[byte[]](0x30,0x82,0x01) }
        @{ Label='non-minimal long length'; Raw=[byte[]](0x30,0x81,0x01,0x00) }
        @{ Label='unsupported Organization string type'; Raw=[byte[]](0x30,0x0C,0x31,0x0A,0x30,0x08,0x06,0x03,0x55,0x04,0x0A,0x16,0x01,0x41) }
    ) {
        param($Label, $Raw)
        $certificate = [pscustomobject]@{
            SubjectName = [pscustomobject]@{ RawData = $Raw }
        }
        Test-LenovoSignerOrganization $certificate | Should -BeFalse
    }

    It 'rejects oversized SubjectName raw bytes' {
        $certificate = [pscustomobject]@{
            SubjectName = [pscustomobject]@{ RawData = [byte[]]::new(16385) }
        }
        Test-LenovoSignerOrganization $certificate | Should -BeFalse
    }

    It 'rejects exceptions from boundary <Label>' -TestCases @(
        @{ Label='registry'; Registry={ throw 'secret registry path C:\private' }; File={ throw 'must not run' }; Signature={ throw 'must not run' } }
        @{ Label='first file snapshot'; Registry=$null; File={ throw 'secret file C:\private' }; Signature={ throw 'must not run' } }
        @{ Label='signature'; Registry=$null; File=$null; Signature={ throw 'secret certificate details' } }
        @{ Label='post-signature file snapshot'; Registry=$null; File='post'; Signature=$null }
    ) {
        param($Label, $Registry, $File, $Signature)
        $action = New-ReviewedLenovoUninstallerAction
        $item = New-LenovoUninstallRegistryItem
        $snapshot = New-StableUninstallerSnapshot
        if ($null -eq $Registry) { $Registry = { param($Paths) $item }.GetNewClosure() }
        if ($File -ceq 'post') {
            $calls=0; $File={ param($Path) $script:calls++; if($script:calls -eq 1){$snapshot}else{throw 'secret post snapshot'} }.GetNewClosure()
        } elseif ($null -eq $File) { $File = { param($Path) $snapshot }.GetNewClosure() }
        if ($null -eq $Signature) { $Signature = { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=联想（北京）有限公司')} } }

        $result = Test-ReviewedLenovoUninstaller -Action $action -RegistryReader $Registry -FileSnapshotReader $File -SignatureReader $Signature

        Assert-SkippedValidationResult $result
    }
}

Describe 'reviewed Lenovo official uninstaller handoff' {
    BeforeEach {
        $script:handoffAction = New-ReviewedLenovoUninstallerAction
        $script:handoffItem = New-LenovoUninstallRegistryItem
        $script:handoffSnapshot = New-StableUninstallerSnapshot
        $script:handoffRegistry = { param($Paths) $script:handoffItem }
        $script:handoffFile = { param($Path) $script:handoffSnapshot }
        $script:handoffSignature = { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=联想（北京）有限公司')} }
    }

    It 'opens only the validated canonical path after a third immediate stable snapshot' {
        $script:fileSnapshotCalls = 0
        $fileReader = { param($Path) $script:fileSnapshotCalls++; $script:handoffSnapshot }
        $script:launchedPath = ''
        $launcher = { param($Path) $script:launchedPath=$Path; [pscustomobject]@{Id=1234} }

        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $script:handoffRegistry -FileSnapshotReader $fileReader `
            -SignatureReader $script:handoffSignature -Launcher $launcher

        $script:fileSnapshotCalls | Should -Be 3
        $script:launchedPath | Should -BeExactly $script:handoffSnapshot.FinalPath
        @($result.PSObject.Properties.Name) | Should -Be @('status','result_reason','failure_stage')
        $result.status | Should -BeExactly 'manual_required'
        $result.result_reason | Should -BeExactly '联想官方卸载程序已打开，请在其中确认或取消'
        $result.failure_stage | Should -BeNullOrEmpty
    }

    It 'never calls launcher when final immediate snapshot changed' {
        $changed = Copy-TestObject $script:handoffSnapshot; $changed.Sha256='1123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
        $queue=[System.Collections.Queue]::new(); $queue.Enqueue($script:handoffSnapshot); $queue.Enqueue($script:handoffSnapshot); $queue.Enqueue($changed)
        $script:launcherCalls=0
        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $script:handoffRegistry -FileSnapshotReader ({param($Path)$queue.Dequeue()}.GetNewClosure()) `
            -SignatureReader $script:handoffSignature -Launcher {param($Path)$script:launcherCalls++}

        $script:launcherCalls | Should -Be 0
        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -BeExactly '启动前安全复核失败，请重新扫描后再试'
        $result.failure_stage | Should -BeNullOrEmpty
    }

    It 'never calls launcher for a validation-boundary rejection <Label>' -TestCases @(
        @{ Label='registry reader'; Registry={throw 'registry secret'}; File=$null; Signature=$null }
        @{ Label='file snapshot reader'; Registry=$null; File={throw 'file secret'}; Signature=$null }
        @{ Label='signature reader'; Registry=$null; File=$null; Signature={throw 'signature secret'} }
    ) {
        param($Label, $Registry, $File, $Signature)
        if ($null -eq $Registry) { $Registry=$script:handoffRegistry }
        if ($null -eq $File) { $File=$script:handoffFile }
        if ($null -eq $Signature) { $Signature=$script:handoffSignature }
        $script:rejectedLauncherCalls=0

        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $Registry -FileSnapshotReader $File -SignatureReader $Signature `
            -Launcher {param($Path)$script:rejectedLauncherCalls++}

        $script:rejectedLauncherCalls | Should -Be 0
        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -BeExactly '启动前安全复核失败，请重新扫描后再试'
        $result.failure_stage | Should -BeNullOrEmpty
    }

    It 'keeps launcher count zero across the complete security rejection matrix <Label>' -TestCases @(
        @{ Label='malformed reviewed action'; Mode='action' }
        @{ Label='registry binding drift'; Mode='registry_drift' }
        @{ Label='invalid initial file snapshot'; Mode='snapshot_invalid' }
        @{ Label='pre post file identity drift'; Mode='file_drift' }
        @{ Label='invalid Authenticode status'; Mode='signature_invalid' }
        @{ Label='missing signer certificate'; Mode='certificate_missing' }
        @{ Label='wrong encoded signer organization'; Mode='organization_invalid' }
        @{ Label='registry boundary exception'; Mode='registry_exception' }
        @{ Label='file boundary exception'; Mode='file_exception' }
        @{ Label='signature boundary exception'; Mode='signature_exception' }
        @{ Label='final immediate snapshot mismatch'; Mode='final_mismatch' }
        @{ Label='final immediate snapshot exception'; Mode='final_exception' }
    ) {
        param($Label, $Mode)
        $action = New-ReviewedLenovoUninstallerAction
        $script:matrixItem = New-LenovoUninstallRegistryItem
        $script:matrixSnapshot = New-StableUninstallerSnapshot
        $script:matrixFileCalls = 0
        $registry = { param($View,$SubKeyPath,$SourcePath) $script:matrixItem }
        $file = { param($Path) $script:matrixFileCalls++; $script:matrixSnapshot }
        $signature = { param($Path) [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=联想（北京）有限公司')} }

        switch ($Mode) {
            'action' { $action.uninstall_executable_path = @($action.uninstall_executable_path) }
            'registry_drift' { $script:matrixItem.DisplayName = '联想电脑管家 5.2' }
            'snapshot_invalid' { $script:matrixSnapshot.NumberOfLinks = [uint32]2 }
            'file_drift' {
                $changed = Copy-TestObject $script:matrixSnapshot
                $changed.Sha256 = '1123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
                $script:matrixQueue = [System.Collections.Queue]::new()
                $script:matrixQueue.Enqueue($script:matrixSnapshot); $script:matrixQueue.Enqueue($changed)
                $file = { param($Path) $script:matrixQueue.Dequeue() }
            }
            'signature_invalid' { $signature = { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} } }
            'certificate_missing' { $signature = { [pscustomobject]@{Status='Valid';SignerCertificate=$null} } }
            'organization_invalid' { $signature = { [pscustomobject]@{Status='Valid';SignerCertificate=(New-TestSignerCertificate 'O=Other Company')} } }
            'registry_exception' { $registry = { throw 'registry secret' } }
            'file_exception' { $file = { throw 'file secret' } }
            'signature_exception' { $signature = { throw 'signature secret' } }
            'final_mismatch' {
                $changed = Copy-TestObject $script:matrixSnapshot
                $changed.Length = [int64]4097
                $script:matrixQueue = [System.Collections.Queue]::new()
                $script:matrixQueue.Enqueue($script:matrixSnapshot); $script:matrixQueue.Enqueue($script:matrixSnapshot); $script:matrixQueue.Enqueue($changed)
                $file = { param($Path) $script:matrixQueue.Dequeue() }
            }
            'final_exception' {
                $file = { param($Path) $script:matrixFileCalls++; if ($script:matrixFileCalls -lt 3) { $script:matrixSnapshot } else { throw 'final secret' } }
            }
        }

        $script:matrixLauncherCalls = 0
        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $action -RegistryReader $registry `
            -FileSnapshotReader $file -SignatureReader $signature `
            -Launcher { param($Path) $script:matrixLauncherCalls++ }

        $script:matrixLauncherCalls | Should -Be 0
        $result.status | Should -BeExactly 'skipped'
        $result.failure_stage | Should -BeNullOrEmpty
    }

    It 'never calls launcher when the final immediate snapshot reader throws' {
        $script:finalSnapshotCalls=0
        $reader={param($Path)$script:finalSnapshotCalls++;if($script:finalSnapshotCalls -lt 3){$script:handoffSnapshot}else{throw 'final secret'}}
        $script:finalExceptionLauncherCalls=0

        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $script:handoffRegistry -FileSnapshotReader $reader `
            -SignatureReader $script:handoffSignature -Launcher {param($Path)$script:finalExceptionLauncherCalls++}

        $script:finalExceptionLauncherCalls | Should -Be 0
        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -BeExactly '启动前安全复核失败，请重新扫描后再试'
        $result.failure_stage | Should -BeNullOrEmpty
    }

    It 'returns launch-stage failure only when the process creation API throws' {
        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $script:handoffRegistry -FileSnapshotReader $script:handoffFile `
            -SignatureReader $script:handoffSignature -Launcher {param($Path)throw 'secret process failure'}

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -BeExactly '无法启动联想官方卸载程序'
        $result.failure_stage | Should -BeExactly 'launch'
    }

    It 'uses Start-Process with only FilePath PassThru and ErrorAction in the production launcher' {
        Mock Start-Process { [pscustomobject]@{Id=1234} }
        $result = Invoke-ReviewedLenovoUninstallerHandoff -Action $script:handoffAction `
            -RegistryReader $script:handoffRegistry -FileSnapshotReader $script:handoffFile `
            -SignatureReader $script:handoffSignature

        $result.status | Should -BeExactly 'manual_required'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -ceq 'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe' -and $PassThru -and
            $ErrorAction -ceq 'Stop' -and -not $PSBoundParameters.ContainsKey('ArgumentList') -and
            -not $PSBoundParameters.ContainsKey('Verb') -and -not $PSBoundParameters.ContainsKey('WorkingDirectory')
        }
    }
}

Describe 'native stable Lenovo uninstaller file snapshot' {
    It 'captures one-link identity, metadata, final DOS path, and SHA256 from a safe temporary file' {
        $path = Join-Path $TestDrive 'uninst.exe'
        [System.IO.File]::WriteAllBytes($path, [byte[]](1,2,3,4,5))
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try { $expectedHash = ([BitConverter]::ToString($hasher.ComputeHash([byte[]](1,2,3,4,5)))).Replace('-', '') }
        finally { $hasher.Dispose() }

        $snapshot = Get-StableLenovoUninstallerFileSnapshot -Path $path

        $snapshot.NumberOfLinks | Should -Be 1
        $snapshot.Length | Should -Be 5
        $snapshot.FinalPath | Should -BeExactly ([System.IO.Path]::GetFullPath($path))
        $snapshot.Sha256 | Should -BeExactly $expectedHash
    }

    It 'rejects a missing file and directory' {
        { Get-StableLenovoUninstallerFileSnapshot -Path (Join-Path $TestDrive 'missing.exe') } | Should -Throw
        { Get-StableLenovoUninstallerFileSnapshot -Path $TestDrive } | Should -Throw
    }

    It 'rejects a reparse point in any existing path component' {
        $target = Join-Path $TestDrive 'target'
        $junction = Join-Path $TestDrive 'junction'
        $null = New-Item -ItemType Directory -Path $target
        [System.IO.File]::WriteAllBytes((Join-Path $target 'uninst.exe'), [byte[]](1,2,3))
        $null = New-Item -ItemType Junction -Path $junction -Target $target

        { Get-StableLenovoUninstallerFileSnapshot -Path (Join-Path $junction 'uninst.exe') } | Should -Throw
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
