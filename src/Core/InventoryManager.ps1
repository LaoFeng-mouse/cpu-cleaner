# Trusted reader for nonce-bound privileged scan inventory packages.
$script:InventorySchemaVersion = 3
$script:MaxInventoryJsonBytes = 8MB
$script:MaxInventoryJsonDepth = 12
$script:MaxInventoryRecords = 20000
$script:MaxInventoryReadyBytes = 256
$script:MaxInventoryProcessNameLength = 260
$script:MaxInventoryProcessPathLength = 32767
$script:TrustedInventorySystemSid = 'S-1-5-18'
$script:TrustedInventoryAdministratorsSid = 'S-1-5-32-544'

function Test-InventoryNonce([string]$Nonce) {
    return (-not [string]::IsNullOrEmpty($Nonce) -and $Nonce -cmatch '^[0-9a-f]{64}$')
}

function Get-SecureInventoryRoot {
    $programData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw 'ProgramData inventory root is unavailable.' }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($programData, 'MouseCleaner', 'ScanResults'))
}

function Resolve-InventoryPackagePath([string]$Nonce) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    $root = [System.IO.Path]::GetFullPath((Get-SecureInventoryRoot)).TrimEnd('\', '/')
    $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $Nonce, 'inventory.json'))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory package path escaped the fixed trust root.'
    }
    return $path
}

function Resolve-InventoryReadyPath([string]$Nonce) {
    $inventoryPath = Resolve-InventoryPackagePath $Nonce
    return [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($inventoryPath), 'inventory.ready')
}

function Get-CurrentUserSid {
    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity -or $null -eq $identity.User) { throw 'Current Windows identity SID is unavailable.' }
        return $identity.User.Value
    } finally {
        if ($null -ne $identity) { $identity.Dispose() }
    }
}

function Test-InventoryInteger($Value) {
    return ($Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64])
}

function Get-InventoryAclDescriptor($Path) {
    try {
        $acl = Get-LocalFileSystemAcl -Path $Path
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
            [pscustomobject]@{
                Sid = $_.IdentityReference.Value
                Type = $_.AccessControlType.ToString()
                Rights = [int64]$_.FileSystemRights
                Inherited = [bool]$_.IsInherited
                AppliesToCurrentObject = (($_.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0)
            }
        })
        return [pscustomobject]@{ OwnerSid=$owner; Protected=[bool]$acl.AreAccessRulesProtected; Rules=$rules }
    } catch {
        throw ('Inventory ACL read failed: ' + $_.Exception.Message)
    }
}

function Test-TrustedInventoryAclDescriptor($Descriptor, [string]$ReaderSid) {
    if ($null -eq $Descriptor -or [string]::IsNullOrWhiteSpace($ReaderSid)) { return $false }
    if ($Descriptor.OwnerSid -isnot [string] -or
        $Descriptor.OwnerSid -cnotin @($script:TrustedInventorySystemSid, $script:TrustedInventoryAdministratorsSid)) { return $false }
    if ($Descriptor.Protected -isnot [bool] -or -not $Descriptor.Protected) { return $false }
    if ($null -eq $Descriptor.Rules -or $Descriptor.Rules -isnot [System.Array]) { return $false }

    # Composite rights also contain read bits, so only primitive mutation bits
    # and raw generic mutation bits are safe to combine into this mask.
    $genericWriteMask = [Convert]::ToInt64('40000000', 16)
    $genericAllMask = [Convert]::ToInt64('10000000', 16)
    $mutationMask = [int64]([System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    $mutationMask = $mutationMask -bor $genericWriteMask -bor $genericAllMask
    $readDataMask = [int64][System.Security.AccessControl.FileSystemRights]::ReadData
    $readControlMask = [int64][System.Security.AccessControl.FileSystemRights]::ReadPermissions
    $readerAllow = [int64]0
    $trustedAllows = @{
        $script:TrustedInventorySystemSid = [int64]0
        $script:TrustedInventoryAdministratorsSid = [int64]0
    }

    foreach ($rule in @($Descriptor.Rules)) {
        if ($null -eq $rule -or $rule.Sid -isnot [string] -or $rule.Type -isnot [string] -or
            -not (Test-InventoryInteger $rule.Rights) -or $rule.Inherited -ne $false -or
            $rule.AppliesToCurrentObject -isnot [bool] -or -not $rule.AppliesToCurrentObject) { return $false }
        # Any deny entry or unfamiliar access-control type makes effective-rights proof ambiguous.
        if ($rule.Type -cne 'Allow') { return $false }
        $rights = [int64]$rule.Rights
        if (($rights -band $mutationMask) -ne 0) {
            if ($rule.Sid -cnotin @($script:TrustedInventorySystemSid, $script:TrustedInventoryAdministratorsSid)) { return $false }
        }
        if ($trustedAllows.ContainsKey($rule.Sid)) { $trustedAllows[$rule.Sid] = [int64]$trustedAllows[$rule.Sid] -bor $rights }
        if ($rule.Sid -ceq $ReaderSid) { $readerAllow = $readerAllow -bor $rights }
    }

    # Require concrete FullControl for both trusted principals. Raw GENERIC_ALL is
    # deliberately not expanded here because this descriptor may be synthetic or
    # unnormalized; the Windows filesystem ACL API returns normalized concrete FileSystemRights.
    $fullControlMask = [int64][System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($trustedSid in @($script:TrustedInventorySystemSid, $script:TrustedInventoryAdministratorsSid)) {
        if (([int64]$trustedAllows[$trustedSid] -band $fullControlMask) -ne $fullControlMask) { return $false }
    }
    if (($readerAllow -band $mutationMask) -ne 0) { return $false }
    if (($readerAllow -band $readDataMask) -ne $readDataMask -or
        ($readerAllow -band $readControlMask) -ne $readControlMask) { return $false }
    return $true
}

function Assert-TrustedInventoryPathAcl($Path, [string]$ReaderSid) {
    $descriptor = Get-InventoryAclDescriptor $Path
    if (-not (Test-TrustedInventoryAclDescriptor $descriptor $ReaderSid)) {
        throw "Inventory path owner/ACL is not trusted: $Path"
    }
}

function Get-ExistingInventoryPathComponents($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw 'Inventory path is invalid.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'Inventory path root is invalid.' }
    Write-Output $root
    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = [System.IO.Path]::Combine($current, $segment)
        Write-Output $current
    }
}

function Get-InventoryPathAttributes([string]$Path) {
    return [System.IO.File]::GetAttributes($Path)
}

function Assert-InventoryPathIsNotReparsePoint($Path) {
    foreach ($component in @(Get-ExistingInventoryPathComponents $Path)) {
        $attributes = Get-InventoryPathAttributes $component
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Inventory path contains a reparse point: $component"
        }
    }
}

function Open-TrustedInventoryReadStream($Path) {
    Assert-InventoryPathIsNotReparsePoint $Path
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        if (-not (Test-OpenedPendingFileIdentity -Stream $stream -Path $Path)) {
            throw 'Inventory file handle identity does not match the expected final path.'
        }
        if (-not (Test-OpenedPendingFileHasSingleLink -Stream $stream)) {
            throw 'Inventory file hardlink count is not exactly one.'
        }
        Assert-InventoryPathIsNotReparsePoint $Path
        return $stream
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Read-LimitedInventorySnapshot($Stream) {
    if ($null -eq $Stream -or -not $Stream.CanRead -or -not $Stream.CanSeek) { throw 'Inventory stream is not readable and seekable.' }
    $Stream.Position = 0
    $length = $Stream.Length
    if (-not (Test-InventoryInteger $length) -or [int64]$length -lt 0 -or [int64]$length -gt [int64]$script:MaxInventoryJsonBytes) {
        throw "Inventory JSON is too large (maximum $script:MaxInventoryJsonBytes bytes)."
    }
    $bytes = New-Object byte[] ([int]$length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) { throw 'Inventory JSON ended before the locked snapshot was complete.' }
        $offset += $read
    }
    if ($Stream.Length -ne $length -or $Stream.Position -ne $length) {
        throw 'Inventory JSON changed while the locked snapshot was read.'
    }
    return $bytes
}

function ConvertFrom-InventorySnapshotBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes) { throw 'Inventory UTF-8 snapshot is null.' }
    $offset = 0
    if ($Bytes.Length -gt 0 -and $Bytes[0] -eq 0xEF) {
        if ($Bytes.Length -lt 3 -or $Bytes[1] -ne 0xBB -or $Bytes[2] -ne 0xBF) {
            throw 'Inventory UTF-8 BOM is malformed.'
        }
        $offset = 3
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        return $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    } catch {
        throw ('Inventory UTF-8 is malformed: ' + $_.Exception.Message)
    }
}

function ConvertFrom-StrictInventoryJson([string]$Json) {
    if ($Json -isnot [string]) { throw 'Inventory JSON must be text.' }
    $oldDepth = $script:MaxPendingJsonDepth
    try {
        $script:MaxPendingJsonDepth = $script:MaxInventoryJsonDepth
        try {
            Assert-JsonPropertyNamesUnique $Json
        } catch {
            $duplicateWord = [string]::Concat([char]0x91CD, [char]0x590D)
            $depthWord = [string]::Concat([char]0x6DF1, [char]0x5EA6)
            if ($_.Exception.Message.Contains($duplicateWord)) { throw ('Inventory JSON has a duplicate property: ' + $_.Exception.Message) }
            if ($_.Exception.Message.Contains($depthWord)) { throw ('Inventory JSON depth exceeds the limit: ' + $_.Exception.Message) }
            throw
        }
        $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
        if ($convertCommand.Parameters.ContainsKey('DateKind')) {
            return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
        }
        return $Json | ConvertFrom-Json -ErrorAction Stop
    } finally {
        $script:MaxPendingJsonDepth = $oldDepth
    }
}

function Test-InventoryExactProperties($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($null -eq $Value -or $Value -is [System.Array] -or $Value -is [string] -or $Value -is [ValueType]) { return $false }
    $allowed = @($Required) + @($Optional)
    $names = @($Value.PSObject.Properties.Name)
    if ($names.Count -lt $Required.Count -or $names.Count -gt $allowed.Count) { return $false }
    foreach ($requiredName in $Required) { if ($names -cnotcontains $requiredName) { return $false } }
    foreach ($name in $names) { if ($allowed -cnotcontains $name) { return $false } }
    return $true
}

function Test-InventoryString($Value, [bool]$AllowEmpty = $false) {
    if ($Value -isnot [string]) { return $false }
    return ($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Value))
}

function ConvertFrom-InventoryCanonicalUtc($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') {
        return $null
    }
    try {
        $parsed = [datetimeoffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [datetimeoffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed) -or
            $parsed.Offset -ne [timespan]::Zero) {
            return $null
        }
        return $parsed
    } catch {
        return $null
    }
}

function Test-InventoryBoundedCleanString($Value, [int]$MaxLength) {
    if ($Value -isnot [string] -or $MaxLength -lt 1 -or $Value.Length -eq 0 -or $Value.Length -gt $MaxLength) { return $false }
    if ($Value -cne $Value.Trim()) { return $false }
    return ($Value -cnotmatch '[\x00-\x1F\x7F-\x9F]')
}

function Test-InventoryFullyQualifiedWindowsPath($Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value -cmatch '^[A-Za-z]:[\\/]') { return $true }
    return ($Value -cmatch '^[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/].*)?$')
}

function ConvertFrom-InventoryServicePathName([string]$PathName) {
    if ($PathName -isnot [string] -or [string]::IsNullOrWhiteSpace($PathName) -or $PathName -cne $PathName.Trim()) { return $null }
    if ($PathName -cmatch '^"([^"\r\n]+\.exe)"(?:\s+.*)?$') { return $matches[1] }
    if ($PathName -cmatch '^([^\s"]+\.exe)(?:\s+.*)?$') { return $matches[1] }
    return $null
}

function Assert-InventoryServiceBaseRecord($Record) {
    foreach ($name in @('Name','DisplayName','State','StartMode')) {
        if (-not (Test-InventoryString $Record.$name)) { throw "Inventory service $name is invalid." }
    }
    if (-not (Test-InventoryString $Record.PathName $true)) { throw 'Inventory service PathName is invalid.' }
    if (-not (Test-InventoryInteger $Record.ProcessId) -or [int64]$Record.ProcessId -lt 0 -or [uint64]$Record.ProcessId -gt [uint64][uint32]::MaxValue) {
        throw 'Inventory service ProcessId is invalid.'
    }
}

function Assert-InventoryLaunchProtectedShape($Record) {
    if ($Record.LaunchProtectedStatus -isnot [string] -or
        $Record.LaunchProtectedStatus -cnotin @('complete','unavailable')) {
        throw 'Inventory service LaunchProtectedStatus is invalid.'
    }
    if (-not (Test-InventoryInteger $Record.LaunchProtectedLevel)) {
        throw 'Inventory service LaunchProtectedLevel is invalid.'
    }
    $level = [int64]$Record.LaunchProtectedLevel
    if (($Record.LaunchProtectedStatus -ceq 'complete' -and ($level -lt 0 -or $level -gt 3)) -or
        ($Record.LaunchProtectedStatus -ceq 'unavailable' -and $level -ne -1)) {
        throw 'Inventory service LaunchProtected status and level are inconsistent.'
    }
}

function Assert-InventoryUninstallEvidenceShape($Record) {
    $stringFields = @(
        'UninstallRegistryPath','UninstallDisplayName','UninstallPublisher','UninstallDisplayVersion',
        'UninstallInstallLocation','UninstallString','UninstallExecutablePath'
    )
    if ($Record.UninstallEvidenceStatus -isnot [string] -or
        $Record.UninstallEvidenceStatus -cnotin @('complete','unavailable')) {
        throw 'Inventory service uninstall evidence status is invalid.'
    }
    foreach ($name in $stringFields) {
        if ($Record.$name -isnot [string]) { throw "Inventory service uninstall evidence $name is invalid." }
    }

    if ($Record.UninstallEvidenceStatus -ceq 'unavailable') {
        foreach ($name in $stringFields) {
            if ($Record.$name -cne '') { throw 'Inventory service unavailable uninstall evidence must be completely empty.' }
        }
        return
    }

    foreach ($name in @('UninstallRegistryPath','UninstallDisplayName','UninstallPublisher','UninstallInstallLocation','UninstallString','UninstallExecutablePath')) {
        if (-not (Test-InventoryBoundedCleanString $Record.$name $script:MaxInventoryProcessPathLength)) {
            throw "Inventory service complete uninstall evidence $name is not a clean nonblank string."
        }
    }
    if ($Record.UninstallDisplayVersion -cne '' -and
        -not (Test-InventoryBoundedCleanString $Record.UninstallDisplayVersion $script:MaxInventoryProcessPathLength)) {
        throw 'Inventory service uninstall evidence DisplayVersion is not a clean string.'
    }

    if ($Record.Name -isnot [string] -or
        -not [string]::Equals($Record.Name, 'HRWSCCtrl', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory service complete uninstall evidence is not authorized for this service.'
    }
    if (-not (Test-LenovoOfficialUninstallRegistryPath -RegistryPath $Record.UninstallRegistryPath)) {
        throw 'Inventory service uninstall registry path is not an allowed Lenovo uninstall key.'
    }
    $displayNameAllowed = $false
    foreach ($prefix in $script:LenovoOfficialUninstallDisplayNamePrefixes) {
        if ($Record.UninstallDisplayName.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $displayNameAllowed = $true
            break
        }
    }
    if (-not $displayNameAllowed) {
        throw 'Inventory service uninstall display name is not allowed.'
    }
    if (-not ($script:LenovoOfficialUninstallPublishers -ccontains $Record.UninstallPublisher)) {
        throw 'Inventory service uninstall publisher is not allowed.'
    }

    $installLocation = $Record.UninstallInstallLocation
    if (-not (Test-StrictOfficialUninstallLocalDrivePath -Path $installLocation)) {
        throw 'Inventory service uninstall install location is invalid.'
    }
    try { $canonicalInstallLocation = [System.IO.Path]::GetFullPath($installLocation) }
    catch { throw 'Inventory service uninstall install location is invalid.' }
    if (-not (Test-StrictOfficialUninstallLocalDrivePath -Path $canonicalInstallLocation) -or
        -not $installLocation.Equals($canonicalInstallLocation, [System.StringComparison]::Ordinal) -or
        $canonicalInstallLocation.Equals([System.IO.Path]::GetPathRoot($canonicalInstallLocation), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory service uninstall install location is not a canonical ordinary local directory.'
    }

    $rawExecutablePath = if ($Record.UninstallString -cmatch '^"([^"\r\n]+\.exe)"$') { $matches[1] }
        elseif ($Record.UninstallString -cmatch '^([^"\r\n]+\.exe)$') { $matches[1] }
        else { $null }
    if ($rawExecutablePath -isnot [string]) {
        throw 'Inventory service uninstall command or executable path is invalid.'
    }
    try { $canonicalRawExecutablePath = [System.IO.Path]::GetFullPath($rawExecutablePath) }
    catch { throw 'Inventory service uninstall command or executable path is invalid.' }
    if (-not $rawExecutablePath.Equals($canonicalRawExecutablePath, [System.StringComparison]::Ordinal)) {
        throw 'Inventory service raw uninstall command path is not canonical.'
    }

    $parsedExecutablePath = ConvertFrom-StrictOfficialUninstallString -Command $Record.UninstallString
    if ($parsedExecutablePath -isnot [string] -or
        -not $Record.UninstallExecutablePath.Equals($parsedExecutablePath, [System.StringComparison]::Ordinal)) {
        throw 'Inventory service uninstall command or executable path is invalid.'
    }
    $installBoundary = $canonicalInstallLocation.TrimEnd('\') + '\'
    if (-not $parsedExecutablePath.StartsWith($installBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory service uninstall executable is outside the install location.'
    }
}

function Assert-InventoryServiceRecord($Record, [datetimeoffset]$GeneratedUtc) {
    $required = @(
        'Name','DisplayName','State','StartMode','PathName','ProcessId','ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc',
        'LaunchProtectedStatus','LaunchProtectedLevel','UninstallEvidenceStatus','UninstallRegistryPath','UninstallDisplayName','UninstallPublisher',
        'UninstallDisplayVersion','UninstallInstallLocation','UninstallString','UninstallExecutablePath'
    )
    if (-not (Test-InventoryExactProperties $Record $required)) { throw 'Inventory service record fields are invalid.' }
    Assert-InventoryServiceBaseRecord $Record
    if ($Record.ProcessIdentityStatus -isnot [string] -or
        $Record.ProcessIdentityStatus -cnotin @('complete','not_running','unavailable')) {
        throw 'Inventory service ProcessIdentityStatus is invalid.'
    }
    foreach ($name in @('ProcessName','ProcessPath','ProcessStartTimeUtc')) {
        if ($Record.$name -isnot [string]) { throw "Inventory service $name is invalid." }
    }
    Assert-InventoryLaunchProtectedShape $Record
    Assert-InventoryUninstallEvidenceShape $Record

    if ($Record.ProcessIdentityStatus -ceq 'complete') {
        if ($Record.State -cne 'Running' -or [int64]$Record.ProcessId -le 0 -or
            [uint64]$Record.ProcessId -gt [uint64][int]::MaxValue) {
            throw 'Inventory service complete process identity state or PID is invalid.'
        }
        if (-not (Test-InventoryBoundedCleanString $Record.ProcessName $script:MaxInventoryProcessNameLength) -or
            $Record.ProcessName -cne [System.IO.Path]::GetFileName($Record.ProcessName) -or
            $Record.ProcessName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw 'Inventory service ProcessName is invalid.'
        }
        if (-not (Test-InventoryBoundedCleanString $Record.ProcessPath $script:MaxInventoryProcessPathLength) -or
            -not (Test-InventoryFullyQualifiedWindowsPath $Record.ProcessPath)) {
            throw 'Inventory service ProcessPath is invalid.'
        }
        try { $processPath = [System.IO.Path]::GetFullPath($Record.ProcessPath) }
        catch { throw 'Inventory service ProcessPath is invalid.' }
        if (-not [System.IO.File]::Exists($processPath) -or
            -not [string]::Equals([System.IO.Path]::GetFileName($processPath), $Record.ProcessName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inventory service process filename or path is invalid.'
        }
        $serviceBinary = ConvertFrom-InventoryServicePathName $Record.PathName
        if ($serviceBinary -isnot [string] -or -not (Test-InventoryFullyQualifiedWindowsPath $serviceBinary)) {
            throw 'Inventory service PathName binary is invalid.'
        }
        try { $serviceBinary = [System.IO.Path]::GetFullPath($serviceBinary) }
        catch { throw 'Inventory service PathName binary is invalid.' }
        if (-not [string]::Equals($serviceBinary, $processPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inventory service PathName binary does not match ProcessPath.'
        }
        $processStart = ConvertFrom-InventoryCanonicalUtc $Record.ProcessStartTimeUtc
        if ($null -eq $processStart) { throw 'Inventory service ProcessStartTimeUtc is invalid.' }
        if ($processStart -gt $GeneratedUtc) { throw 'Inventory service process start time is after package generation.' }
        return
    }

    if ($Record.ProcessName -cne '' -or $Record.ProcessPath -cne '' -or $Record.ProcessStartTimeUtc -cne '') {
        throw 'Inventory service process identity must be completely empty.'
    }
    if ($Record.ProcessIdentityStatus -ceq 'not_running' -and
        ($Record.State -ceq 'Running' -or [int64]$Record.ProcessId -ne 0)) {
        throw 'Inventory service not_running state or PID is invalid.'
    }
}

function Assert-InventoryTaskRecord($Record) {
    $required = @('TaskName','TaskPath','State','Author','Description','Actions')
    if (-not (Test-InventoryExactProperties $Record $required)) { throw 'Inventory task record fields are invalid.' }
    if (-not (Test-InventoryString $Record.TaskName)) { throw 'Inventory task TaskName is invalid.' }
    if (-not (Test-InventoryString $Record.TaskPath) -or -not $Record.TaskPath.StartsWith('\', [System.StringComparison]::Ordinal)) {
        throw 'Inventory task TaskPath is invalid.'
    }
    $validStateNames = @('Unknown','Disabled','Queued','Ready','Running')
    $stateIsValid = ((Test-InventoryString $Record.State) -and $validStateNames -ccontains $Record.State)
    if (Test-InventoryInteger $Record.State) {
        $stateIsValid = ([int64]$Record.State -ge 0 -and [int64]$Record.State -le 4)
    }
    if (-not $stateIsValid) { throw 'Inventory task State is invalid.' }
    if (-not (Test-InventoryString $Record.Author $true)) { throw 'Inventory task Author is invalid.' }
    if (-not (Test-InventoryString $Record.Description $true)) { throw 'Inventory task Description is invalid.' }
    if ($Record.Actions -isnot [System.Array]) { throw 'Inventory task Actions must be an array.' }
    foreach ($action in @($Record.Actions)) {
        if ($action -isnot [string]) { throw 'Inventory task Actions entries must be strings.' }
    }
}

function Assert-InventoryPackageShape($Package, [string]$ExpectedNonce, [string]$ExpectedSid, [datetime]$UtcNow = [datetime]::UtcNow) {
    $topFields = @('inventory_schema_version','nonce','generated_utc','collector_sid','services','tasks','health','warnings')
    if (-not (Test-InventoryExactProperties $Package $topFields)) { throw 'Inventory package top-level fields are invalid.' }
    if (-not (Test-InventoryInteger $Package.inventory_schema_version) -or [int64]$Package.inventory_schema_version -ne $script:InventorySchemaVersion) {
        throw 'Inventory package schema is unsupported.'
    }
    if ($Package.nonce -isnot [string] -or $Package.nonce -cne $ExpectedNonce -or -not (Test-InventoryNonce $Package.nonce)) {
        throw 'Inventory package nonce mismatch.'
    }
    if ($Package.collector_sid -isnot [string] -or $Package.collector_sid -cne $ExpectedSid) {
        throw 'Inventory package collector SID mismatch.'
    }
    $generated = ConvertFrom-InventoryCanonicalUtc $Package.generated_utc
    if ($null -eq $generated) { throw 'Inventory package UTC timestamp is invalid.' }
    $nowOffset = [datetimeoffset]::new($UtcNow.ToUniversalTime())
    if ($generated -lt $nowOffset.AddMinutes(-5) -or $generated -gt $nowOffset.AddMinutes(1)) {
        throw 'Inventory package UTC timestamp is outside the trusted window.'
    }
    if ($Package.services -isnot [System.Array] -or $Package.tasks -isnot [System.Array] -or $Package.warnings -isnot [System.Array]) {
        throw 'Inventory services, tasks, and warnings must be arrays.'
    }
    if (@($Package.services).Count -gt $script:MaxInventoryRecords -or @($Package.tasks).Count -gt $script:MaxInventoryRecords) {
        throw 'Inventory record count exceeds the limit.'
    }
    if (-not (Test-InventoryExactProperties $Package.health @('services','tasks'))) {
        throw 'Inventory health fields are invalid.'
    }
    if ($Package.health.services -isnot [string] -or $Package.health.services -cne 'complete' -or
        $Package.health.tasks -isnot [string] -or $Package.health.tasks -cne 'complete') {
        throw 'Inventory health is incomplete or invalid.'
    }
    foreach ($warning in @($Package.warnings)) {
        if ($warning -isnot [string]) { throw 'Inventory warning must be a scalar string.' }
    }
    foreach ($service in @($Package.services)) {
        if ($null -eq $service) { throw 'Inventory service record cannot be null.' }
        Assert-InventoryServiceRecord $service $generated
    }
    foreach ($task in @($Package.tasks)) {
        if ($null -eq $task) { throw 'Inventory task record cannot be null.' }
        Assert-InventoryTaskRecord $task
    }
}

function Read-TrustedInventoryJsonPackageAtPath([string]$Path, [string]$Nonce, [string]$ReaderSid) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    if ([string]::IsNullOrWhiteSpace($ReaderSid)) { throw 'Inventory reader SID is invalid.' }
    $root = Get-SecureInventoryRoot
    $nonceDirectory = Resolve-InventoryNonceDirectory $Nonce
    $name = [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($Path))
    if ($name -ceq 'inventory.json') {
        $Path = Assert-NonceLocalInventoryFilePath -Path $Path -Nonce $Nonce -Final
    } else {
        $Path = Assert-NonceLocalInventoryFilePath -Path $Path -Nonce $Nonce
    }
    $trustedPaths = @($root, $nonceDirectory, $Path)
    foreach ($trustedPath in $trustedPaths) {
        Assert-InventoryPathIsNotReparsePoint $trustedPath
        Assert-TrustedInventoryPathAcl $trustedPath $ReaderSid
    }

    $stream = $null
    try {
        $stream = Open-TrustedInventoryReadStream $Path
        $bytes = Read-LimitedInventorySnapshot $stream
        foreach ($trustedPath in $trustedPaths) {
            Assert-InventoryPathIsNotReparsePoint $trustedPath
            Assert-TrustedInventoryPathAcl $trustedPath $ReaderSid
        }
        $json = ConvertFrom-InventorySnapshotBytes $bytes
        $package = ConvertFrom-StrictInventoryJson $json
        Assert-InventoryPackageShape $package $Nonce $ReaderSid ([datetime]::UtcNow)
        return [pscustomobject]@{ Package=$package; Sha256=(Get-BytesSha256Hex $bytes).ToLowerInvariant() }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-TrustedInventoryJsonPackage([string]$Nonce, [string]$ReaderSid) {
    return Read-TrustedInventoryJsonPackageAtPath -Path (Resolve-InventoryPackagePath $Nonce) -Nonce $Nonce -ReaderSid $ReaderSid
}

function ConvertTo-InventoryReadyBytes([string]$Nonce, [string]$Sha256) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Inventory ready SHA256 is invalid.' }
    $text = "inventory-ready-v1`n$Nonce`n$Sha256`n"
    return (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($text)
}

function ConvertFrom-InventoryReadyBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -gt $script:MaxInventoryReadyBytes) { throw 'Inventory ready marker is invalid or too large.' }
    $text = ConvertFrom-InventorySnapshotBytes $Bytes
    $match = [regex]::Match($text, '\Ainventory-ready-v1\n([0-9a-f]{64})\n([0-9a-f]{64})\n\z', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { throw 'Inventory ready marker content is invalid.' }
    return [pscustomobject]@{ Nonce=$match.Groups[1].Value; Sha256=$match.Groups[2].Value }
}

function Read-TrustedInventoryReadyMarkerAtPath([string]$Path, [string]$Nonce, [string]$ReaderSid) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    if ([string]::IsNullOrWhiteSpace($ReaderSid)) { throw 'Inventory reader SID is invalid.' }
    $root = Get-SecureInventoryRoot
    $nonceDirectory = Resolve-InventoryNonceDirectory $Nonce
    $name = [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($Path))
    if ($name -ceq 'inventory.ready') {
        $Path = Assert-NonceLocalInventoryFilePath -Path $Path -Nonce $Nonce -Ready
    } else {
        $Path = Assert-NonceLocalInventoryFilePath -Path $Path -Nonce $Nonce -ReadyTemp
    }
    $trustedPaths = @($root, $nonceDirectory, $Path)
    foreach ($trustedPath in $trustedPaths) {
        Assert-InventoryPathIsNotReparsePoint $trustedPath
        Assert-TrustedInventoryPathAcl $trustedPath $ReaderSid
    }
    $stream = $null
    try {
        $stream = Open-TrustedInventoryReadStream $Path
        if ($stream.Length -gt $script:MaxInventoryReadyBytes) { throw 'Inventory ready marker is too large.' }
        $bytes = Read-LimitedInventorySnapshot $stream
        foreach ($trustedPath in $trustedPaths) {
            Assert-InventoryPathIsNotReparsePoint $trustedPath
            Assert-TrustedInventoryPathAcl $trustedPath $ReaderSid
        }
        $marker = ConvertFrom-InventoryReadyBytes $bytes
        if ($marker.Nonce -cne $Nonce) { throw 'Inventory ready marker nonce mismatch.' }
        return $marker
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-TrustedInventoryReadyMarker([string]$Nonce, [string]$ReaderSid) {
    return Read-TrustedInventoryReadyMarkerAtPath -Path (Resolve-InventoryReadyPath $Nonce) -Nonce $Nonce -ReaderSid $ReaderSid
}

function Read-TrustedInventoryPackage([string]$Nonce) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    $readerSid = Get-CurrentUserSid
    $marker = Read-TrustedInventoryReadyMarker -Nonce $Nonce -ReaderSid $readerSid
    $result = Read-TrustedInventoryJsonPackage -Nonce $Nonce -ReaderSid $readerSid
    if ($marker.Sha256 -cne $result.Sha256) { throw 'Inventory ready marker hash does not match inventory.json.' }
    return $result
}

function New-ProtectedInventorySecurity {
    param(
        [Parameter(Mandatory=$true)][string]$ReaderSid,
        [switch]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($ReaderSid)) { throw 'Inventory reader SID is invalid.' }
    try { $readerIdentity = New-Object System.Security.Principal.SecurityIdentifier($ReaderSid) }
    catch { throw ('Inventory reader SID is invalid: ' + $_.Exception.Message) }

    $security = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $security.SetAccessRuleProtection($true, $false)
    $adminIdentity = New-Object System.Security.Principal.SecurityIdentifier($script:TrustedInventoryAdministratorsSid)
    $systemIdentity = New-Object System.Security.Principal.SecurityIdentifier($script:TrustedInventorySystemSid)
    $security.SetOwner($adminIdentity)
    $inheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($identity in @($systemIdentity, $adminIdentity)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow)
        $null = $security.AddAccessRule($rule)
    }
    $readRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::ReadPermissions -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    $readerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $readerIdentity, $readRights, $inheritance, $propagation, $allow)
    $null = $security.AddAccessRule($readerRule)
    return $security
}

function Set-InventoryPathAcl($Path, $Acl) {
    Set-LocalFileSystemAcl -Path $Path -Acl $Acl
}

function Protect-InventoryPathAcl {
    param(
        [Parameter(Mandatory=$true)]$Path,
        [Parameter(Mandatory=$true)][string]$ReaderSid,
        [switch]$Directory
    )
    Set-InventoryPathAcl -Path $Path -Acl (New-ProtectedInventorySecurity -ReaderSid $ReaderSid -Directory:$Directory)
    Assert-TrustedInventoryPathAcl -Path $Path -ReaderSid $ReaderSid
}

function Assert-ExistingInventoryAncestorsNotReparsePoint([string]$Path) {
    $candidate = [System.IO.Path]::GetFullPath($Path)
    while (-not [System.IO.Directory]::Exists($candidate) -and -not [System.IO.File]::Exists($candidate)) {
        $parent = [System.IO.Path]::GetDirectoryName($candidate)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $candidate) {
            throw 'No existing inventory path ancestor could be validated.'
        }
        $candidate = $parent
    }
    Assert-InventoryPathIsNotReparsePoint $candidate
}

function Initialize-TrustedInventoryDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$ReaderSid
    )
    Assert-ExistingInventoryAncestorsNotReparsePoint $Path
    if ([System.IO.Directory]::Exists($Path)) {
        Assert-InventoryPathIsNotReparsePoint $Path
        Assert-TrustedInventoryPathAcl -Path $Path -ReaderSid $ReaderSid
        return
    }
    $security = New-ProtectedInventorySecurity -ReaderSid $ReaderSid -Directory
    $null = [System.IO.Directory]::CreateDirectory($Path, $security)
    Assert-InventoryPathIsNotReparsePoint $Path
    Assert-TrustedInventoryPathAcl -Path $Path -ReaderSid $ReaderSid
}

function Resolve-InventoryNonceDirectory([string]$Nonce) {
    return Split-Path -Parent (Resolve-InventoryPackagePath $Nonce)
}

function New-InventoryTempPath([string]$Nonce) {
    $nonceDirectory = Resolve-InventoryNonceDirectory $Nonce
    return [System.IO.Path]::Combine($nonceDirectory, ('inventory.' + [guid]::NewGuid().ToString('N') + '.tmp'))
}

function New-InventoryReadyTempPath([string]$Nonce) {
    $nonceDirectory = Resolve-InventoryNonceDirectory $Nonce
    return [System.IO.Path]::Combine($nonceDirectory, ('inventory.ready.' + [guid]::NewGuid().ToString('N') + '.tmp'))
}

function Assert-NonceLocalInventoryFilePath {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Nonce,
        [switch]$Final,
        [switch]$Ready,
        [switch]$ReadyTemp
    )
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    $nonceDirectory = [System.IO.Path]::GetFullPath((Resolve-InventoryNonceDirectory $Nonce)).TrimEnd('\', '/')
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($fullPath), $nonceDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory file is not directly inside the validated nonce directory.'
    }
    $name = [System.IO.Path]::GetFileName($fullPath)
    if (@($Final, $Ready, $ReadyTemp | Where-Object { $_ }).Count -gt 1) { throw 'Inventory file kind is ambiguous.' }
    if ($Final) {
        if ($name -cne 'inventory.json') { throw 'Inventory final filename is invalid.' }
    } elseif ($Ready) {
        if ($name -cne 'inventory.ready') { throw 'Inventory ready filename is invalid.' }
    } elseif ($ReadyTemp) {
        if ($name -cnotmatch '^inventory\.ready\.[0-9a-f]{32}\.tmp$') { throw 'Inventory ready temporary filename is invalid.' }
    } elseif ($name -cnotmatch '^inventory\.[0-9a-f]{32}\.tmp$') {
        throw 'Inventory temporary filename is invalid.'
    }
    return $fullPath
}

function Write-InventoryBytesTempFile([string]$Path, [byte[]]$Bytes) {
    if ($null -eq $Bytes) { throw 'Inventory temporary bytes are null.' }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Write-InventoryTempFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Package
    )
    $json = ConvertTo-Json -InputObject $Package -Depth $script:MaxInventoryJsonDepth -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($json)
    if ($bytes.Length -gt $script:MaxInventoryJsonBytes) { throw 'Inventory JSON is too large.' }
    Write-InventoryBytesTempFile -Path $Path -Bytes $bytes
}

function Publish-InventoryTempFile([string]$TempPath, [string]$FinalPath) {
    [System.IO.File]::Move($TempPath, $FinalPath)
}

function Remove-ValidatedInventoryFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Nonce,
        [switch]$Final,
        [switch]$Ready,
        [switch]$ReadyTemp
    )
    $validated = Assert-NonceLocalInventoryFilePath -Path $Path -Nonce $Nonce -Final:$Final -Ready:$Ready -ReadyTemp:$ReadyTemp
    if ([System.IO.File]::Exists($validated)) {
        Assert-InventoryPathIsNotReparsePoint $validated
        [System.IO.File]::Delete($validated)
    }
}

function Write-TrustedInventoryPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Nonce,
        [Parameter(Mandatory=$true)][string]$ReaderSid,
        [Parameter(Mandatory=$true)]$Package
    )
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    Assert-InventoryPackageShape $Package $Nonce $ReaderSid ([datetime]::UtcNow)
    $root = Get-SecureInventoryRoot
    $finalPath = Resolve-InventoryPackagePath $Nonce
    $readyPath = Resolve-InventoryReadyPath $Nonce
    $nonceDirectory = Split-Path -Parent $finalPath
    Initialize-TrustedInventoryDirectory -Path $root -ReaderSid $ReaderSid
    Initialize-TrustedInventoryDirectory -Path $nonceDirectory -ReaderSid $ReaderSid
    Remove-ValidatedInventoryFile -Path $readyPath -Nonce $Nonce -Ready
    if ([System.IO.File]::Exists($finalPath)) { throw 'Inventory final package already exists.' }

    $tempPath = New-InventoryTempPath $Nonce
    $readyTempPath = New-InventoryReadyTempPath $Nonce
    $published = $false
    $rechecked = $null
    try {
        $null = Assert-NonceLocalInventoryFilePath -Path $tempPath -Nonce $Nonce
        Write-InventoryTempFile -Path $tempPath -Package $Package
        Protect-InventoryPathAcl -Path $tempPath -ReaderSid $ReaderSid
        $tempRechecked = Read-TrustedInventoryJsonPackageAtPath -Path $tempPath -Nonce $Nonce -ReaderSid $ReaderSid
        if ([System.IO.File]::Exists($finalPath)) { throw 'Inventory final package appeared before publication.' }
        Publish-InventoryTempFile -TempPath $tempPath -FinalPath $finalPath
        $published = $true
        $rechecked = Read-TrustedInventoryJsonPackageAtPath -Path $finalPath -Nonce $Nonce -ReaderSid $ReaderSid
        if ($tempRechecked.Sha256 -cne $rechecked.Sha256) { throw 'Published inventory JSON hash mismatch.' }

        $null = Assert-NonceLocalInventoryFilePath -Path $readyTempPath -Nonce $Nonce -ReadyTemp
        $readyBytes = ConvertTo-InventoryReadyBytes -Nonce $Nonce -Sha256 $rechecked.Sha256
        Write-InventoryBytesTempFile -Path $readyTempPath -Bytes $readyBytes
        Protect-InventoryPathAcl -Path $readyTempPath -ReaderSid $ReaderSid
        $marker = Read-TrustedInventoryReadyMarkerAtPath -Path $readyTempPath -Nonce $Nonce -ReaderSid $ReaderSid
        if ($marker.Sha256 -cne $rechecked.Sha256) { throw 'Staged inventory ready marker hash mismatch.' }
        if ([System.IO.File]::Exists($readyPath)) { throw 'Inventory ready marker appeared before publication.' }
    } catch {
        $failure = $_
        try { Remove-ValidatedInventoryFile -Path $tempPath -Nonce $Nonce } catch {}
        try { Remove-ValidatedInventoryFile -Path $readyTempPath -Nonce $Nonce -ReadyTemp } catch {}
        if ($published) {
            try { Remove-ValidatedInventoryFile -Path $finalPath -Nonce $Nonce -Final } catch {}
        }
        throw $failure
    }
    Publish-InventoryTempFile -TempPath $readyTempPath -FinalPath $readyPath
    return $rechecked
}

function Get-InventoryChildDirectories([string]$Root) {
    if (-not [System.IO.Directory]::Exists($Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction Stop)
}

function Assert-InventoryTreeHasNoReparsePoints([string]$Path) {
    $pending = New-Object System.Collections.Stack
    $pending.Push((New-Object System.IO.DirectoryInfo($Path)))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Inventory cleanup tree contains a reparse point: ' + $directory.FullName)
        }
        foreach ($entry in @($directory.GetFileSystemInfos())) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Inventory cleanup tree contains a reparse point: ' + $entry.FullName)
            }
            if ($entry -is [System.IO.DirectoryInfo]) { $pending.Push($entry) }
        }
    }
}

function Remove-TrustedInventoryDirectory([string]$Path) {
    Assert-InventoryTreeHasNoReparsePoints $Path
    [System.IO.Directory]::Delete($Path, $true)
}

function Remove-StaleTrustedInventoryPackages {
    param([datetime]$UtcNow = [datetime]::UtcNow)
    try {
        $rootFull = [System.IO.Path]::GetFullPath((Get-SecureInventoryRoot)).TrimEnd('\', '/')
        if (-not [System.IO.Directory]::Exists($rootFull)) { return }
        $readerSid = Get-CurrentUserSid
        Assert-InventoryPathIsNotReparsePoint $rootFull
        Assert-TrustedInventoryPathAcl -Path $rootFull -ReaderSid $readerSid
    } catch {
        # Never enumerate a missing, uncertain, or untrusted fixed root.
        return
    }
    $cutoff = $UtcNow.ToUniversalTime().AddHours(-24)
    $entries = @()
    try { $entries = @(Get-InventoryChildDirectories $rootFull) } catch { return }
    foreach ($entry in $entries) {
        try {
            if ($null -eq $entry -or $entry.Name -isnot [string] -or $entry.Name -cnotmatch '^[0-9a-f]{64}$') { continue }
            if ($entry.LastWriteTimeUtc -isnot [datetime] -or $entry.LastWriteTimeUtc.ToUniversalTime() -ge $cutoff) { continue }
            $expected = [System.IO.Path]::Combine($rootFull, $entry.Name)
            $actual = [System.IO.Path]::GetFullPath([string]$entry.FullName).TrimEnd('\', '/')
            if (-not [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            Assert-InventoryPathIsNotReparsePoint $actual
            Assert-TrustedInventoryPathAcl -Path $actual -ReaderSid $readerSid
            Assert-InventoryPathIsNotReparsePoint $rootFull
            Assert-TrustedInventoryPathAcl -Path $rootFull -ReaderSid $readerSid
            Remove-TrustedInventoryDirectory -Path $actual
        } catch {
            # Uncertain or untrusted stale entries are intentionally retained.
        }
    }
}

function New-InventoryProcessIdentityState($Status, $Name, $Path, $StartUtc) {
    return [pscustomobject][ordered]@{
        ProcessIdentityStatus = $Status
        ProcessName = $Name
        ProcessPath = $Path
        ProcessStartTimeUtc = $StartUtc
    }
}

function Get-PrivilegedServiceExecutionSnapshot([string]$ServiceName) {
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return $null }
    try {
        $escapedName = $ServiceName.Replace('\', '\\').Replace("'", "\'")
        $services = @(Get-CimInstance -ClassName Win32_Service -Filter ("Name = '{0}'" -f $escapedName) -ErrorAction Stop)
        if ($services.Count -ne 1 -or $null -eq $services[0]) { return $null }
        $service = $services[0]
        if ($service.Name -isnot [string] -or $service.Name -cne $ServiceName -or
            $service.State -isnot [string] -or $service.State -cne 'Running') {
            return $null
        }
        $processId = Get-StrictServiceProcessId $service.ProcessId
        if ($null -eq $processId -or $service.PathName -isnot [string] -or
            [string]::IsNullOrWhiteSpace($service.PathName)) {
            return $null
        }
        $binaryPath = ConvertFrom-InventoryServicePathName $service.PathName
        if ($binaryPath -isnot [string] -or -not (Test-InventoryFullyQualifiedWindowsPath $binaryPath)) {
            return $null
        }
        $binaryPath = [System.IO.Path]::GetFullPath($binaryPath)
        if (-not [System.IO.File]::Exists($binaryPath)) { return $null }
        return [pscustomobject][ordered]@{
            Name = $service.Name
            State = $service.State
            ProcessId = $processId
            PathName = $service.PathName
            BinaryPath = $binaryPath
        }
    } catch {
        return $null
    }
}

function Get-PrivilegedServiceProcessIdentity($Service) {
    if ($null -ne $Service -and $Service.State -is [string] -and $Service.State -cne 'Running' -and
        (Test-InventoryInteger $Service.ProcessId) -and [int64]$Service.ProcessId -eq 0) {
        return New-InventoryProcessIdentityState not_running '' '' ''
    }

    try {
        if ($null -eq $Service -or $Service.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Service.Name) -or
            $Service.State -isnot [string] -or $Service.State -cne 'Running') {
            throw 'unavailable'
        }
        $collectedProcessId = Get-StrictServiceProcessId $Service.ProcessId
        if ($null -eq $collectedProcessId -or $Service.PathName -isnot [string]) { throw 'unavailable' }

        $first = Get-PrivilegedServiceExecutionSnapshot -ServiceName $Service.Name
        if ($null -eq $first -or $first.Name -cne $Service.Name -or $first.State -cne $Service.State -or
            $first.ProcessId -ne $collectedProcessId -or $first.PathName -cne $Service.PathName) {
            throw 'unavailable'
        }
        $collectedBinaryPath = ConvertFrom-InventoryServicePathName $Service.PathName
        if ($collectedBinaryPath -isnot [string] -or -not (Test-InventoryFullyQualifiedWindowsPath $collectedBinaryPath)) {
            throw 'unavailable'
        }
        $collectedBinaryPath = [System.IO.Path]::GetFullPath($collectedBinaryPath)
        if (-not [string]::Equals($collectedBinaryPath, [string]$first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'unavailable'
        }

        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $first.ProcessId) -ErrorAction Stop)
        if ($processes.Count -ne 1 -or $null -eq $processes[0]) { throw 'unavailable' }
        $process = $processes[0]
        $processId = Get-StrictServiceProcessId $process.ProcessId
        if ($null -eq $processId -or $processId -ne $first.ProcessId) { throw 'unavailable' }

        if ($process.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($process.Name)) { throw 'unavailable' }
        $processName = [string]$process.Name
        $expectedName = [System.IO.Path]::GetFileName([string]$first.BinaryPath)
        if (-not [string]::Equals($processName, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'unavailable'
        }

        $wmiProcessStartTimeUtc = ConvertTo-ServiceProcessStartTimeUtc $process.CreationDate
        if ([string]::IsNullOrWhiteSpace([string]$wmiProcessStartTimeUtc)) { throw 'unavailable' }
        $parsedWmiProcessStart = ConvertFrom-InventoryCanonicalUtc $wmiProcessStartTimeUtc
        if ($null -eq $parsedWmiProcessStart -or $parsedWmiProcessStart -gt [datetimeoffset]::UtcNow) { throw 'unavailable' }

        $wmiPathIsValid = $false
        $wmiProcessPath = $null
        if ($process.ExecutablePath -is [string] -and (Test-InventoryFullyQualifiedWindowsPath $process.ExecutablePath)) {
            try { $wmiProcessPath = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath) } catch { $wmiProcessPath = $null }
            $wmiPathIsValid = $null -ne $wmiProcessPath -and [System.IO.File]::Exists($wmiProcessPath) -and
                [string]::Equals($wmiProcessPath, [string]$first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)
        }

        if ($wmiPathIsValid) {
            $processPath = $wmiProcessPath
            $processStartTimeUtc = $wmiProcessStartTimeUtc
        } else {
            $nativeIdentity = Get-NativeProcessIdentity -ProcessId $first.ProcessId
            if ($null -eq $nativeIdentity -or
                (Get-StrictServiceProcessId $nativeIdentity.PID) -ne $first.ProcessId -or
                $nativeIdentity.Name -isnot [string] -or
                -not [string]::Equals([string]$nativeIdentity.Name, $processName, [System.StringComparison]::OrdinalIgnoreCase) -or
                $nativeIdentity.Path -isnot [string] -or -not (Test-InventoryFullyQualifiedWindowsPath $nativeIdentity.Path) -or
                -not [System.IO.File]::Exists([string]$nativeIdentity.Path) -or
                -not [string]::Equals([System.IO.Path]::GetFullPath([string]$nativeIdentity.Path), [string]$first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                $nativeIdentity.StartTimeUtc -isnot [string] -or
                -not (Test-WmiNativeProcessStartTimeEqual -WmiStartTimeUtc $wmiProcessStartTimeUtc -NativeStartTimeUtc $nativeIdentity.StartTimeUtc)) {
                throw 'unavailable'
            }
            $processName = [string]$nativeIdentity.Name
            $processPath = [System.IO.Path]::GetFullPath([string]$nativeIdentity.Path)
            $processStartTimeUtc = [string]$nativeIdentity.StartTimeUtc
        }

        $second = Get-PrivilegedServiceExecutionSnapshot -ServiceName $first.Name
        if ($null -eq $second -or $second.Name -cne $first.Name -or $second.State -cne 'Running' -or
            $second.ProcessId -ne $first.ProcessId -or $second.PathName -cne $first.PathName -or
            -not [string]::Equals([string]$second.BinaryPath, [string]$first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'unavailable'
        }

        return New-InventoryProcessIdentityState complete $processName $processPath $processStartTimeUtc
    } catch {
        $warning = [string]::Concat(
            [char]0x670D, [char]0x52A1, [char]0x8FDB, [char]0x7A0B, [char]0x8EAB,
            [char]0x4EFD, [char]0x4E0D, [char]0x53EF, [char]0x7528, [char]0x3002
        )
        Add-ScanWarning $warning
        return New-InventoryProcessIdentityState unavailable '' '' ''
    }
}

function ConvertTo-InventoryServiceRecord($Record) {
    if ($null -eq $Record) { throw 'Inventory service record cannot be null.' }
    $required = @('Name','DisplayName','State','StartMode','PathName','ProcessId')
    $names = @($Record.PSObject.Properties.Name)
    foreach ($name in $required) {
        if ($names -cnotcontains $name) { throw "Inventory service collection is missing required field $name." }
    }
    Assert-InventoryServiceBaseRecord $Record
    $identity = Get-PrivilegedServiceProcessIdentity $Record
    try {
        $launchState = Get-ServiceLaunchProtectedState -ServiceName $Record.Name
        $launchEvidence = [pscustomobject][ordered]@{
            LaunchProtectedStatus = $launchState.Status
            LaunchProtectedLevel = $launchState.Level
        }
        Assert-InventoryLaunchProtectedShape $launchEvidence
    } catch {
        $launchEvidence = [pscustomobject][ordered]@{
            LaunchProtectedStatus = 'unavailable'
            LaunchProtectedLevel = [int]-1
        }
    }

    $uninstallEvidence = New-UnavailableLenovoOfficialUninstallEvidence
    if ([string]::Equals($Record.Name, 'HRWSCCtrl', [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $uninstallEvidence = Get-LenovoOfficialUninstallEvidence
            $uninstallValidationRecord = [pscustomobject][ordered]@{
                Name = $Record.Name
                UninstallEvidenceStatus = $uninstallEvidence.UninstallEvidenceStatus
                UninstallRegistryPath = $uninstallEvidence.UninstallRegistryPath
                UninstallDisplayName = $uninstallEvidence.UninstallDisplayName
                UninstallPublisher = $uninstallEvidence.UninstallPublisher
                UninstallDisplayVersion = $uninstallEvidence.UninstallDisplayVersion
                UninstallInstallLocation = $uninstallEvidence.UninstallInstallLocation
                UninstallString = $uninstallEvidence.UninstallString
                UninstallExecutablePath = $uninstallEvidence.UninstallExecutablePath
            }
            Assert-InventoryUninstallEvidenceShape $uninstallValidationRecord
        } catch {
            $uninstallEvidence = New-UnavailableLenovoOfficialUninstallEvidence
        }
    }
    return [pscustomobject][ordered]@{
        Name = $Record.Name
        DisplayName = $Record.DisplayName
        State = $Record.State
        StartMode = $Record.StartMode
        PathName = $Record.PathName
        ProcessId = $Record.ProcessId
        ProcessIdentityStatus = $identity.ProcessIdentityStatus
        ProcessName = $identity.ProcessName
        ProcessPath = $identity.ProcessPath
        ProcessStartTimeUtc = $identity.ProcessStartTimeUtc
        LaunchProtectedStatus = $launchEvidence.LaunchProtectedStatus
        LaunchProtectedLevel = $launchEvidence.LaunchProtectedLevel
        UninstallEvidenceStatus = $uninstallEvidence.UninstallEvidenceStatus
        UninstallRegistryPath = $uninstallEvidence.UninstallRegistryPath
        UninstallDisplayName = $uninstallEvidence.UninstallDisplayName
        UninstallPublisher = $uninstallEvidence.UninstallPublisher
        UninstallDisplayVersion = $uninstallEvidence.UninstallDisplayVersion
        UninstallInstallLocation = $uninstallEvidence.UninstallInstallLocation
        UninstallString = $uninstallEvidence.UninstallString
        UninstallExecutablePath = $uninstallEvidence.UninstallExecutablePath
    }
}

function ConvertTo-InventoryTaskRecord($Record) {
    if ($null -eq $Record) { throw 'Inventory task record cannot be null.' }
    $propertyNames = @($Record.PSObject.Properties.Name)
    foreach ($name in @('TaskName','TaskPath','State','Author','Description','Actions')) {
        if ($propertyNames -cnotcontains $name) { throw "Inventory task collection is missing required field $name." }
    }
    if ($Record.Author -isnot [string]) { throw 'Inventory task Author must be a collected string.' }
    if ($Record.Description -isnot [string]) { throw 'Inventory task Description must be a collected string.' }
    if ($Record.Actions -isnot [System.Array]) { throw 'Inventory task Actions must be a collected array.' }
    $actions = [object[]]@($Record.Actions | ForEach-Object {
        if ($_ -isnot [string]) { throw 'Inventory task Actions entries must be collected strings.' }
        [string]$_
    })
    return [pscustomobject][ordered]@{
        TaskName = $Record.TaskName
        TaskPath = $Record.TaskPath
        State = $Record.State
        Author = [string]$Record.Author
        Description = [string]$Record.Description
        Actions = $actions
    }
}

function Invoke-ScanInventory([string]$Nonce) {
    if (-not (Is-Admin)) { throw 'scan_inventory requires administrator rights.' }
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    Reset-ScanDiagnostics
    $readerSid = Get-CurrentUserSid
    $services = @(Get-ServicesInfo)
    $tasks = @(Get-TasksInfo)
    if ($services.Count -eq 0 -or $tasks.Count -eq 0) { throw 'Privileged inventory collection returned an incomplete category.' }
    if ([string]$script:ScanHealth.services -cne 'complete' -or [string]$script:ScanHealth.tasks -cne 'complete') {
        throw 'Privileged inventory collection health is incomplete.'
    }
    $serviceRecords = @($services | ForEach-Object { ConvertTo-InventoryServiceRecord $_ })
    $taskRecords = @($tasks | ForEach-Object { ConvertTo-InventoryTaskRecord $_ })
    $warnings = @($script:ScanWarnings | ForEach-Object {
        if ($_ -isnot [string]) { throw 'Inventory warning must be a scalar string.' }
        [string]$_
    })
    $package = [pscustomobject][ordered]@{
        inventory_schema_version = $script:InventorySchemaVersion
        nonce = $Nonce
        generated_utc = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        collector_sid = $readerSid
        services = [object[]]$serviceRecords
        tasks = [object[]]$taskRecords
        health = [pscustomobject][ordered]@{ services='complete'; tasks='complete' }
        warnings = [object[]]$warnings
    }
    Assert-InventoryPackageShape $package $Nonce $readerSid ([datetime]::UtcNow)
    Remove-StaleTrustedInventoryPackages
    $null = Write-TrustedInventoryPackage -Nonce $Nonce -ReaderSid $readerSid -Package $package
    return $package
}
