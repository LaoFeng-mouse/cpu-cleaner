# Pester tests: unprivileged reader verification for privileged inventory packages
BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Root = $projectRoot
    foreach ($module in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
        . (Join-Path $projectRoot ('src\Core\' + $module + '.ps1'))
    }
    $inventoryModule = Join-Path $projectRoot 'src\Core\InventoryManager.ps1'
    if (Test-Path -LiteralPath $inventoryModule) { . $inventoryModule }

    $script:ReaderSid = 'S-1-5-21-1000-1000-1000-1001'
    $script:Nonce = 'a' * 64
    $script:TestServiceDirectory = Join-Path $TestDrive 'Program Files\Example'
    $null = New-Item -ItemType Directory -Path $script:TestServiceDirectory -Force
    $script:TestServiceExecutable = Join-Path $script:TestServiceDirectory 'service.exe'
    [System.IO.File]::WriteAllBytes($script:TestServiceExecutable, [byte[]](1))
    if (-not (Get-Command Is-Admin -ErrorAction SilentlyContinue)) {
        function Is-Admin { return $false }
    }

    function New-TestInventoryPackage {
        param([datetime]$UtcNow = [datetime]::UtcNow)
        $generated = $UtcNow.ToUniversalTime().AddSeconds(-10)
        return [pscustomobject][ordered]@{
            inventory_schema_version = 2
            nonce = $script:Nonce
            generated_utc = $generated.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            collector_sid = $script:ReaderSid
            services = @([pscustomobject][ordered]@{
                Name='ExampleSvc'; DisplayName='Example Service'; State='Running'; StartMode='Auto'
                PathName=('"' + $script:TestServiceExecutable + '" --service'); ProcessId=123
                ProcessIdentityStatus='complete'; ProcessName='service.exe'; ProcessPath=$script:TestServiceExecutable
                ProcessStartTimeUtc=$generated.AddSeconds(-1).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            })
            tasks = @([pscustomobject][ordered]@{
                TaskName='Example Task'; TaskPath='\Vendor\'; State='Ready'; Author='Vendor'
                Description='Example scheduled task'; Actions=@('C:\Program Files\Example\task.exe')
            })
            health = [pscustomobject][ordered]@{ services='complete'; tasks='complete' }
            warnings = @('compatibility fallback used')
        }
    }

    function Copy-TestInventoryPackage($Package) {
        return ConvertFrom-StrictInventoryJson ($Package | ConvertTo-Json -Depth 12)
    }

    function New-TestInventoryAclDescriptor {
        param(
            [string]$OwnerSid = 'S-1-5-18',
            [bool]$Protected = $true,
            [string]$ReaderSid = $script:ReaderSid,
            [int64]$ReaderRights = [int64]([System.Security.AccessControl.FileSystemRights]::Read),
            $AdditionalRules = @()
        )
        $full = [int64][System.Security.AccessControl.FileSystemRights]::FullControl
        $rules = @(
            [pscustomobject]@{ Sid='S-1-5-18'; Type='Allow'; Rights=$full; Inherited=$false; AppliesToCurrentObject=$true }
            [pscustomobject]@{ Sid='S-1-5-32-544'; Type='Allow'; Rights=$full; Inherited=$false; AppliesToCurrentObject=$true }
            [pscustomobject]@{ Sid=$ReaderSid; Type='Allow'; Rights=$ReaderRights; Inherited=$false; AppliesToCurrentObject=$true }
        ) + @($AdditionalRules)
        return [pscustomobject]@{ OwnerSid=$OwnerSid; Protected=$Protected; Rules=$rules }
    }

    function Convert-PackageToUtf8Bytes($Package) {
        $json = $Package | ConvertTo-Json -Depth 12 -Compress
        return [System.Text.UTF8Encoding]::new($false, $true).GetBytes($json)
    }
}

Describe 'trusted privileged inventory nonce and paths' {
    It 'defines the bounded inventory constants' {
        $script:InventorySchemaVersion | Should -Be 2
        $script:MaxInventoryJsonBytes | Should -Be 8MB
        $script:MaxInventoryJsonDepth | Should -Be 12
        $script:MaxInventoryRecords | Should -Be 20000
        $script:MaxInventoryProcessNameLength | Should -Be 260
        $script:MaxInventoryProcessPathLength | Should -Be 32767
    }

    It 'accepts exactly 64 lowercase hexadecimal characters' {
        Test-InventoryNonce ('0f' * 32) | Should -BeTrue
        Test-InventoryNonce ('a' * 64) | Should -BeTrue
    }

    It 'rejects uppercase traversal wrong lengths and nonhex nonce values' -TestCases @(
        @{ Value=('A' * 64) }, @{ Value='..\inventory.json' }, @{ Value=('a' * 63) }
        @{ Value=('a' * 65) }, @{ Value=('g' * 64) }, @{ Value='' }, @{ Value=$null }
    ) {
        param($Value)
        Test-InventoryNonce $Value | Should -BeFalse
    }

    It 'accepts only bounded clean identity strings' {
        Test-InventoryBoundedCleanString 'service.exe' 260 | Should -BeTrue
        Test-InventoryBoundedCleanString 7 260 | Should -BeFalse
        Test-InventoryBoundedCleanString '' 260 | Should -BeFalse
        Test-InventoryBoundedCleanString ('a' * 261) 260 | Should -BeFalse
        Test-InventoryBoundedCleanString ' service.exe' 260 | Should -BeFalse
        Test-InventoryBoundedCleanString 'service.exe ' 260 | Should -BeFalse
        Test-InventoryBoundedCleanString ("service$([char]0x7f).exe") 260 | Should -BeFalse
    }

    It 'parses canonical zero-offset UTC timestamps' {
        $parsed = ConvertFrom-InventoryCanonicalUtc '2026-08-13T00:00:00.1234567Z'
        $parsed.Offset | Should -Be ([timespan]::Zero)
        $parsed.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture) |
            Should -BeExactly '2026-08-13T00:00:00.1234567Z'
    }

    It 'returns null for invalid canonical UTC <Label>' -TestCases @(
        @{ Label='syntax'; Value='2026-08-13T00:00:00Z' }
        @{ Label='type'; Value=7 }
        @{ Label='offset'; Value='2026-08-13T00:00:00.1234567+00:00' }
        @{ Label='null'; Value=$null }
    ) {
        param($Label, $Value)
        ConvertFrom-InventoryCanonicalUtc $Value | Should -BeNullOrEmpty
    }

    It 'accepts only fully qualified Windows paths' {
        Test-InventoryFullyQualifiedWindowsPath $script:TestServiceExecutable | Should -BeTrue
        Test-InventoryFullyQualifiedWindowsPath 'C:\service.exe' | Should -BeTrue
        Test-InventoryFullyQualifiedWindowsPath 'C:/service.exe' | Should -BeTrue
        Test-InventoryFullyQualifiedWindowsPath '\\server\share\service.exe' | Should -BeTrue
        Test-InventoryFullyQualifiedWindowsPath 'C:service.exe' | Should -BeFalse
        Test-InventoryFullyQualifiedWindowsPath '\service.exe' | Should -BeFalse
        Test-InventoryFullyQualifiedWindowsPath '\\server' | Should -BeFalse
        Test-InventoryFullyQualifiedWindowsPath '\\server\' | Should -BeFalse
    }

    It 'resolves the fixed ProgramData MouseCleaner ScanResults root' {
        $root = Get-SecureInventoryRoot
        [System.IO.Path]::IsPathRooted($root) | Should -BeTrue
        $root.TrimEnd('\') | Should -Match '[\\/]MouseCleaner[\\/]ScanResults$'
        $root | Should -Be ([System.IO.Path]::GetFullPath($root))
    }

    It 'resolves inventory.json only beneath the fixed root' {
        Mock Get-SecureInventoryRoot { 'C:\ProgramData\MouseCleaner\ScanResults' }
        $expected = 'C:\ProgramData\MouseCleaner\ScanResults\' + ('b' * 64) + '\inventory.json'
        Resolve-InventoryPackagePath ('b' * 64) | Should -BeExactly $expected
    }

    It 'rejects path-like input rather than accepting an arbitrary path' {
        { Resolve-InventoryPackagePath 'C:\Temp\inventory.json' } | Should -Throw '*nonce*'
    }

    It 'returns a Windows SID for the current identity' {
        Get-CurrentUserSid | Should -Match '^S-1-'
    }

    It 'disposes each Windows identity token handle after reading the SID' {
        $process = [System.Diagnostics.Process]::GetCurrentProcess()
        try {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $process.Refresh()
            $before = $process.HandleCount
            foreach ($iteration in 1..32) { $null = Get-CurrentUserSid }
            $process.Refresh()
            ($process.HandleCount - $before) | Should -BeLessOrEqual 2
        } finally {
            $process.Dispose()
        }
    }
}

Describe 'trusted privileged inventory ACL proof' {
    It 'reads the ACL without depending on Security module autoloading' {
        Mock Get-Acl { throw "The 'Get-Acl' command was found in the module 'Microsoft.PowerShell.Security', but the module could not be loaded." }

        $descriptor = Get-InventoryAclDescriptor -Path $TestDrive

        $descriptor.OwnerSid | Should -Match '^S-1-'
        $descriptor.Rules.Count | Should -BeGreaterThan 0
        Assert-MockCalled Get-Acl -Times 0 -Exactly
    }

    It 'accepts a protected trusted owner with trusted writers and a read-only reader' {
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor) $script:ReaderSid | Should -BeTrue
    }

    It 'rejects an unprotected DACL' {
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor -Protected $false) $script:ReaderSid | Should -BeFalse
    }

    It 'rejects an untrusted owner' {
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor -OwnerSid $script:ReaderSid) $script:ReaderSid | Should -BeFalse
    }

    It 'rejects mutation rights granted to the reader' {
        $rights = [int64]([System.Security.AccessControl.FileSystemRights]::Read -bor [System.Security.AccessControl.FileSystemRights]::Write)
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor -ReaderRights $rights) $script:ReaderSid | Should -BeFalse
    }

    It 'rejects raw <Name> rights granted to an untrusted SID' -TestCases @(
        @{ Name='GENERIC_WRITE'; Mask=[Convert]::ToInt64('40000000', 16) }
        @{ Name='GENERIC_ALL'; Mask=[Convert]::ToInt64('10000000', 16) }
    ) {
        param($Name, $Mask)
        $rule = [pscustomobject]@{
            Sid='S-1-5-11'; Type='Allow'; Rights=[int64]$Mask
            Inherited=$false; AppliesToCurrentObject=$true
        }
        $descriptor = New-TestInventoryAclDescriptor -AdditionalRules @($rule)
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'rejects raw <Name> rights granted to the reader' -TestCases @(
        @{ Name='GENERIC_WRITE'; Mask=[Convert]::ToInt64('40000000', 16) }
        @{ Name='GENERIC_ALL'; Mask=[Convert]::ToInt64('10000000', 16) }
    ) {
        param($Name, $Mask)
        $rights = [int64]([System.Security.AccessControl.FileSystemRights]::Read) -bor [int64]$Mask
        $descriptor = New-TestInventoryAclDescriptor -ReaderRights $rights
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'does not treat raw GENERIC_READ as concrete read proof' {
        $genericRead = [Convert]::ToInt64('80000000', 16)
        $descriptor = New-TestInventoryAclDescriptor -ReaderRights $genericRead
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'does not treat raw GENERIC_READ as a mutation right' {
        $genericRead = [Convert]::ToInt64('80000000', 16)
        $rights = [int64]([System.Security.AccessControl.FileSystemRights]::Read) -bor $genericRead
        $descriptor = New-TestInventoryAclDescriptor -ReaderRights $rights
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeTrue
    }

    It 'rejects missing read-control for the supplied reader' {
        $rights = [int64][System.Security.AccessControl.FileSystemRights]::ReadData
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor -ReaderRights $rights) $script:ReaderSid | Should -BeFalse
    }

    It 'requires file-read access in addition to read-control for the supplied reader' {
        $rights = [int64]([System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
            [System.Security.AccessControl.FileSystemRights]::ReadPermissions)
        Test-TrustedInventoryAclDescriptor (New-TestInventoryAclDescriptor -ReaderRights $rights) $script:ReaderSid | Should -BeFalse
    }

    It 'rejects untrusted writers and deny or inherited ambiguity' -TestCases @(
        @{ Rule=[pscustomobject]@{ Sid='S-1-5-11'; Type='Allow'; Rights=[int64][System.Security.AccessControl.FileSystemRights]::Write; Inherited=$false; AppliesToCurrentObject=$true } }
        @{ Rule=[pscustomobject]@{ Sid='S-1-5-11'; Type='Deny'; Rights=[int64][System.Security.AccessControl.FileSystemRights]::Read; Inherited=$false; AppliesToCurrentObject=$true } }
        @{ Rule=[pscustomobject]@{ Sid='S-1-5-11'; Type='Allow'; Rights=[int64][System.Security.AccessControl.FileSystemRights]::Read; Inherited=$true; AppliesToCurrentObject=$true } }
        @{ Rule=[pscustomobject]@{ Sid='S-1-5-11'; Type='Allow'; Rights=[int64][System.Security.AccessControl.FileSystemRights]::Read; Inherited=$false; AppliesToCurrentObject=$false } }
    ) {
        param($Rule)
        $descriptor = New-TestInventoryAclDescriptor -AdditionalRules @($Rule)
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'requires both SYSTEM and Administrators to retain write access' -TestCases @(
        @{ MissingSid='S-1-5-18' }
        @{ MissingSid='S-1-5-32-544' }
    ) {
        param($MissingSid)
        $descriptor = New-TestInventoryAclDescriptor
        $descriptor.Rules = @($descriptor.Rules | Where-Object { $_.Sid -cne $MissingSid })
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'rejects read-only SYSTEM or Administrators entries as missing trusted writers' -TestCases @(
        @{ Sid='S-1-5-18' }
        @{ Sid='S-1-5-32-544' }
    ) {
        param($Sid)
        $descriptor = New-TestInventoryAclDescriptor
        @($descriptor.Rules | Where-Object { $_.Sid -ceq $Sid })[0].Rights =
            [int64][System.Security.AccessControl.FileSystemRights]::Read
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'rejects weak WriteData-only SYSTEM or Administrators entries as lacking FullControl' -TestCases @(
        @{ Sid='S-1-5-18' }
        @{ Sid='S-1-5-32-544' }
    ) {
        param($Sid)
        $descriptor = New-TestInventoryAclDescriptor
        @($descriptor.Rules | Where-Object { $_.Sid -ceq $Sid })[0].Rights =
            [int64][System.Security.AccessControl.FileSystemRights]::WriteData
        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeFalse
    }

    It 'throws when a path ACL is not trusted' {
        Mock Get-InventoryAclDescriptor { New-TestInventoryAclDescriptor -OwnerSid $script:ReaderSid }
        { Assert-TrustedInventoryPathAcl 'C:\trusted\inventory.json' $script:ReaderSid } | Should -Throw '*ACL*'
    }
}

Describe 'trusted privileged inventory reparse and handle identity proof' {
    It 'rejects a reparse point at each existing path component' {
        $base = Join-Path $TestDrive 'root'
        $nonceDir = Join-Path $base $script:Nonce
        $file = Join-Path $nonceDir 'inventory.json'
        $null = New-Item -ItemType Directory -Path $nonceDir -Force
        [System.IO.File]::WriteAllText($file, '{}')
        $components = @(Get-ExistingInventoryPathComponents $file)
        $components.Count | Should -BeGreaterThan 2
        foreach ($badComponent in $components) {
            $script:BadReparseComponent = $badComponent
            Mock Get-InventoryPathAttributes {
                if ([string]::Equals($Path, $script:BadReparseComponent, [StringComparison]::OrdinalIgnoreCase)) {
                    return [System.IO.FileAttributes]::ReparsePoint
                }
                return [System.IO.FileAttributes]::Normal
            }
            { Assert-InventoryPathIsNotReparsePoint $file } | Should -Throw '*reparse*'
        }
    }

    It 'fails closed when a path component cannot be inspected' {
        $path = 'C:\ProgramData\MouseCleaner\ScanResults\' + $script:Nonce + '\inventory.json'
        Mock Test-Path { $false }
        Mock Get-InventoryPathAttributes { throw 'ambiguous path component' }

        { Assert-InventoryPathIsNotReparsePoint $path } | Should -Throw '*ambiguous path component*'
    }

    It 'rejects a final path mismatch' {
        $path = Join-Path $TestDrive 'mismatch.json'
        [System.IO.File]::WriteAllText($path, '{}')
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Test-OpenedPendingFileIdentity { $false }
        { Open-TrustedInventoryReadStream $path } | Should -Throw '*identity*'
    }

    It 'rejects a hardlink count other than one' {
        $path = Join-Path $TestDrive 'hardlink.json'
        [System.IO.File]::WriteAllText($path, '{}')
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Test-OpenedPendingFileIdentity { $true }
        Mock Test-OpenedPendingFileHasSingleLink { $false }
        { Open-TrustedInventoryReadStream $path } | Should -Throw '*hardlink*'
    }

    It 'holds a read-share handle that rejects replacement while open' {
        $path = Join-Path $TestDrive 'locked.json'
        $replacement = Join-Path $TestDrive 'replacement.json'
        $backup = Join-Path $TestDrive 'replaced-backup.json'
        [System.IO.File]::WriteAllText($path, '{}')
        [System.IO.File]::WriteAllText($replacement, '{"replacement":true}')
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Test-OpenedPendingFileIdentity { $true }
        Mock Test-OpenedPendingFileHasSingleLink { $true }
        $stream = Open-TrustedInventoryReadStream $path
        try {
            $stream.CanRead | Should -BeTrue
            $stream.CanWrite | Should -BeFalse
            { [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite).Dispose() } | Should -Throw
            { [System.IO.File]::Replace($replacement, $path, $backup) } | Should -Throw
        } finally {
            $stream.Dispose()
        }
    }

    It 'proves final-path identity and a single link with a real filesystem handle' {
        $path = Join-Path $TestDrive 'real-identity.json'
        [System.IO.File]::WriteAllText($path, '{}')

        $stream = Open-TrustedInventoryReadStream $path
        try {
            Test-OpenedPendingFileIdentity -Stream $stream -Path $path | Should -BeTrue
            Test-OpenedPendingFileHasSingleLink -Stream $stream | Should -BeTrue
        } finally {
            $stream.Dispose()
        }
    }
}

Describe 'strict privileged inventory JSON and package shape' {
    It 'rejects decoded duplicate JSON properties before conversion' -TestCases @(
        @{ Json='{"nonce":"a","nonce":"b"}' }
        @{ Json='{"nonce":"a","Nonce":"b"}' }
        @{ Json='{"nonce":"a","\u006eonce":"b"}' }
    ) {
        param($Json)
        { ConvertFrom-StrictInventoryJson $Json } | Should -Throw '*duplicate*'
    }

    It 'rejects inventory JSON deeper than twelve containers' {
        $json = '{"a":0}'
        for ($i = 0; $i -lt 13; $i++) { $json = '{"a":' + $json + '}' }
        { ConvertFrom-StrictInventoryJson $json } | Should -Throw '*depth*'
    }

    It 'accepts a strict current package compatible with Scanner record shapes' {
        { Assert-InventoryPackageShape (New-TestInventoryPackage) $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'uses only the exact service and task fields with strict scalar and array types' {
        $package = New-TestInventoryPackage
        (@($package.services[0].PSObject.Properties.Name) -join ',') |
            Should -BeExactly 'Name,DisplayName,State,StartMode,PathName,ProcessId,ProcessIdentityStatus,ProcessName,ProcessPath,ProcessStartTimeUtc'
        (@($package.tasks[0].PSObject.Properties.Name) -join ',') |
            Should -BeExactly 'TaskName,TaskPath,State,Author,Description,Actions'
        foreach ($name in @('Name','DisplayName','State','StartMode','PathName')) {
            $package.services[0].$name | Should -BeOfType [string]
        }
        Test-InventoryInteger $package.services[0].ProcessId | Should -BeTrue
        foreach ($name in @('ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc')) {
            $package.services[0].$name | Should -BeOfType [string]
        }
        foreach ($name in @('TaskName','TaskPath','State','Author','Description')) {
            $package.tasks[0].$name | Should -BeOfType [string]
        }
        ($package.tasks[0].Actions -is [System.Array]) | Should -BeTrue
        foreach ($action in @($package.tasks[0].Actions)) { $action | Should -BeOfType [string] }
    }

    It 'accepts the exact task contract after the JSON round trip' {
        $package = New-TestInventoryPackage
        $jsonPackage = ConvertFrom-StrictInventoryJson (
            ConvertFrom-InventorySnapshotBytes (Convert-PackageToUtf8Bytes $package))

        { Assert-InventoryPackageShape $jsonPackage $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'accepts the exact service contract after the JSON round trip' {
        $package = New-TestInventoryPackage
        $jsonPackage = ConvertFrom-StrictInventoryJson (
            ConvertFrom-InventorySnapshotBytes (Convert-PackageToUtf8Bytes $package))

        { Assert-InventoryPackageShape $jsonPackage $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'accepts valid service process identity status <Status>' -TestCases @(
        @{ Status='complete'; State='Running'; ProcessId=[int]::MaxValue }
        @{ Status='not_running'; State='Stopped'; ProcessId=0 }
        @{ Status='unavailable'; State='Running'; ProcessId=123 }
        @{ Status='unavailable'; State='Stopped'; ProcessId=0 }
    ) {
        param($Status, $State, $ProcessId)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $service = $package.services[0]
        $service.ProcessIdentityStatus = $Status
        $service.State = $State
        $service.ProcessId = $ProcessId
        if ($Status -cne 'complete') {
            $service.ProcessName = ''
            $service.ProcessPath = ''
            $service.ProcessStartTimeUtc = ''
        }

        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'accepts unavailable service identity with UInt32 max PID' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $service = $package.services[0]
        $service.ProcessIdentityStatus = 'unavailable'
        $service.ProcessId = [uint32]::MaxValue
        $service.ProcessName = ''
        $service.ProcessPath = ''
        $service.ProcessStartTimeUtc = ''

        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'rejects legacy schema v1 packages' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.inventory_schema_version = 1
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*schema*'
    }

    It 'rejects stale future nonce SID and incomplete health packages' -TestCases @(
        @{ Mutation={ param($p) $p.generated_utc=[datetime]::UtcNow.AddMinutes(-6).ToString('o') } }
        @{ Mutation={ param($p) $p.generated_utc=[datetime]::UtcNow.AddMinutes(2).ToString('o') } }
        @{ Mutation={ param($p) $p.nonce='b' * 64 } }
        @{ Mutation={ param($p) $p.collector_sid='S-1-5-21-999' } }
        @{ Mutation={ param($p) $p.health.tasks='unavailable' } }
        @{ Mutation={ param($p) $p.health.services='degraded' } }
    ) {
        param($Mutation)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        & $Mutation $package
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw
    }

    It 'rejects non-canonical generated_utc text' -TestCases @(
        @{ Value='Thursday, August 13, 2026 12:00:00 AM Z' }
        @{ Value='2026-08-13T00:00:00.0000000+00:00' }
        @{ Value='2026-08-13T00:00:00.0000000z' }
        @{ Value='2026-08-13T00:00:00Z' }
        @{ Value='2026-08-13T00:00:00.123Z' }
    ) {
        param($Value)
        $now = [datetime]::SpecifyKind([datetime]'2026-08-13T00:00:00', [DateTimeKind]::Utc)
        $package = New-TestInventoryPackage $now
        $package.generated_utc = $Value
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid $now } | Should -Throw '*UTC timestamp*'
    }

    It 'rejects unknown top health service and task fields' -TestCases @(
        @{ Target='top' }, @{ Target='health' }, @{ Target='service' }, @{ Target='task' }
    ) {
        param($Target)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        switch ($Target) {
            'top' { $package | Add-Member Unexpected $true }
            'health' { $package.health | Add-Member Unexpected $true }
            'service' { $package.services[0] | Add-Member Unexpected $true }
            'task' { $package.tasks[0] | Add-Member Unexpected $true }
        }
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*field*'
    }

    It 'rejects scalar array confusion and null records' -TestCases @(
        @{ Mutation={ param($p) $p.services='service' } }
        @{ Mutation={ param($p) $p.tasks=[pscustomobject]@{ TaskName='task' } } }
        @{ Mutation={ param($p) $p.warnings='warning' } }
        @{ Mutation={ param($p) $p.services=@($null) } }
        @{ Mutation={ param($p) $p.tasks=@($null) } }
    ) {
        param($Mutation)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        & $Mutation $package
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw
    }

    It 'rejects warnings that are not scalar strings' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.warnings = @([pscustomobject]@{ message='not scalar' })
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*warning*'
    }

    It 'rejects more than twenty thousand service records' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $record = $package.services[0]
        $package.services = @($record) * 20001
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*record*'
    }

    It 'rejects more than twenty thousand task records' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.tasks = @($package.tasks[0]) * 20001
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*record*'
    }

    It 'accepts twenty thousand services and twenty thousand tasks independently' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.services = @($package.services[0]) * 20000
        $package.tasks = @($package.tasks[0]) * 20000
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
    }

    It 'rejects invalid service records' -TestCases @(
        @{ Property='Name'; Value='' }, @{ Property='DisplayName'; Value=@('array') }
        @{ Property='State'; Value=$null }, @{ Property='StartMode'; Value=[pscustomobject]@{} }
        @{ Property='PathName'; Value=7 }, @{ Property='ProcessId'; Value=-1 }
        @{ Property='ProcessId'; Value='123' }
    ) {
        param($Property, $Value)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.services[0].$Property = $Value
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*service*'
    }

    It 'rejects invalid service process identities: <Case>' -TestCases @(
        @{ Case='unknown status'; Mutation={ param($s,$p) $s.ProcessIdentityStatus='unknown' } }
        @{ Case='partial identity'; Mutation={ param($s,$p) $s.ProcessIdentityStatus='unavailable'; $s.ProcessName='service.exe'; $s.ProcessPath=''; $s.ProcessStartTimeUtc='' } }
        @{ Case='complete with PID zero'; Mutation={ param($s,$p) $s.ProcessId=0 } }
        @{ Case='complete while service is not Running'; Mutation={ param($s,$p) $s.State='Stopped' } }
        @{ Case='not running with positive PID'; Mutation={ param($s,$p) $s.ProcessIdentityStatus='not_running'; $s.State='Stopped'; $s.ProcessId=1; $s.ProcessName=''; $s.ProcessPath=''; $s.ProcessStartTimeUtc='' } }
        @{ Case='not running status while state is Running'; Mutation={ param($s,$p) $s.ProcessIdentityStatus='not_running'; $s.ProcessId=0; $s.ProcessName=''; $s.ProcessPath=''; $s.ProcessStartTimeUtc='' } }
        @{ Case='unrooted process path'; Mutation={ param($s,$p) $s.ProcessPath='service.exe' } }
        @{ Case='drive-relative process path'; Mutation={ param($s,$p) $s.ProcessPath='C:service.exe' } }
        @{ Case='root-relative process path'; Mutation={ param($s,$p) $s.ProcessPath='\service.exe' } }
        @{ Case='drive-relative service binary'; Mutation={ param($s,$p) $s.PathName='C:service.exe' } }
        @{ Case='root-relative service binary'; Mutation={ param($s,$p) $s.PathName='\service.exe' } }
        @{ Case='filename path mismatch'; Mutation={ param($s,$p) $s.ProcessName='other.exe' } }
        @{ Case='service binary path mismatch'; Mutation={ param($s,$p) $s.PathName='C:\Other\service.exe' } }
        @{ Case='process name is not a pure filename'; Mutation={ param($s,$p) $s.ProcessName='folder\service.exe' } }
        @{ Case='process name has leading whitespace'; Mutation={ param($s,$p) $s.ProcessName=' service.exe' } }
        @{ Case='process name has control characters'; Mutation={ param($s,$p) $s.ProcessName="service$([char]0x1f).exe" } }
        @{ Case='process path has C1 controls'; Mutation={ param($s,$p) $s.ProcessPath=([string]$s.ProcessPath + [char]0x85) } }
        @{ Case='process path exceeds its bound'; Mutation={ param($s,$p) $s.ProcessPath=('C:\' + ('a' * 32768)) } }
        @{ Case='noncanonical process UTC'; Mutation={ param($s,$p) $s.ProcessStartTimeUtc='2026-08-13T00:00:00Z' } }
        @{ Case='process start after generated UTC'; Mutation={ param($s,$p) $s.ProcessStartTimeUtc='9999-12-31T23:59:59.9999999Z' } }
        @{ Case='PID exceeds Int32 max'; Mutation={ param($s,$p) $s.ProcessId=[int64][int]::MaxValue + 1 } }
    ) {
        param($Case, $Mutation)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        & $Mutation $package.services[0] $package
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*service*'
    }

    It 'rejects missing and extra service fields' -TestCases @(
        @{ Mode='missing' }, @{ Mode='extra' }
    ) {
        param($Mode)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        if ($Mode -ceq 'missing') {
            $package.services[0].PSObject.Properties.Remove('ProcessStartTimeUtc')
        } else {
            $package.services[0] | Add-Member Unexpected $true
        }
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*service*'
    }

    It 'rejects invalid task records' -TestCases @(
        @{ Property='TaskName'; Value='' }, @{ Property='TaskPath'; Value='Vendor' }
        @{ Property='State'; Value=@('Ready') }, @{ Property='State'; Value='Bogus' }
        @{ Property='State'; Value=5 }, @{ Property='Author'; Value=@('Vendor') }
        @{ Property='Description'; Value=7 }, @{ Property='Actions'; Value='task.exe' }
        @{ Property='Actions'; Value=@('task.exe', 7) }
    ) {
        param($Property, $Value)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.tasks[0].$Property = $Value
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*task*'
    }

    It 'rejects missing required task fields' {
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $package.tasks[0].PSObject.Properties.Remove('Actions')
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw '*task*'
    }

    It 'rejects legacy TriggerHint and LoginTrigger fields' -TestCases @(
        @{ Target='service'; Property='TriggerHint' }
        @{ Target='task'; Property='LoginTrigger' }
    ) {
        param($Target, $Property)
        $package = Copy-TestInventoryPackage (New-TestInventoryPackage)
        $record = if ($Target -eq 'service') { $package.services[0] } else { $package.tasks[0] }
        $record | Add-Member $Property $false
        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Throw "*$Target*field*"
    }
}

Describe 'bounded one-snapshot privileged inventory reader' {
    BeforeEach {
        Mock Get-CurrentUserSid { $script:ReaderSid }
        Mock Resolve-InventoryPackagePath { Join-Path $TestDrive 'inventory.json' }
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Assert-TrustedInventoryPathAcl {}
    }

    It 'does not expose a caller-controlled ReaderSid parameter' {
        (Get-Command Read-TrustedInventoryPackage).Parameters.Keys | Should -Not -Contain 'ReaderSid'
    }

    It 'does not expose a caller-controlled UtcNow parameter' {
        (Get-Command Read-TrustedInventoryPackage).Parameters.Keys | Should -Not -Contain 'UtcNow'
    }

    It 'cannot revive a stale package with caller-controlled time' {
        $callerTime = [datetime]::UtcNow.AddMinutes(-10)
        $bytes = Convert-PackageToUtf8Bytes (New-TestInventoryPackage $callerTime)
        $stream = [System.IO.MemoryStream]::new($bytes)
        Mock Open-TrustedInventoryReadStream { $stream }
        Mock Read-LimitedInventorySnapshot { return $bytes }

        { Read-TrustedInventoryJsonPackage -Nonce $script:Nonce -ReaderSid $script:ReaderSid } | Should -Throw '*trusted window*'
    }

    It 'rejects a snapshot larger than eight megabytes' {
        $stream = [System.IO.MemoryStream]::new((New-Object byte[] (8MB + 1)))
        try { { Read-LimitedInventorySnapshot $stream } | Should -Throw '*large*' }
        finally { $stream.Dispose() }
    }

    It 'rejects malformed UTF-8 and an incomplete BOM' -TestCases @(
        @{ Bytes=[byte[]](0xC3,0x28) }, @{ Bytes=[byte[]](0xEF,0xBB) }
    ) {
        param($Bytes)
        { ConvertFrom-InventorySnapshotBytes $Bytes } | Should -Throw '*UTF-8*'
    }

    It 'accepts strict UTF-8 with and without the repository-compatible BOM' -TestCases @(
        @{ Bom=$false }, @{ Bom=$true }
    ) {
        param($Bom)
        $jsonBytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes('{"name":"测试"}')
        $bytes = if ($Bom) { [byte[]]([System.Text.Encoding]::UTF8.GetPreamble() + $jsonBytes) } else { $jsonBytes }

        ConvertFrom-InventorySnapshotBytes $bytes | Should -BeExactly '{"name":"测试"}'
    }

    It 'parses and hashes exactly one byte snapshot' {
        $bytes = Convert-PackageToUtf8Bytes (New-TestInventoryPackage)
        $stream = [System.IO.MemoryStream]::new($bytes)
        Mock Open-TrustedInventoryReadStream { $stream }
        Mock Read-LimitedInventorySnapshot { return $bytes }
        $expectedHash = (Get-BytesSha256Hex $bytes).ToLowerInvariant()

        $result = Read-TrustedInventoryJsonPackage -Nonce $script:Nonce -ReaderSid $script:ReaderSid

        $result.Package.nonce | Should -BeExactly $script:Nonce
        $result.Sha256 | Should -BeExactly $expectedHash
        Assert-MockCalled Open-TrustedInventoryReadStream -Times 1 -Exactly
        Assert-MockCalled Read-LimitedInventorySnapshot -Times 1 -Exactly
    }

    It 'reads and hashes an actual inventory file through the locked handle path' {
        $path = Join-Path $TestDrive 'inventory.json'
        $bytes = Convert-PackageToUtf8Bytes (New-TestInventoryPackage)
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $expectedHash = Get-BytesSha256Hex $bytes
        ($expectedHash -cmatch '[A-F]') | Should -BeTrue

        $result = Read-TrustedInventoryJsonPackage -Nonce $script:Nonce -ReaderSid $script:ReaderSid

        $result.Package.collector_sid | Should -BeExactly $script:ReaderSid
        $result.Sha256 | Should -BeExactly $expectedHash.ToLowerInvariant()
        $result.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'rejects a package collected for any SID other than the current user' {
        $package = New-TestInventoryPackage
        $package.collector_sid = 'S-1-5-21-999'
        $bytes = Convert-PackageToUtf8Bytes $package
        $stream = [System.IO.MemoryStream]::new($bytes)
        Mock Open-TrustedInventoryReadStream { $stream }
        Mock Read-LimitedInventorySnapshot { return $bytes }

        { Read-TrustedInventoryJsonPackage -Nonce $script:Nonce -ReaderSid $script:ReaderSid } | Should -Throw '*SID*'
    }

    It 'revalidates ACLs for root nonce directory and file around the locked read' {
        $bytes = Convert-PackageToUtf8Bytes (New-TestInventoryPackage)
        $stream = [System.IO.MemoryStream]::new($bytes)
        Mock Get-SecureInventoryRoot { 'C:\ProgramData\MouseCleaner\ScanResults' }
        Mock Resolve-InventoryPackagePath { 'C:\ProgramData\MouseCleaner\ScanResults\' + $script:Nonce + '\inventory.json' }
        Mock Open-TrustedInventoryReadStream { $stream }
        Mock Read-LimitedInventorySnapshot { return $bytes }

        $null = Read-TrustedInventoryJsonPackage -Nonce $script:Nonce -ReaderSid $script:ReaderSid

        Assert-MockCalled Assert-TrustedInventoryPathAcl -Times 6 -Exactly
        Assert-MockCalled Assert-TrustedInventoryPathAcl -Times 6 -Exactly -ParameterFilter { $ReaderSid -ceq $script:ReaderSid }
    }
}

Describe 'ready-marker inventory commit protocol' {
    BeforeEach {
        Mock Get-CurrentUserSid { $script:ReaderSid }
    }

    It 'requires the fixed inventory.ready marker before opening inventory.json' {
        Mock Read-TrustedInventoryReadyMarker { throw 'inventory.ready is missing' }
        Mock Read-TrustedInventoryJsonPackage { throw 'must not read uncommitted JSON' }

        { Read-TrustedInventoryPackage $script:Nonce } | Should -Throw '*inventory.ready*'
        Assert-MockCalled Read-TrustedInventoryJsonPackage -Times 0 -Exactly
    }

    It 'rejects a ready marker whose hash does not bind the JSON snapshot' {
        Mock Read-TrustedInventoryReadyMarker {
            [pscustomobject]@{ Nonce=$script:Nonce; Sha256=('1' * 64) }
        }
        Mock Read-TrustedInventoryJsonPackage {
            [pscustomobject]@{ Package=(New-TestInventoryPackage); Sha256=('2' * 64) }
        }

        { Read-TrustedInventoryPackage $script:Nonce } | Should -Throw '*hash*'
    }

    It 'accepts a valid marker-bound package' {
        $hash = '3' * 64
        Mock Read-TrustedInventoryReadyMarker {
            [pscustomobject]@{ Nonce=$script:Nonce; Sha256=$hash }
        }
        Mock Read-TrustedInventoryJsonPackage {
            [pscustomobject]@{ Package=(New-TestInventoryPackage); Sha256=$hash }
        }

        $result = Read-TrustedInventoryPackage $script:Nonce
        $result.Package.nonce | Should -BeExactly $script:Nonce
        $result.Sha256 | Should -BeExactly $hash
    }

    It 'uses a fixed marker name and exposes no arbitrary marker path' {
        Mock Get-SecureInventoryRoot { 'C:\ProgramData\MouseCleaner\ScanResults' }
        Resolve-InventoryReadyPath $script:Nonce | Should -BeExactly ('C:\ProgramData\MouseCleaner\ScanResults\' + $script:Nonce + '\inventory.ready')
        (Get-Command Read-TrustedInventoryReadyMarker).Parameters.Keys | Should -Not -Contain 'Path'
    }
}

Describe 'cpu-cleaner module load order' {
    It 'loads InventoryManager immediately after BackupManager' {
        $source = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw
        $source | Should -Match "'ActionEngine','BackupManager','InventoryManager'"
    }
}

Describe 'protected privileged inventory writer ACLs' {
    It 'creates a protected descriptor accepted by the Task1 validator' {
        $security = New-ProtectedInventorySecurity -ReaderSid $script:ReaderSid
        $descriptor = [pscustomobject]@{
            OwnerSid = $security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            Protected = $security.AreAccessRulesProtected
            Rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
                [pscustomobject]@{
                    Sid = $_.IdentityReference.Value
                    Type = $_.AccessControlType.ToString()
                    Rights = [int64]$_.FileSystemRights
                    Inherited = [bool]$_.IsInherited
                    AppliesToCurrentObject = (($_.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0)
                }
            })
        }

        Test-TrustedInventoryAclDescriptor $descriptor $script:ReaderSid | Should -BeTrue
    }

    It 'gives the reader read and read-control but no mutation rights' {
        $security = New-ProtectedInventorySecurity -ReaderSid $script:ReaderSid -Directory
        $readerRules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
            Where-Object { $_.IdentityReference.Value -ceq $script:ReaderSid })

        $readerRules.Count | Should -Be 1
        ([int64]$readerRules[0].FileSystemRights -band [int64][System.Security.AccessControl.FileSystemRights]::ReadData) | Should -Not -Be 0
        ([int64]$readerRules[0].FileSystemRights -band [int64][System.Security.AccessControl.FileSystemRights]::ReadPermissions) | Should -Not -Be 0
        $genericWrite = [Convert]::ToInt64('40000000', 16)
        $genericAll = [Convert]::ToInt64('10000000', 16)
        $mutationRights = [int64]([System.Security.AccessControl.FileSystemRights]::WriteData -bor
            [System.Security.AccessControl.FileSystemRights]::AppendData -bor
            [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
            [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [System.Security.AccessControl.FileSystemRights]::Delete -bor
            [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
        $mutationRights = $mutationRights -bor $genericWrite -bor $genericAll
        ([int64]$readerRules[0].FileSystemRights -band $mutationRights) | Should -Be 0
    }

    It 'uses inheritable directory ACEs and non-inheritable file ACEs' {
        $directoryRules = @(New-ProtectedInventorySecurity -ReaderSid $script:ReaderSid -Directory |
            ForEach-Object { $_.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) })
        $fileRules = @(New-ProtectedInventorySecurity -ReaderSid $script:ReaderSid |
            ForEach-Object { $_.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) })

        @($directoryRules | Where-Object {
            $_.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        }).Count | Should -Be 0
        @($fileRules | Where-Object {
            $_.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]::None
        }).Count | Should -Be 0
    }
}

Describe 'atomic privileged inventory publication' {
    BeforeEach {
        $script:WriterRoot = Join-Path $TestDrive 'ScanResults'
        $script:WriterNonce = 'b' * 64
        $script:WriterNonceDirectory = Join-Path $script:WriterRoot $script:WriterNonce
        $script:WriterFinal = Join-Path $script:WriterNonceDirectory 'inventory.json'
        $script:WriterPackage = New-TestInventoryPackage
        $script:WriterPackage.nonce = $script:WriterNonce
        $script:WriterPackage.collector_sid = $script:ReaderSid
        New-Item -ItemType Directory -Path $script:WriterNonceDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath $script:WriterNonceDirectory -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse

        Mock Get-SecureInventoryRoot { $script:WriterRoot }
        Mock Initialize-TrustedInventoryDirectory {}
        Mock Protect-InventoryPathAcl {}
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Assert-TrustedInventoryPathAcl {}
        Mock Read-TrustedInventoryJsonPackageAtPath { [pscustomobject]@{ Package=$script:WriterPackage; Sha256=('0' * 64) } }
        Mock Read-TrustedInventoryReadyMarkerAtPath { [pscustomobject]@{ Nonce=$script:WriterNonce; Sha256=('0' * 64) } }
    }

    It 'writes UTF-8 without BOM through a nonce-local temp and atomically publishes inventory.json' {
        $result = Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage

        Test-Path -LiteralPath $script:WriterFinal -PathType Leaf | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($script:WriterFinal)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:WriterNonceDirectory -Filter 'inventory.*.tmp').Count | Should -Be 0
        $result.Package.nonce | Should -BeExactly $script:WriterNonce
        Assert-MockCalled Protect-InventoryPathAcl -Times 2 -Exactly
        Assert-MockCalled Read-TrustedInventoryJsonPackageAtPath -Times 2 -Exactly
        Assert-MockCalled Read-TrustedInventoryReadyMarkerAtPath -Times 1 -Exactly
    }

    It 'performs every fallible validation before publishing inventory.ready as the terminal operation' {
        $script:PublishOrder = [System.Collections.Generic.List[string]]::new()
        Mock Write-InventoryTempFile { param($Path, $Package) $script:PublishOrder.Add('write-json') }
        Mock Write-InventoryBytesTempFile { param($Path, $Bytes) $script:PublishOrder.Add('write-ready') }
        Mock Protect-InventoryPathAcl { param($Path) $script:PublishOrder.Add($(if ($Path -like '*ready*') {'acl-ready'} else {'acl-json'})) }
        Mock Publish-InventoryTempFile { param($TempPath, $FinalPath) $script:PublishOrder.Add($(if ($FinalPath -like '*.ready') {'publish-ready'} else {'publish-json'})) }
        Mock Read-TrustedInventoryJsonPackageAtPath {
            param($Path)
            $script:PublishOrder.Add($(if ([System.IO.Path]::GetFileName($Path) -ceq 'inventory.json') {'json-final-recheck'} else {'json-temp-recheck'}))
            [pscustomobject]@{Package=$script:WriterPackage;Sha256=('0' * 64)}
        }
        Mock Read-TrustedInventoryReadyMarkerAtPath {
            param($Path)
            $script:PublishOrder.Add('ready-temp-recheck')
            [pscustomobject]@{Nonce=$script:WriterNonce;Sha256=('0' * 64)}
        }

        $null = Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage

        @($script:PublishOrder) | Should -Be @('write-json','acl-json','json-temp-recheck','publish-json','json-final-recheck','write-ready','acl-ready','ready-temp-recheck','publish-ready')
        $script:PublishOrder[$script:PublishOrder.Count - 1] | Should -BeExactly 'publish-ready'
    }

    It 'has no post-marker recheck or cleanup path that can fail after commit' {
        $script:PostCommitOperations = [System.Collections.Generic.List[string]]::new()
        Mock Publish-InventoryTempFile {
            param($TempPath, $FinalPath)
            $name = [System.IO.Path]::GetFileName($FinalPath)
            $script:PostCommitOperations.Add($(if ($name -ceq 'inventory.ready') { 'publish-ready' } else { 'publish-json' }))
        }
        Mock Read-TrustedInventoryReadyMarker {
            $script:PostCommitOperations.Add('read-ready-after-commit')
            throw 'post-marker ready recheck must not execute'
        }
        Mock Read-TrustedInventoryPackage {
            $script:PostCommitOperations.Add('read-package-after-commit')
            throw 'post-marker package recheck must not execute'
        }
        Mock Remove-ValidatedInventoryFile {
            param($Path)
            $script:PostCommitOperations.Add(('remove-' + [System.IO.Path]::GetFileName([string]$Path)))
        }

        { $script:PostCommitResult = Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Not -Throw

        $script:PostCommitResult.Package.nonce | Should -BeExactly $script:WriterNonce
        @($script:PostCommitOperations) | Should -Be @('remove-inventory.ready','publish-json','publish-ready')
        $readyIndex = $script:PostCommitOperations.IndexOf('publish-ready')
        $readyIndex | Should -Be ($script:PostCommitOperations.Count - 1)
        Assert-MockCalled Read-TrustedInventoryReadyMarker -Times 0 -Exactly
        Assert-MockCalled Read-TrustedInventoryPackage -Times 0 -Exactly
        Assert-MockCalled Remove-ValidatedInventoryFile -Times 1 -Exactly -ParameterFilter { $Ready }
    }

    It 'leaves JSON non-consumable and performs no cleanup when marker publication fails' {
        Mock Publish-InventoryTempFile {
            param($TempPath, $FinalPath)
            if ([System.IO.Path]::GetFileName($FinalPath) -ceq 'inventory.ready') { throw 'ready publish failed' }
            [System.IO.File]::Move($TempPath, $FinalPath)
        }

        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw '*ready publish failed*'

        Test-Path -LiteralPath $script:WriterFinal | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:WriterNonceDirectory 'inventory.ready') | Should -BeFalse
    }

    It 'leaves no consumable final package when <Stage> fails' -TestCases @(
        @{ Stage='create' }, @{ Stage='write' }, @{ Stage='flush' },
        @{ Stage='acl' }, @{ Stage='move' }, @{ Stage='recheck' }
    ) {
        param($Stage)
        if ($Stage -eq 'create') { Mock Initialize-TrustedInventoryDirectory { throw 'create failed' } }
        if ($Stage -eq 'write') { Mock Write-InventoryTempFile { param($Path) [System.IO.File]::WriteAllText($Path, 'partial'); throw 'write failed' } }
        if ($Stage -eq 'flush') { Mock Write-InventoryTempFile { param($Path) [System.IO.File]::WriteAllText($Path, 'complete but unflushed'); throw 'flush failed' } }
        if ($Stage -eq 'acl') { Mock Protect-InventoryPathAcl { throw 'ACL failed' } }
        if ($Stage -eq 'move') { Mock Publish-InventoryTempFile { throw 'move failed' } }
        if ($Stage -eq 'recheck') { Mock Read-TrustedInventoryJsonPackageAtPath { throw 'recheck failed' } }

        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw

        Test-Path -LiteralPath $script:WriterFinal | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:WriterNonceDirectory -Filter 'inventory.*.tmp').Count | Should -Be 0
    }

    It 'refuses an existing final package instead of replacing it' {
        [System.IO.File]::WriteAllText($script:WriterFinal, 'existing')
        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw '*exists*'
        [System.IO.File]::ReadAllText($script:WriterFinal) | Should -BeExactly 'existing'
    }

    It 'does not accept an arbitrary output path' {
        (Get-Command Write-TrustedInventoryPackage).Parameters.Keys | Should -Not -Contain 'Path'
        (Get-Command Write-TrustedInventoryPackage).Parameters.Keys | Should -Not -Contain 'OutputPath'
    }

    It 'removes a stale success marker before a new write attempt' {
        $readyPath = Join-Path $script:WriterNonceDirectory 'inventory.ready'
        [System.IO.File]::WriteAllText($readyPath, 'stale')
        Mock Write-InventoryTempFile { throw 'write failed' }

        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw '*write failed*'

        Test-Path -LiteralPath $readyPath | Should -BeFalse
    }

    It 'leaves leftover JSON non-consumable when final recheck and JSON deletion both fail' {
        Mock Publish-InventoryTempFile {
            param($TempPath, $FinalPath)
            [System.IO.File]::Move($TempPath, $FinalPath)
        }
        Mock Read-TrustedInventoryJsonPackageAtPath {
            param($Path)
            if ([System.IO.Path]::GetFileName([string]$Path) -ceq 'inventory.json') { throw 'final recheck failed' }
            [pscustomobject]@{ Package=$script:WriterPackage; Sha256=('0' * 64) }
        }
        Mock Remove-ValidatedInventoryFile {
            param($Path, $Nonce, $Final)
            if ([System.IO.Path]::GetFileName([string]$Path) -ceq 'inventory.json') { throw 'delete failed' }
        }

        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw '*final recheck failed*'

        Test-Path -LiteralPath $script:WriterFinal | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:WriterNonceDirectory 'inventory.ready') | Should -BeFalse
        Assert-MockCalled Read-TrustedInventoryJsonPackageAtPath -Times 2 -Exactly
        Assert-MockCalled Remove-ValidatedInventoryFile -Times 1 -Exactly -ParameterFilter { $Final }
        Assert-MockCalled Publish-InventoryTempFile -Times 0 -Exactly -ParameterFilter {
            [System.IO.Path]::GetFileName([string]$FinalPath) -ceq 'inventory.ready'
        }
        Mock Read-TrustedInventoryReadyMarker { throw 'inventory.ready is missing' }
        { Read-TrustedInventoryPackage $script:WriterNonce } | Should -Throw '*inventory.ready*'
    }

    It 'rejects an invalid nonce or package before creating trusted directories' {
        { Write-TrustedInventoryPackage -Nonce '..\inventory.json' -ReaderSid $script:ReaderSid -Package $script:WriterPackage } | Should -Throw '*nonce*'
        $invalidPackage = Copy-TestInventoryPackage $script:WriterPackage
        $invalidPackage.PSObject.Properties.Remove('health')
        { Write-TrustedInventoryPackage -Nonce $script:WriterNonce -ReaderSid $script:ReaderSid -Package $invalidPackage } | Should -Throw '*fields*'

        Assert-MockCalled Initialize-TrustedInventoryDirectory -Times 0 -Exactly
    }

    It 'refuses cleanup outside the exact nonce directory or through a reparse point' {
        $outside = Join-Path $script:WriterRoot 'inventory.00000000000000000000000000000000.tmp'
        [System.IO.File]::WriteAllText($outside, 'outside')
        { Remove-ValidatedInventoryFile -Path $outside -Nonce $script:WriterNonce } | Should -Throw '*directly inside*'
        Test-Path -LiteralPath $outside | Should -BeTrue

        $temp = Join-Path $script:WriterNonceDirectory 'inventory.00000000000000000000000000000000.tmp'
        [System.IO.File]::WriteAllText($temp, 'candidate')
        Mock Assert-InventoryPathIsNotReparsePoint { throw 'reparse point' }
        { Remove-ValidatedInventoryFile -Path $temp -Nonce $script:WriterNonce } | Should -Throw '*reparse*'
        Test-Path -LiteralPath $temp | Should -BeTrue
    }
}

Describe 'stale privileged inventory cleanup' {
    BeforeEach {
        $script:CleanupRoot = Join-Path $TestDrive 'ScanResults'
        $null = New-Item -ItemType Directory -Path $script:CleanupRoot -Force
        $script:OldNonce = 'c' * 64
        $script:OldPath = Join-Path $script:CleanupRoot $script:OldNonce
        $script:CleanupNow = [datetime]'2026-08-13T12:00:00Z'
        Mock Get-SecureInventoryRoot { $script:CleanupRoot }
        Mock Get-CurrentUserSid { $script:ReaderSid }
        Mock Assert-TrustedInventoryPathAcl {}
        Mock Assert-InventoryPathIsNotReparsePoint {}
        Mock Remove-TrustedInventoryDirectory {}
    }

    It 'does not expose caller-controlled cleanup root or reader SID parameters' {
        (Get-Command Remove-StaleTrustedInventoryPackages).Parameters.Keys | Should -Not -Contain 'Root'
        (Get-Command Remove-StaleTrustedInventoryPackages).Parameters.Keys | Should -Not -Contain 'ReaderSid'
    }

    It 'returns without enumeration or deletion when the fixed root is missing' {
        Remove-Item -LiteralPath $script:CleanupRoot -Force
        Mock Get-InventoryChildDirectories { throw 'must not enumerate a missing root' }

        { Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow } | Should -Not -Throw

        Assert-MockCalled Get-InventoryChildDirectories -Times 0 -Exactly
        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 0 -Exactly
    }

    It 'retains everything without enumeration when root <Reason> validation fails' -TestCases @(
        @{ Reason='ACL is untrusted'; Failure='Inventory path owner/ACL is not trusted' }
        @{ Reason='contains a reparse point'; Failure='Inventory path contains a reparse point' }
        @{ Reason='ACL inspection throws'; Failure='Inventory ACL read failed' }
    ) {
        param($Reason, $Failure)
        if ($Reason -eq 'contains a reparse point') {
            Mock Assert-InventoryPathIsNotReparsePoint { throw $Failure }
        } else {
            Mock Assert-TrustedInventoryPathAcl { throw $Failure }
        }
        Mock Get-InventoryChildDirectories { throw 'must not enumerate an untrusted root' }

        { Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow } | Should -Not -Throw

        Assert-MockCalled Get-InventoryChildDirectories -Times 0 -Exactly
        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 0 -Exactly
    }

    It 'deletes only an exact direct trusted non-reparse nonce directory older than 24 hours' {
        Mock Get-InventoryChildDirectories {
            [pscustomobject]@{ Name=$script:OldNonce; FullName=$script:OldPath; LastWriteTimeUtc=$script:CleanupNow.AddHours(-25) }
        }

        Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow

        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 1 -Exactly -ParameterFilter { $Path -ceq $script:OldPath }
    }

    It 'validates the root before enumeration and again immediately before deletion' {
        $script:CleanupOrder = @()
        Mock Assert-InventoryPathIsNotReparsePoint {
            param($Path)
            $script:CleanupOrder += "reparse:$Path"
        }
        Mock Assert-TrustedInventoryPathAcl {
            param($Path)
            $script:CleanupOrder += "acl:$Path"
        }
        Mock Get-InventoryChildDirectories {
            $script:CleanupOrder += 'enumerate'
            [pscustomobject]@{ Name=$script:OldNonce; FullName=$script:OldPath; LastWriteTimeUtc=$script:CleanupNow.AddHours(-25) }
        }
        Mock Remove-TrustedInventoryDirectory {
            param($Path)
            $script:CleanupOrder += "delete:$Path"
        }

        Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow

        $script:CleanupOrder | Should -Be @(
            "reparse:$($script:CleanupRoot)",
            "acl:$($script:CleanupRoot)",
            'enumerate',
            "reparse:$($script:OldPath)",
            "acl:$($script:OldPath)",
            "reparse:$($script:CleanupRoot)",
            "acl:$($script:CleanupRoot)",
            "delete:$($script:OldPath)"
        )
    }

    It 'retains a stale entry when <Reason> is uncertain or untrusted' -TestCases @(
        @{ Reason='name' }, @{ Reason='young' }, @{ Reason='boundary' }, @{ Reason='nested' }, @{ Reason='reparse' }, @{ Reason='acl' }
    ) {
        param($Reason)
        $name = if ($Reason -eq 'name') { 'not-a-nonce' } else { $script:OldNonce }
        $path = if ($Reason -eq 'nested') { Join-Path (Join-Path $script:CleanupRoot 'extra') $name } else { Join-Path $script:CleanupRoot $name }
        $age = if ($Reason -eq 'young') { $script:CleanupNow.AddHours(-23) } elseif ($Reason -eq 'boundary') { $script:CleanupNow.AddHours(-24) } else { $script:CleanupNow.AddHours(-25) }
        Mock Get-InventoryChildDirectories { [pscustomobject]@{ Name=$name; FullName=$path; LastWriteTimeUtc=$age } }
        if ($Reason -eq 'reparse') { Mock Assert-InventoryPathIsNotReparsePoint { throw 'reparse' } }
        if ($Reason -eq 'acl') { Mock Assert-TrustedInventoryPathAcl { throw 'ACL' } }

        Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow

        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 0 -Exactly
    }

    It 'retains all entries when root enumeration is uncertain' {
        Mock Get-InventoryChildDirectories { throw 'enumeration failed' }

        { Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow } | Should -Not -Throw
        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 0 -Exactly
    }

    It 'retains a candidate when deletion reports an error' {
        Mock Get-InventoryChildDirectories {
            [pscustomobject]@{ Name=$script:OldNonce; FullName=$script:OldPath; LastWriteTimeUtc=$script:CleanupNow.AddHours(-25) }
        }
        Mock Remove-TrustedInventoryDirectory { throw 'delete failed' }

        { Remove-StaleTrustedInventoryPackages -UtcNow $script:CleanupNow } | Should -Not -Throw
        Assert-MockCalled Remove-TrustedInventoryDirectory -Times 1 -Exactly
    }
}

Describe 'internal scan_inventory collector' {
    BeforeEach {
        $script:CollectorServiceExecutable = Join-Path $TestDrive 'svc.exe'
        $script:CollectorOtherExecutable = Join-Path $TestDrive 'other.exe'
        [System.IO.File]::WriteAllBytes($script:CollectorServiceExecutable, [byte[]](1))
        [System.IO.File]::WriteAllBytes($script:CollectorOtherExecutable, [byte[]](1))
        $script:CollectorServicePathName = '"' + $script:CollectorServiceExecutable + '" --service'
        $script:CollectorPid = 4242
        $script:CollectorStartUtc = [datetime]::SpecifyKind([datetime]'2026-08-13T08:09:10.1234567', [DateTimeKind]::Utc)
        $script:UnavailableIdentityWarning = [string]::Concat(
            [char]0x670D, [char]0x52A1, [char]0x8FDB, [char]0x7A0B, [char]0x8EAB,
            [char]0x4EFD, [char]0x4E0D, [char]0x53EF, [char]0x7528, [char]0x3002
        )
        $script:ServiceSnapshotQueryCount = 0
        $script:ProcessQueryCount = 0
        $script:CollectorFailureMode = ''
        if (-not (Get-Command Get-NativeProcessIdentity -ErrorAction SilentlyContinue)) {
            function Get-NativeProcessIdentity { param($ProcessId) return $null }
        }
        Mock Is-Admin { $true }
        Mock Get-NativeProcessIdentity { $null }
        Mock Get-CurrentUserSid { $script:ReaderSid }
        Mock Get-ServicesInfo {
            [pscustomobject]@{
                Name='Svc'; DisplayName='Service'; State='Running'; StartMode='Auto'
                PathName=$script:CollectorServicePathName; ProcessId=$script:CollectorPid; TriggerHint=$false
            }
        }
        Mock Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            if ($ClassName -ceq 'Win32_Service') {
                $script:ServiceSnapshotQueryCount++
                $snapshot = [ordered]@{
                    Name='Svc'; State='Running'; ProcessId=$script:CollectorPid
                    PathName=$script:CollectorServicePathName
                }
                $isSecond = $script:ServiceSnapshotQueryCount -eq 2
                switch ($script:CollectorFailureMode) {
                    'first-name' { if (-not $isSecond) { $snapshot.Name = 'OtherSvc' } }
                    'first-state' { if (-not $isSecond) { $snapshot.State = 'Stopped' } }
                    'first-pid' { if (-not $isSecond) { $snapshot.ProcessId = $script:CollectorPid + 1 } }
                    'first-pathname' { if (-not $isSecond) { $snapshot.PathName = '"' + $script:CollectorServiceExecutable + '" --changed' } }
                    'first-binary' { if (-not $isSecond) { $snapshot.PathName = '"' + $script:CollectorOtherExecutable + '" --service' } }
                    'second-name' { if ($isSecond) { $snapshot.Name = 'OtherSvc' } }
                    'second-state' { if ($isSecond) { $snapshot.State = 'Stopped' } }
                    'second-pid' { if ($isSecond) { $snapshot.ProcessId = $script:CollectorPid + 1 } }
                    'second-pathname' { if ($isSecond) { $snapshot.PathName = '"' + $script:CollectorServiceExecutable + '" --changed' } }
                    'second-binary' { if ($isSecond) { $snapshot.PathName = '"' + $script:CollectorOtherExecutable + '" --service' } }
                }
                return [pscustomobject]$snapshot
            }
            if ($ClassName -cne 'Win32_Process') { throw "unexpected CIM class $ClassName" }
            $script:ProcessQueryCount++
            if ($script:CollectorFailureMode -ceq 'access-denied') {
                throw 'Access denied C:\internal\secret token=collector-secret'
            }
            if ($script:CollectorFailureMode -ceq 'zero-processes') { return @() }
            $process = [ordered]@{
                ProcessId=$script:CollectorPid
                Name=[System.IO.Path]::GetFileName($script:CollectorServiceExecutable)
                ExecutablePath=$script:CollectorServiceExecutable
                CreationDate=$script:CollectorStartUtc
            }
            switch ($script:CollectorFailureMode) {
                'multiple-processes' { return @([pscustomobject]$process, [pscustomobject]$process) }
                'invalid-creation' { $process.CreationDate = 'not-a-date' }
                'unspecified-creation' { $process.CreationDate = [datetime]::SpecifyKind([datetime]'2026-08-13T08:09:10', [DateTimeKind]::Unspecified) }
                'future-creation' { $process.CreationDate = [datetime]::UtcNow.AddDays(1) }
                'process-pid' { $process.ProcessId = $script:CollectorPid + 1 }
                'process-name' { $process.Name = 'other.exe' }
                'path-missing' { $process.ExecutablePath = '' }
                'path-unrooted' { $process.ExecutablePath = 'svc.exe' }
                'path-mismatch' { $process.ExecutablePath = $script:CollectorOtherExecutable }
                'path-nonexistent' { $process.ExecutablePath = Join-Path $TestDrive 'missing.exe' }
                'native-valid' { $process.ExecutablePath = $null }
                'native-submicrosecond' {
                    $process.ExecutablePath = $null
                    $process.CreationDate = [datetime]::SpecifyKind([datetime]'2026-08-25T01:51:29.5408150', [DateTimeKind]::Utc)
                }
                'native-failure' { $process.ExecutablePath = $null }
                'native-name-mismatch' { $process.ExecutablePath = $null }
                'native-path-mismatch' { $process.ExecutablePath = $null }
                'native-start-mismatch' { $process.ExecutablePath = $null }
            }
            return [pscustomobject]$process
        }
        Mock Get-NativeProcessIdentity {
            if ($script:CollectorFailureMode -cnotin @('native-valid','native-submicrosecond','native-name-mismatch','native-path-mismatch','native-start-mismatch')) {
                return $null
            }
            $identity = [ordered]@{
                PID=[int]$script:CollectorPid
                Name=[System.IO.Path]::GetFileName($script:CollectorServiceExecutable)
                Path=$script:CollectorServiceExecutable
                StartTimeUtc='2026-08-13T08:09:10.1234567Z'
            }
            if ($script:CollectorFailureMode -ceq 'native-submicrosecond') { $identity.StartTimeUtc = '2026-08-25T01:51:29.5408156Z' }
            if ($script:CollectorFailureMode -ceq 'native-name-mismatch') { $identity.Name = 'other.exe' }
            if ($script:CollectorFailureMode -ceq 'native-path-mismatch') { $identity.Path = $script:CollectorOtherExecutable }
            if ($script:CollectorFailureMode -ceq 'native-start-mismatch') { $identity.StartTimeUtc = '2026-08-13T08:09:11.1234567Z' }
            return [pscustomobject]$identity
        }
        Mock Get-TasksInfo {
            [pscustomobject]@{ TaskName='Task';TaskPath='\Vendor\';State='Ready';LoginTrigger=$true;Author='Vendor';Description='Task description';Actions=@('C:\task.exe') }
        }
        Mock Remove-StaleTrustedInventoryPackages {}
        Mock Write-TrustedInventoryPackage { param($Nonce, $ReaderSid, $Package) $Package }
        Mock Write-ScanReport {}
        Mock Write-HtmlReport {}
        Mock Save-PendingActions {}
        Mock Invoke-Clean {}
        Mock Invoke-Restore {}
        Mock Invoke-StopProcessPending {}
        Mock Stop-Service {}
        Mock Set-Service {}
        Mock Remove-ItemProperty {}
        Mock Unregister-ScheduledTask {}
        Mock Invoke-ServiceConfigDisable {}
        Mock Invoke-ServiceDisableAction {}
        Mock Invoke-TaskDisableAction {}
        Mock Disable-ScheduledTask {}
        Mock Remove-LiteralRegistryValueFromKey {}
        Mock Invoke-LiteralAutostartRemovalFromKey {}
        Mock Invoke-LiteralAutostartRemoval {}
    }

    It 'rejects a non-administrator before collecting anything' {
        Mock Is-Admin { $false }
        { Invoke-ScanInventory -Nonce $script:Nonce } | Should -Throw '*administrator*'
        Assert-MockCalled Get-ServicesInfo -Times 0 -Exactly
        Assert-MockCalled Get-TasksInfo -Times 0 -Exactly
    }

    It 'rejects an invalid nonce before collecting anything' {
        { Invoke-ScanInventory -Nonce '..\inventory.json' } | Should -Throw '*nonce*'
        Assert-MockCalled Get-ServicesInfo -Times 0 -Exactly
        Assert-MockCalled Get-TasksInfo -Times 0 -Exactly
    }

    It 'captures a stable protected service process identity into the exact Task1 package shape' {
        $package = Invoke-ScanInventory -Nonce $script:Nonce

        { Assert-InventoryPackageShape $package $script:Nonce $script:ReaderSid ([datetime]::UtcNow) } | Should -Not -Throw
        @($package.PSObject.Properties.Name) | Should -Be @('inventory_schema_version','nonce','generated_utc','collector_sid','services','tasks','health','warnings')
        @($package.services[0].PSObject.Properties.Name) | Should -Be @('Name','DisplayName','State','StartMode','PathName','ProcessId','ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc')
        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'complete'
        $package.services[0].ProcessName | Should -BeExactly 'svc.exe'
        $package.services[0].ProcessPath | Should -BeExactly $script:CollectorServiceExecutable
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly '2026-08-13T08:09:10.1234567Z'
        @($package.tasks[0].PSObject.Properties.Name) | Should -Be @('TaskName','TaskPath','State','Author','Description','Actions')
        $package.tasks[0].Actions -is [System.Array] | Should -BeTrue
        @($package.tasks[0].Actions) | Should -Be @('C:\task.exe')
        $package.generated_utc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
        $script:ServiceSnapshotQueryCount | Should -Be 2
        $script:ProcessQueryCount | Should -Be 1
        @($package.warnings).Count | Should -Be 0
        Should -Invoke Get-NativeProcessIdentity -Times 0 -Exactly
    }

    It 'completes a protected service identity from the exact native PID when WMI path is null' {
        $script:CollectorFailureMode = 'native-valid'

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'complete'
        $package.services[0].ProcessName | Should -BeExactly 'svc.exe'
        $package.services[0].ProcessPath | Should -BeExactly $script:CollectorServiceExecutable
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly '2026-08-13T08:09:10.1234567Z'
        $script:ServiceSnapshotQueryCount | Should -Be 2
        $script:ProcessQueryCount | Should -Be 1
        Should -Invoke Get-NativeProcessIdentity -Times 1 -Exactly -ParameterFilter { $ProcessId -eq $script:CollectorPid }
        @($package.warnings).Count | Should -Be 0
    }

    It 'stores the full native 100ns start time when WMI agrees at microsecond precision' {
        $script:CollectorFailureMode = 'native-submicrosecond'

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'complete'
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly '2026-08-25T01:51:29.5408156Z'
        @($package.warnings).Count | Should -Be 0
    }

    It 'constructs only the ordered four-field process identity state' {
        $state = New-InventoryProcessIdentityState complete 'svc.exe' $script:CollectorServiceExecutable '2026-08-13T08:09:10.1234567Z'

        @($state.PSObject.Properties.Name) | Should -Be @('ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc')
        $state.ProcessIdentityStatus | Should -BeExactly 'complete'
        $state.ProcessName | Should -BeExactly 'svc.exe'
        $state.ProcessPath | Should -BeExactly $script:CollectorServiceExecutable
        $state.ProcessStartTimeUtc | Should -BeExactly '2026-08-13T08:09:10.1234567Z'
    }

    It 'uses collector-specific WQL escaping for a service name containing apostrophe and backslash' {
        $serviceName = "Vendor\O'Brien"
        $expectedServiceFilter = "Name = 'Vendor\\O\'Brien'"
        $script:SpecialQueryLog = [System.Collections.Generic.List[string]]::new()
        Mock Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            $script:SpecialQueryLog.Add("$ClassName|$Filter")
            if ($ClassName -ceq 'Win32_Service') {
                if ($Filter -cne $expectedServiceFilter) { throw 'malformed service filter rejected' }
                return [pscustomobject]@{
                    Name=$serviceName; State='Running'; ProcessId=$script:CollectorPid
                    PathName=$script:CollectorServicePathName
                }
            }
            if ($ClassName -ceq 'Win32_Process' -and $Filter -ceq "ProcessId = $($script:CollectorPid)") {
                return [pscustomobject]@{
                    ProcessId=$script:CollectorPid; Name='svc.exe'
                    ExecutablePath=$script:CollectorServiceExecutable; CreationDate=$script:CollectorStartUtc
                }
            }
            throw 'unexpected class or filter'
        }
        $record = [pscustomobject]@{
            Name=$serviceName; DisplayName='Special Service'; State='Running'; StartMode='Auto'
            PathName=$script:CollectorServicePathName; ProcessId=$script:CollectorPid
        }

        $identity = Get-PrivilegedServiceProcessIdentity $record

        $identity.ProcessIdentityStatus | Should -BeExactly 'complete'
        @($script:SpecialQueryLog) | Should -Be @(
            "Win32_Service|$expectedServiceFilter"
            "Win32_Process|ProcessId = $($script:CollectorPid)"
            "Win32_Service|$expectedServiceFilter"
        )
    }

    It 'fails closed with one sanitized warning for unavailable identity when <Case>' -TestCases @(
        @{ Case='process query is access denied'; Mode='access-denied' }
        @{ Case='process query returns zero processes'; Mode='zero-processes' }
        @{ Case='process query returns multiple processes'; Mode='multiple-processes' }
        @{ Case='CreationDate is invalid'; Mode='invalid-creation' }
        @{ Case='CreationDate has unspecified kind'; Mode='unspecified-creation' }
        @{ Case='CreationDate is in the future'; Mode='future-creation' }
        @{ Case='process PID mismatches'; Mode='process-pid' }
        @{ Case='process name mismatches'; Mode='process-name' }
        @{ Case='process path is missing'; Mode='path-missing' }
        @{ Case='process path is unrooted'; Mode='path-unrooted' }
        @{ Case='process path mismatches'; Mode='path-mismatch' }
        @{ Case='process path does not exist'; Mode='path-nonexistent' }
        @{ Case='native query fails and service config alone cannot authorize'; Mode='native-failure' }
        @{ Case='native process name mismatches WMI name'; Mode='native-name-mismatch' }
        @{ Case='native process path mismatches service binary'; Mode='native-path-mismatch' }
        @{ Case='native process start mismatches WMI creation'; Mode='native-start-mismatch' }
        @{ Case='first snapshot name mismatches'; Mode='first-name' }
        @{ Case='first snapshot state mismatches'; Mode='first-state' }
        @{ Case='first snapshot PID mismatches'; Mode='first-pid' }
        @{ Case='first snapshot PathName mismatches'; Mode='first-pathname' }
        @{ Case='first snapshot normalized binary mismatches'; Mode='first-binary' }
        @{ Case='second snapshot name drifts'; Mode='second-name' }
        @{ Case='second snapshot state drifts'; Mode='second-state' }
        @{ Case='second snapshot PID drifts'; Mode='second-pid' }
        @{ Case='second snapshot PathName drifts'; Mode='second-pathname' }
        @{ Case='second snapshot normalized binary drifts'; Mode='second-binary' }
    ) {
        param($Case, $Mode)
        $script:CollectorFailureMode = $Mode

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.health.services | Should -BeExactly 'complete'
        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'unavailable'
        $package.services[0].ProcessName | Should -BeExactly ''
        $package.services[0].ProcessPath | Should -BeExactly ''
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly ''
        @($package.warnings) | Should -Be @($script:UnavailableIdentityWarning)
        ($package.warnings -join '') | Should -Not -Match 'internal|secret|token=|collector-secret|Access denied|svc\.exe'
    }

    It 'publishes one complete and one unavailable service with intentional fixed warning and real routing' {
        $goodPid = 4242
        $badPid = 5252
        $goodPathName = '"' + $script:CollectorServiceExecutable + '" --service'
        $badPathName = '"' + $script:CollectorOtherExecutable + '" --service'
        $script:TwoServiceQueryLog = [System.Collections.Generic.List[string]]::new()
        Mock Get-ServicesInfo {
            @(
                [pscustomobject]@{ Name='GoodSvc';DisplayName='Good Service';State='Running';StartMode='Auto';PathName=$goodPathName;ProcessId=$goodPid }
                [pscustomobject]@{ Name='BadSvc';DisplayName='Bad Service';State='Running';StartMode='Auto';PathName=$badPathName;ProcessId=$badPid }
            )
        }
        Mock Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            $script:TwoServiceQueryLog.Add("$ClassName|$Filter")
            if ($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name = 'GoodSvc'") {
                return [pscustomobject]@{ Name='GoodSvc';State='Running';ProcessId=$goodPid;PathName=$goodPathName }
            }
            if ($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name = 'BadSvc'") {
                return [pscustomobject]@{ Name='BadSvc';State='Running';ProcessId=$badPid;PathName=$badPathName }
            }
            if ($ClassName -ceq 'Win32_Process' -and $Filter -ceq "ProcessId = $goodPid") {
                return [pscustomobject]@{
                    ProcessId=$goodPid; Name='svc.exe'; ExecutablePath=$script:CollectorServiceExecutable
                    CreationDate=$script:CollectorStartUtc
                }
            }
            if ($ClassName -ceq 'Win32_Process' -and $Filter -ceq "ProcessId = $badPid") {
                return [pscustomobject]@{
                    ProcessId=$badPid; Name='other.exe'; ExecutablePath=$null
                    CreationDate=$script:CollectorStartUtc
                }
            }
            throw 'unexpected class or filter'
        }
        Mock Get-NativeProcessIdentity { $null } -ParameterFilter { $ProcessId -eq $badPid }

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.health.services | Should -BeExactly 'complete'
        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'complete'
        $package.services[0].ProcessName | Should -BeExactly 'svc.exe'
        $package.services[1].ProcessIdentityStatus | Should -BeExactly 'unavailable'
        $package.services[1].ProcessName | Should -BeExactly ''
        $package.services[1].ProcessPath | Should -BeExactly ''
        $package.services[1].ProcessStartTimeUtc | Should -BeExactly ''
        @($package.warnings) | Should -Be @($script:UnavailableIdentityWarning)
        Should -Invoke Get-NativeProcessIdentity -Times 1 -Exactly -ParameterFilter { $ProcessId -eq $badPid }
        @($script:TwoServiceQueryLog) | Should -Be @(
            "Win32_Service|Name = 'GoodSvc'"
            "Win32_Process|ProcessId = $goodPid"
            "Win32_Service|Name = 'GoodSvc'"
            "Win32_Service|Name = 'BadSvc'"
            "Win32_Process|ProcessId = $badPid"
        )
    }

    It 'marks Running PID zero unavailable without failing service enumeration health' {
        Mock Get-ServicesInfo {
            [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Running';StartMode='Auto';PathName=$script:CollectorServicePathName;ProcessId=0 }
        }

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.health.services | Should -BeExactly 'complete'
        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'unavailable'
        $package.services[0].ProcessName | Should -BeExactly ''
        $package.services[0].ProcessPath | Should -BeExactly ''
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly ''
        @($package.warnings) | Should -Be @($script:UnavailableIdentityWarning)
        $script:ProcessQueryCount | Should -Be 0
    }

    It 'fails closed before CIM for inconsistent or non-strict collected state PID <Case>' -TestCases @(
        @{ Case='Stopped positive'; State='Stopped'; ProcessId=12 }
        @{ Case='Running negative'; State='Running'; ProcessId=-1 }
        @{ Case='Running string'; State='Running'; ProcessId='4242' }
        @{ Case='Running above Int32'; State='Running'; ProcessId=([uint64][int]::MaxValue + 1) }
    ) {
        param($Case, $State, $ProcessId)
        Reset-ScanDiagnostics
        $record = [pscustomobject]@{
            Name='Svc'; DisplayName='Service'; State=$State; StartMode='Auto'
            PathName=$script:CollectorServicePathName; ProcessId=$ProcessId
        }

        $identity = Get-PrivilegedServiceProcessIdentity $record

        $identity.ProcessIdentityStatus | Should -BeExactly 'unavailable'
        $identity.ProcessName | Should -BeExactly ''
        $identity.ProcessPath | Should -BeExactly ''
        $identity.ProcessStartTimeUtc | Should -BeExactly ''
        @($script:ScanWarnings) | Should -Be @($script:UnavailableIdentityWarning)
        $script:ServiceSnapshotQueryCount | Should -Be 0
        $script:ProcessQueryCount | Should -Be 0
    }

    It 'marks a stopped PID zero service not_running and never queries Win32_Process' {
        Mock Get-ServicesInfo {
            [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Stopped';StartMode='Manual';PathName=$script:CollectorServicePathName;ProcessId=0 }
        }

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.services[0].ProcessIdentityStatus | Should -BeExactly 'not_running'
        $package.services[0].ProcessName | Should -BeExactly ''
        $package.services[0].ProcessPath | Should -BeExactly ''
        $package.services[0].ProcessStartTimeUtc | Should -BeExactly ''
        $script:ServiceSnapshotQueryCount | Should -Be 0
        $script:ProcessQueryCount | Should -Be 0
        @($package.warnings).Count | Should -Be 0
    }

    It 'preserves multiple scanner task Actions as an array' {
        Mock Get-TasksInfo {
            [pscustomobject]@{
                TaskName='Task';TaskPath='\Vendor\';State='Ready';LoginTrigger=$true
                Author='Vendor';Description='Task description';Actions=@('C:\first.exe','C:\second.exe')
            }
        }

        $package = Invoke-ScanInventory -Nonce $script:Nonce

        $package.tasks[0].Actions -is [System.Array] | Should -BeTrue
        @($package.tasks[0].Actions) | Should -Be @('C:\first.exe','C:\second.exe')
    }

    It 'rejects missing required service collection fields before publication' {
        $record = [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Running';StartMode='Auto';ProcessId=12 }
        { ConvertTo-InventoryServiceRecord $record } | Should -Throw '*PathName*'
    }

    It 'rejects malformed base service field <Field> before privileged capture' -TestCases @(
        @{ Field='Name'; Value='' }
        @{ Field='DisplayName'; Value=@('Service') }
        @{ Field='State'; Value=' ' }
        @{ Field='StartMode'; Value=7 }
        @{ Field='PathName'; Value=@('C:\svc.exe') }
        @{ Field='ProcessId'; Value='4242' }
        @{ Field='ProcessId'; Value=-1 }
        @{ Field='ProcessId'; Value=([uint64][uint32]::MaxValue + 1) }
    ) {
        param($Field, $Value)
        Mock Get-PrivilegedServiceProcessIdentity { throw 'privileged capture must not run' }
        $record = [pscustomobject][ordered]@{
            Name='Svc'; DisplayName='Service'; State='Running'; StartMode='Auto'
            PathName=$script:CollectorServicePathName; ProcessId=$script:CollectorPid
        }
        $record.$Field = $Value

        { ConvertTo-InventoryServiceRecord $record } | Should -Throw "*$Field*"

        Assert-MockCalled Get-PrivilegedServiceProcessIdentity -Times 0 -Exactly
        Assert-MockCalled Get-CimInstance -Times 0 -Exactly
    }

    It 'independently recaptures identity exactly once and ignores supplied identity properties' {
        Mock Get-PrivilegedServiceProcessIdentity {
            New-InventoryProcessIdentityState unavailable '' '' ''
        }
        $record = [pscustomobject]@{
            Name='Svc'; DisplayName='Service'; State='Running'; StartMode='Auto'
            PathName=$script:CollectorServicePathName; ProcessId=$script:CollectorPid
            ProcessIdentityStatus='complete'; ProcessName='attacker.exe'; ProcessPath='C:\attacker.exe'
            ProcessStartTimeUtc='2026-08-13T00:00:00.0000000Z'
        }

        $converted = ConvertTo-InventoryServiceRecord $record

        $converted.ProcessIdentityStatus | Should -BeExactly 'unavailable'
        $converted.ProcessName | Should -BeExactly ''
        $converted.ProcessPath | Should -BeExactly ''
        $converted.ProcessStartTimeUtc | Should -BeExactly ''
        Assert-MockCalled Get-PrivilegedServiceProcessIdentity -Times 1 -Exactly
    }

    It 'rejects missing required task metadata before publication' {
        $record = [pscustomobject]@{ TaskName='Task';TaskPath='\';State='Ready';Description='Description';Actions=@('C:\task.exe') }
        { ConvertTo-InventoryTaskRecord $record } | Should -Throw '*Author*'
    }

    It 'rejects a scanner task without required Actions instead of fabricating an empty array' {
        Mock Get-TasksInfo {
            [pscustomobject]@{ TaskName='Task';TaskPath='\Vendor\';State='Ready';LoginTrigger=$true;Author='Vendor';Description='Task description' }
        }

        { Invoke-ScanInventory -Nonce $script:Nonce } | Should -Throw '*Actions*'
        Assert-MockCalled Write-TrustedInventoryPackage -Times 0 -Exactly
    }

    It 'rejects empty or incomplete collection and never publishes it' -TestCases @(
        @{ Category='services' }, @{ Category='tasks' }, @{ Category='health' }, @{ Category='service_fallback' }, @{ Category='record' }
    ) {
        param($Category)
        if ($Category -eq 'services') { Mock Get-ServicesInfo { @() } }
        if ($Category -eq 'tasks') { Mock Get-TasksInfo { @() } }
        if ($Category -eq 'health') { Mock Get-TasksInfo { $script:ScanHealth.tasks='degraded'; [pscustomobject]@{TaskName='Task';TaskPath='\';State='Ready';LoginTrigger=$false} } }
        if ($Category -eq 'service_fallback') { Mock Get-ServicesInfo { $script:ScanHealth.services='degraded'; [pscustomobject]@{Name='Svc';DisplayName='Service';State='Running';StartMode='Manual';PathName='';ProcessId=0} } }
        if ($Category -eq 'record') { Mock Get-ServicesInfo { [pscustomobject]@{Name='';DisplayName='';State='';StartMode='';PathName='';ProcessId=0} } }

        { Invoke-ScanInventory -Nonce $script:Nonce } | Should -Throw
        Assert-MockCalled Write-TrustedInventoryPackage -Times 0 -Exactly
    }

    It 'invokes no mutation report or pending path for complete unavailable and not_running identities' {
        foreach ($state in @('complete','unavailable','not_running')) {
            if ($state -ceq 'unavailable') { $script:CollectorFailureMode = 'access-denied' }
            elseif ($state -ceq 'not_running') {
                Mock Get-ServicesInfo {
                    [pscustomobject]@{ Name='Svc';DisplayName='Service';State='Stopped';StartMode='Manual';PathName=$script:CollectorServicePathName;ProcessId=0 }
                }
            }
            $null = Invoke-ScanInventory -Nonce $script:Nonce
        }

        foreach ($command in @('Write-ScanReport','Write-HtmlReport','Save-PendingActions','Invoke-Clean','Invoke-Restore','Invoke-StopProcessPending','Stop-Service','Set-Service','Remove-ItemProperty','Unregister-ScheduledTask','Invoke-ServiceConfigDisable','Invoke-ServiceDisableAction','Invoke-TaskDisableAction','Disable-ScheduledTask','Remove-LiteralRegistryValueFromKey','Invoke-LiteralAutostartRemovalFromKey','Invoke-LiteralAutostartRemoval')) {
            Assert-MockCalled $command -Times 0 -Exactly
        }
    }
}

Describe 'scan_inventory CLI contract and early dispatch' {
    BeforeAll {
        $script:CliSource = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $script:CliAst = [System.Management.Automation.Language.Parser]::ParseInput($script:CliSource, [ref]$null, [ref]$null)
    }

    It 'declares scan_inventory InventoryNonce and AllowLimited without an inventory output path' {
        $script:CliSource | Should -Match "ValidateSet\([^\)]*'scan_inventory'"
        @($script:CliAst.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Contain 'InventoryNonce'
        @($script:CliAst.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Contain 'AllowLimited'
        @($script:CliAst.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Not -Contain 'InventoryOutputPath'
    }

    It 'dispatches scan_inventory before the normal scan branch and rejects unrelated arguments' {
        $inventoryIndex = $script:CliSource.IndexOf("'scan_inventory'")
        $scanIndex = $script:CliSource.IndexOf("'scan' {", $inventoryIndex + 1)
        $inventoryIndex | Should -BeGreaterThan -1
        $scanIndex | Should -BeGreaterThan $inventoryIndex
        $script:CliSource | Should -Match "'scan_inventory'\s*\{[\s\S]*Invoke-ScanInventory"
        $script:CliSource | Should -Match 'scan_inventory accepts only InventoryNonce'
    }
}
