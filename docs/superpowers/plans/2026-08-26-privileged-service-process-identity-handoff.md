# Privileged Service Process Identity Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an exact HRWSCCtrl service hit safely selectable by carrying a strictly validated process identity from the privileged read-only inventory into the normal scan, while preserving administrator revalidation immediately before process termination.

**Architecture:** Upgrade the protected inventory to Schema v2 and enrich each service record with an all-or-nothing process identity plus an explicit status. The normal scanner accepts that identity only from a verified nonce-bound inventory, checks it against two live service snapshots, and emits the existing identity-bound `manual_impact stop_service_process` pending action; the existing elevated executor remains the final authority and is protected by additional regression tests.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, CIM (`Win32_Service`, `Win32_Process`), Pester, WPF/XAML, strict JSON with ACL/nonce/SID/hash binding.

---

## File map

- Modify `src/Core/InventoryManager.ps1`: define Inventory Schema v2, validate the strict service-process identity states, collect protected process identity, and publish v2 records.
- Modify `src/Core/Scanner.ps1`: preserve verified v2 identity fields with an internal trusted-source marker and build pending identity from those fields after two live service snapshots.
- Modify `src/Core/ProfileEngine.ps1`: require exact service-name provenance, not merely an exact display-name match, for `stop_service_process`.
- Modify `tests/Pester/Inventory.Tests.ps1`: cover v2 shape, invariants, tampering, protected collection success/failure, and no-mutation behavior.
- Modify `tests/Pester/Profile.Tests.ps1`: prove exact HRWSCCtrl becomes selectable only with trusted, complete, stable identity evidence.
- Modify `tests/Pester/ProcessStop.Tests.ps1`: prove inventory evidence never replaces administrator execution-time identity revalidation.
- Modify `tests/Gui.Tests.ps1`: prove a real-shaped HRWSCCtrl pending action is displayed, initially unchecked, selectable, and included only after confirmation.
- Modify `tests/GuiPresentation.Tests.ps1`: prove necessity, impact, cleanup reason, and observation fallback copy remain truthful.
- Modify `tests/schema-tests.ps1`: lock Inventory Schema v2 and release-document statements.
- Modify `README.md`, `SECURITY.md`, `CHANGELOG.md`: document the privileged identity handoff, fail-closed states, and real-machine acceptance boundary without changing the already prepared v1.8.1 version.

### Task 1: Inventory Schema v2 strict contract

**Files:**
- Modify: `tests/Pester/Inventory.Tests.ps1`
- Modify: `src/Core/InventoryManager.ps1`

- [ ] **Step 1: Change the valid fixture to Schema v2 and write failing shape tests**

Create a real fixture file in `BeforeAll`:

```powershell
$script:TestServiceBinary = Join-Path $TestDrive 'service.exe'
[System.IO.File]::WriteAllBytes($script:TestServiceBinary, [byte[]](1))
```

Update `New-TestInventoryPackage` so its valid running service is:

```powershell
inventory_schema_version = 2
services = @([pscustomobject][ordered]@{
    Name='ExampleSvc'; DisplayName='Example Service'; State='Running'; StartMode='Auto'
    PathName=$script:TestServiceBinary; ProcessId=[int]123
    ProcessIdentityStatus='complete'; ProcessName='service.exe'
    ProcessPath=$script:TestServiceBinary
    ProcessStartTimeUtc=$UtcNow.AddMinutes(-2).ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
})
```

Change the constants assertion to `InventorySchemaVersion | Should -Be 2`. Assert the exact service property sequence is:

```powershell
@(
  'Name','DisplayName','State','StartMode','PathName','ProcessId',
  'ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc'
)
```

Add valid fixtures for:

```powershell
@{
  State='Stopped'; ProcessId=[int]0; ProcessIdentityStatus='not_running'
  ProcessName=''; ProcessPath=''; ProcessStartTimeUtc=''
}
@{
  State='Running'; ProcessId=[int]123; ProcessIdentityStatus='unavailable'
  ProcessName=''; ProcessPath=''; ProcessStartTimeUtc=''
}
```

Add an invalid table that mutates one valid record at a time: Schema v1, unknown status, partial identity, running complete with PID 0, stopped/not_running with positive PID, rooted-path failure, file-name/path mismatch, control characters, noncanonical UTC, start time after `generated_utc`, missing field, and extra field. Every invalid package must make `Assert-InventoryPackageShape` throw.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Inventory.Tests.ps1 -Output Detailed"
```

Expected: failures report Schema v1 and the six-field service contract because production still accepts only Inventory Schema v1.

- [ ] **Step 3: Implement reusable strict identity validators**

In `InventoryManager.ps1`, set:

```powershell
$script:InventorySchemaVersion = 2
$script:MaxInventoryProcessNameLength = 260
$script:MaxInventoryProcessPathLength = 32767
```

Add a strict UTC parser that returns a `DateTimeOffset` or `$null`:

```powershell
function ConvertFrom-InventoryCanonicalUtc([string]$Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { return $null }
    $parsed = [datetimeoffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetimeoffset]::TryParseExact(
        $Value, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    if ($parsed.Offset -ne [timespan]::Zero) { return $null }
    return $parsed
}
```

Add the bounded string validator:

```powershell
function Test-InventoryBoundedCleanString($Value, [int]$MaxLength) {
    if ($Value -isnot [string] -or $Value.Length -eq 0 -or $Value.Length -gt $MaxLength) { return $false }
    if ($Value -cne $Value.Trim()) { return $false }
    return ($Value -cnotmatch '[\x00-\x1F\x7F-\x9F]')
}
```

Reuse `ConvertFrom-InventoryCanonicalUtc` for the package timestamp so package and process timestamps have one canonical rule.

- [ ] **Step 4: Implement the exact v2 service state machine**

Change `Assert-InventoryServiceRecord` to require exactly ten fields. Give it a second parameter, the parsed package generation time, and implement the complete state machine:

```powershell
function Assert-InventoryServiceRecord($Record, [datetimeoffset]$GeneratedUtc) {
    $required = @(
        'Name','DisplayName','State','StartMode','PathName','ProcessId',
        'ProcessIdentityStatus','ProcessName','ProcessPath','ProcessStartTimeUtc'
    )
    if (-not (Test-InventoryExactProperties $Record $required)) {
        throw 'Inventory service record fields are invalid.'
    }
    foreach ($name in @('Name','DisplayName','State','StartMode')) {
        if (-not (Test-InventoryString $Record.$name)) { throw "Inventory service $name is invalid." }
    }
    if (-not (Test-InventoryString $Record.PathName $true)) { throw 'Inventory service PathName is invalid.' }
    if (-not (Test-InventoryInteger $Record.ProcessId) -or [int64]$Record.ProcessId -lt 0 -or
        [uint64]$Record.ProcessId -gt [uint64][uint32]::MaxValue) {
        throw 'Inventory service ProcessId is invalid.'
    }
    switch -CaseSensitive ([string]$Record.ProcessIdentityStatus) {
        'complete' {
            if ($Record.State -cne 'Running' -or [int64]$Record.ProcessId -lt 1 -or
                [int64]$Record.ProcessId -gt [int]::MaxValue) {
                throw 'Inventory complete service process identity state is invalid.'
            }
            if (-not (Test-InventoryBoundedCleanString $Record.ProcessName $script:MaxInventoryProcessNameLength) -or
                [System.IO.Path]::GetFileName($Record.ProcessName) -cne $Record.ProcessName) {
                throw 'Inventory service ProcessName is invalid.'
            }
            if (-not (Test-InventoryBoundedCleanString $Record.ProcessPath $script:MaxInventoryProcessPathLength) -or
                -not [System.IO.Path]::IsPathRooted($Record.ProcessPath)) {
                throw 'Inventory service ProcessPath is invalid.'
            }
            try { $processPath = [System.IO.Path]::GetFullPath($Record.ProcessPath) }
            catch { throw 'Inventory service ProcessPath is invalid.' }
            $binary = Get-ServiceBinaryPathFromPathName $Record.PathName
            try { $binary = [System.IO.Path]::GetFullPath([string]$binary) }
            catch { throw 'Inventory service binary path is invalid.' }
            if (-not [System.IO.File]::Exists($processPath) -or
                -not [string]::Equals([System.IO.Path]::GetFileName($processPath), $Record.ProcessName, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($processPath, $binary, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Inventory complete service process path identity is inconsistent.'
            }
            $started = ConvertFrom-InventoryCanonicalUtc $Record.ProcessStartTimeUtc
            if ($null -eq $started -or $started -gt $GeneratedUtc) {
                throw 'Inventory service ProcessStartTimeUtc is invalid.'
            }
        }
        'not_running' {
            if ($Record.State -ceq 'Running' -or [int64]$Record.ProcessId -ne 0 -or
                $Record.ProcessName -cne '' -or $Record.ProcessPath -cne '' -or
                $Record.ProcessStartTimeUtc -cne '') {
                throw 'Inventory not_running service process identity state is invalid.'
            }
        }
        'unavailable' {
            if ($Record.ProcessName -cne '' -or $Record.ProcessPath -cne '' -or
                $Record.ProcessStartTimeUtc -cne '') {
                throw 'Inventory unavailable service process identity must be empty.'
            }
        }
        default { throw 'Inventory service ProcessIdentityStatus is invalid.' }
    }
}
```

Parse `generated_utc` once in `Assert-InventoryPackageShape`, then call `Assert-InventoryServiceRecord $service $generated`. No partial identity may pass.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all `Inventory.Tests.ps1` tests pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```powershell
git add src/Core/InventoryManager.ps1 tests/Pester/Inventory.Tests.ps1
git commit -m "feat: define strict inventory v2 process identity"
```

### Task 2: Privileged all-or-nothing identity collection

**Files:**
- Modify: `tests/Pester/Inventory.Tests.ps1`
- Modify: `src/Core/InventoryManager.ps1`

- [ ] **Step 1: Write failing collector tests**

In `Describe 'internal scan_inventory collector'`, make the default service path an existing `$TestDrive\svc.exe`, and mock two `Win32_Service` snapshots plus one `Win32_Process` record:

```powershell
Mock Get-CimInstance {
    if ($ClassName -ceq 'Win32_Process') {
        return [pscustomobject]@{
            ProcessId=[int]12; Name='svc.exe'; ExecutablePath=$script:SvcBinary
            CreationDate=[datetime]::SpecifyKind([datetime]'2026-08-25T01:02:03', [DateTimeKind]::Utc)
        }
    }
    return [pscustomobject]@{
        Name='Svc'; State='Running'; ProcessId=[int]12
        PathName=('"' + $script:SvcBinary + '" /service')
    }
} -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }
```

Assert the published record has `ProcessIdentityStatus='complete'`, exact name/path, and canonical UTC. Add table cases for access denied, no process, duplicate process, invalid CreationDate, name mismatch, path mismatch, first/second service PID drift, Running with PID 0, and Stopped with PID 0. Expected statuses are `unavailable` for all unsafe combinations and `not_running` only for the last case. For unavailable records, assert all three identity strings are empty and the warning uses a fixed category without the mocked exception text.

- [ ] **Step 2: Run the collector tests and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Inventory.Tests.ps1 -Output Detailed"
```

Expected: failures show `ConvertTo-InventoryServiceRecord` does not query or emit process identity.

- [ ] **Step 3: Implement the privileged capture helper**

Add these constructors and `Get-PrivilegedServiceProcessIdentity` to `InventoryManager.ps1`:

```powershell
[pscustomobject][ordered]@{
    ProcessIdentityStatus='complete'; ProcessName=$name; ProcessPath=$path
    ProcessStartTimeUtc=$startUtc
}
[pscustomobject][ordered]@{
    ProcessIdentityStatus='not_running'; ProcessName=''; ProcessPath=''; ProcessStartTimeUtc=''
}
[pscustomobject][ordered]@{
    ProcessIdentityStatus='unavailable'; ProcessName=''; ProcessPath=''; ProcessStartTimeUtc=''
}
```

Use this implementation shape, returning `unavailable` from every failed guard:

```powershell
function New-InventoryProcessIdentityState([string]$Status, [string]$Name='', [string]$Path='', [string]$StartUtc='') {
    return [pscustomobject][ordered]@{
        ProcessIdentityStatus=$Status; ProcessName=$Name
        ProcessPath=$Path; ProcessStartTimeUtc=$StartUtc
    }
}

function Get-PrivilegedServiceProcessIdentity($Service) {
    if ($Service.State -cne 'Running' -and [int64]$Service.ProcessId -eq 0) {
        return New-InventoryProcessIdentityState 'not_running'
    }
    $pid = Get-StrictServiceProcessId $Service.ProcessId
    if ($Service.State -cne 'Running' -or $null -eq $pid) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    $reason = ''
    $first = Get-CurrentServiceExecutionSnapshot -ServiceName ([string]$Service.Name) -FailureReason ([ref]$reason)
    if ($null -eq $first -or $first.ProcessId -ne $pid -or $Service.PathName -cne $first.PathName) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $pid) -ErrorAction Stop)
    } catch {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    if ($processes.Count -ne 1 -or $null -eq $processes[0]) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    $process = $processes[0]
    $actualPid = Get-StrictServiceProcessId $process.ProcessId
    $name = [string]$process.Name
    $path = [string]$process.ExecutablePath
    if ($actualPid -ne $pid -or [string]::IsNullOrWhiteSpace($name) -or
        [string]::IsNullOrWhiteSpace($path) -or -not [System.IO.Path]::IsPathRooted($path)) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    try { $path = [System.IO.Path]::GetFullPath($path) }
    catch {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    $startUtc = ConvertTo-ServiceProcessStartTimeUtc $process.CreationDate
    if (-not [System.IO.File]::Exists($path) -or
        -not [string]::Equals($path, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($name, [System.IO.Path]::GetFileName($first.BinaryPath), [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([string]$startUtc)) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    $secondReason = ''
    $second = Get-CurrentServiceExecutionSnapshot -ServiceName $first.Name -FailureReason ([ref]$secondReason)
    if ($null -eq $second -or $second.Name -cne $first.Name -or $second.State -cne 'Running' -or
        $second.ProcessId -ne $first.ProcessId -or $second.PathName -cne $first.PathName -or
        -not [string]::Equals($second.BinaryPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ScanWarning '服务进程身份不可用。'
        return New-InventoryProcessIdentityState 'unavailable'
    }
    return New-InventoryProcessIdentityState 'complete' $name $path $startUtc
}
```

The fixed warning excludes raw exceptions and command-line text. If the implementation extracts the repeated unavailable branch into one helper, keep the exact returned shape and warning text above.

- [ ] **Step 4: Publish the enriched record**

In `ConvertTo-InventoryServiceRecord`, retain the six required collector fields, call the helper once, and return:

```powershell
return [pscustomobject][ordered]@{
    Name=$Record.Name; DisplayName=$Record.DisplayName; State=$Record.State
    StartMode=$Record.StartMode; PathName=$Record.PathName; ProcessId=$Record.ProcessId
    ProcessIdentityStatus=$identity.ProcessIdentityStatus
    ProcessName=$identity.ProcessName
    ProcessPath=$identity.ProcessPath
    ProcessStartTimeUtc=$identity.ProcessStartTimeUtc
}
```

Keep `Invoke-ScanInventory` package-level failure behavior for empty/incomplete service or task enumeration. A single `unavailable` service identity is a record-level safe degradation and must not change `health.services='complete'`.

- [ ] **Step 5: Prove the collector is read-only and GREEN**

Run the Step 2 command. Expected: all inventory tests pass. The existing mutation-mock loop must still report zero calls for every mutation command, including the new complete and unavailable cases.

- [ ] **Step 6: Commit Task 2**

```powershell
git add src/Core/InventoryManager.ps1 tests/Pester/Inventory.Tests.ps1
git commit -m "feat: collect protected service process identity"
```

### Task 3: Trusted scan handoff and exact HRWSCCtrl action

**Files:**
- Modify: `tests/Pester/Profile.Tests.ps1`
- Modify: `src/Core/ProfileEngine.ps1`
- Modify: `src/Core/Scanner.ps1`

- [ ] **Step 1: Rewrite the success fixture to require trusted inventory evidence**

In the HRWSCCtrl success test, stop mocking `Win32_Process`. Pass this service object to `Match-Profiles`:

```powershell
[pscustomobject]@{
    Name='HRWSCCtrl'; DisplayName='Lenovo Security Center'; State='Running'; StartMode='Manual'
    PathName=('"' + $binary + '" /svc_run'); ProcessId=[int]4321
    ProcessIdentityStatus='complete'; ProcessName='wsctrl11.exe'; ProcessPath=$binary
    ProcessStartTimeUtc='2026-08-25T01:02:03.0000000Z'
    ProcessIdentitySource='trusted_inventory_v2'
}
```

Mock only two identical `Win32_Service` reads. Assert the hit is `stop_service_process`, `manual_impact`, `default_selected=$false`, and contains all five existing execution identity fields. Assert `Win32_Process` is called zero times.

Add failing cases for missing source marker, `unavailable`, `not_running`, partial identity, service-name matcher through display name, first snapshot mismatch, second snapshot drift, process path/service binary mismatch, noncanonical start UTC, and missing executable file. Each must return `action='investigate'`, `execution_class='observation'`, `default_selected=$false`, and a nonblank sanitized `obs_reason`.

- [ ] **Step 2: Run focused profile tests and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Profile.Tests.ps1 -Output Detailed"
```

Expected: the success case fails because the current helper ignores v2 fields and attempts an unprivileged `Win32_Process` read.

- [ ] **Step 3: Preserve v2 fields only after trusted package verification**

In the nonce branch of `Get-ScanServiceTaskInventory`, project each already-validated service as:

```powershell
[pscustomobject]@{
    Name=$_.Name; DisplayName=$_.DisplayName; State=$_.State; StartMode=$_.StartMode
    PathName=$_.PathName; ProcessId=$_.ProcessId; TriggerHint=(Test-ServiceTriggerHint $_)
    ProcessIdentityStatus=$_.ProcessIdentityStatus
    ProcessName=$_.ProcessName
    ProcessPath=$_.ProcessPath
    ProcessStartTimeUtc=$_.ProcessStartTimeUtc
    ProcessIdentitySource='trusted_inventory_v2'
}
```

Do not add `ProcessIdentitySource` to the JSON Schema. It is an internal marker created only after `Read-TrustedInventoryPackage` completes ACL, nonce, SID, ready-marker, hash, time, and shape validation. Local/limited `Get-ServicesInfo` records remain without this marker and therefore cannot authorize `stop_service_process`.

- [ ] **Step 4: Require exact service-name provenance**

In `Get-HitExecutionDecision`, read the matched field beside the matched type:

```powershell
$matchedType = [string](Get-ObjectPropertyValue $evidence 'matched_type')
$matchedField = [string](Get-ObjectPropertyValue $evidence 'matched_field')
```

Change only the `stop_service_process` manual authorization branch to:

```powershell
$hitType -ceq 'service' -and
$matchedType -ceq 'exact' -and
$matchedField -ceq 'service_name'
```

Keep other manual actions on the existing narrow-evidence rule. Add a direct decision test proving `exact/service_display_name` returns `investigate`, while `exact/service_name` returns `stop_service_process`.
Update existing positive `stop_service_process` decision fixtures from:

```powershell
[pscustomobject]@{ matched_type='exact' }
```

to:

```powershell
[pscustomobject]@{ matched_type='exact'; matched_field='service_name' }
```

Do not add a default for a missing matched field; missing provenance must fail closed.

- [ ] **Step 5: Replace the normal-user process query with strict v2 consumption**

Refactor `Get-ServiceProcessExecutionIdentity` so the body follows these exact guards and return shape:

```powershell
if ($Service.ProcessIdentitySource -cne 'trusted_inventory_v2' -or
    $Service.ProcessIdentityStatus -cne 'complete') {
    Set-ServiceProcessIdentityFailureReason $FailureReason '受保护扫描没有提供完整服务进程身份，请重新扫描。'
    return $null
}
$first = Get-CurrentServiceExecutionSnapshot -ServiceName $Service.Name -FailureReason $FailureReason
if ($null -eq $first) { return $null }
$trustedPid = Get-StrictServiceProcessId $Service.ProcessId
if ($Service.Name -cne $first.Name -or $Service.State -cne 'Running' -or
    $null -eq $trustedPid -or $trustedPid -ne $first.ProcessId -or
    $Service.PathName -cne $first.PathName) {
    Set-ServiceProcessIdentityFailureReason $FailureReason '受保护扫描与当前服务的名称、状态、PID 或 PathName 不一致，请重新扫描。'
    return $null
}
try { $trustedPath = [System.IO.Path]::GetFullPath([string]$Service.ProcessPath) }
catch {
    Set-ServiceProcessIdentityFailureReason $FailureReason '受保护扫描的服务进程路径无效，请重新扫描。'
    return $null
}
$trustedName = [string]$Service.ProcessName
$trustedStart = ConvertFrom-InventoryCanonicalUtc ([string]$Service.ProcessStartTimeUtc)
if (-not [System.IO.Path]::IsPathRooted([string]$Service.ProcessPath) -or
    -not [System.IO.File]::Exists($trustedPath) -or $null -eq $trustedStart -or
    -not [string]::Equals($trustedPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals($trustedName, [System.IO.Path]::GetFileName($first.BinaryPath), [System.StringComparison]::OrdinalIgnoreCase)) {
    Set-ServiceProcessIdentityFailureReason $FailureReason '受保护扫描的服务进程身份与当前服务二进制不一致，请重新扫描。'
    return $null
}
$second = Get-CurrentServiceExecutionSnapshot -ServiceName $first.Name -FailureReason $FailureReason
if ($null -eq $second) { return $null }
if ($second.Name -cne $first.Name -or $second.State -cne 'Running' -or
    $second.ProcessId -ne $first.ProcessId -or $second.PathName -cne $first.PathName -or
    -not [string]::Equals($second.BinaryPath, $first.BinaryPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Set-ServiceProcessIdentityFailureReason $FailureReason '服务在身份交接期间发生漂移，请重新扫描。'
    return $null
}
return [pscustomobject]@{
    service_binary_path=$first.BinaryPath; process_id=$first.ProcessId
    process_name=$trustedName; process_path=$trustedPath
    process_start_time_utc=$trustedStart.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}
```

Remove the scan-time `Win32_Process` query from this helper; administrator execution-time process revalidation remains in `ActionEngine.ps1`.

- [ ] **Step 6: Run Profile and Schema 3 regression suites**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Profile.Tests.ps1,tests/Pester/Schema3.Tests.ps1 -Output Detailed"
```

Expected: zero failures. The existing mixed exact/contains test must still prove that a target matched only by `contains` cannot execute.

- [ ] **Step 7: Commit Task 3**

```powershell
git add src/Core/ProfileEngine.ps1 src/Core/Scanner.ps1 tests/Pester/Profile.Tests.ps1
git commit -m "fix: hand trusted process identity to service hits"
```

### Task 4: Execution and GUI end-to-end contracts

**Files:**
- Modify: `tests/Pester/ProcessStop.Tests.ps1`
- Modify: `tests/Gui.Tests.ps1`
- Modify: `tests/GuiPresentation.Tests.ps1`

- [ ] **Step 1: Add an execution-authority regression test**

In `ProcessStop.Tests.ps1`, create a valid pending action whose identity came from v2, then mock `Get-CurrentServiceProcessIdentity` with a different start time. Assert:

```powershell
$result.status | Should -BeExactly 'skipped'
$result.failure_stage | Should -BeExactly 'authorization'
$result.result_reason | Should -Match '启动时间|身份|重新扫描'
Assert-MockCalled Stop-Process -Times 0 -Exactly
```

Repeat for current PID and current path drift. This locks the rule that trusted inventory is scan evidence only; `ActionEngine.ps1` must still re-read administrator process identity before mutation.

- [ ] **Step 2: Add the GUI selection fixture**

In `Gui.Tests.ps1`, build a pending envelope with one HRWSCCtrl action:

```powershell
[pscustomobject]@{
    id='lenovo-hrwscctrl'; hit_type='service'; service_name='HRWSCCtrl'
    action='stop_service_process'; matched_pattern='HRWSCCtrl'; matched_type='exact'
    matched_field='service_name'; execution_class='manual_impact'; necessity='optional'
    default_selected=$false; requires_confirmation=$true
    impact_cn='只结束当前实例；联想服务可能重新拉起'
    cleanup_reason_cn='不使用联想电脑管家时可减少当前后台占用'
    service_binary_path='C:\Program Files (x86)\Lenovo\PCManager\wsctrl11.exe'
    process_id=[int]4321; process_name='wsctrl11.exe'
    process_path='C:\Program Files (x86)\Lenovo\PCManager\wsctrl11.exe'
    process_start_time_utc='2026-08-25T01:02:03.0000000Z'
}
```

Assert the review row is enabled but initially unchecked, displays necessity/impact/reason, becomes selected after the checkbox event, and appears in the reviewed subset only after the existing confirmation gate. Assert cancelling confirmation leaves execution invocation count at zero.

- [ ] **Step 3: Add observation presentation coverage**

In `GuiPresentation.Tests.ps1`, use the same profile identity with `action='investigate'`, `execution_class='observation'`, and:

```powershell
obs_reason='受保护扫描没有提供完整服务进程身份，请重新扫描。'
```

Assert the row has no selectable action, shows the observation reason, and never displays a success or clean-computer conclusion.

- [ ] **Step 4: Run all three focused suites**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/ProcessStop.Tests.ps1,tests/GuiPresentation.Tests.ps1,tests/Gui.Tests.ps1 -Output Detailed"
```

Expected: zero failures. No production GUI or ActionEngine edit is expected because both already implement selection and administrator identity binding; a failure here identifies a real regression and must be diagnosed before changing those modules.

- [ ] **Step 5: Commit Task 4**

```powershell
git add tests/Pester/ProcessStop.Tests.ps1 tests/Gui.Tests.ps1 tests/GuiPresentation.Tests.ps1
git commit -m "test: lock HRWSCCtrl selection and revalidation flow"
```

### Task 5: Documentation and complete automated verification

**Files:**
- Modify: `tests/schema-tests.ps1`
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Write failing documentation contract assertions**

Extend `tests/schema-tests.ps1` to require all of these facts:

```text
inventory_schema_version = 2
管理员只读清单携带 all-or-nothing 服务进程身份
complete 才能生成可选 stop_service_process
unavailable/not_running 只能观察并要求重新扫描
执行器再次核对 PID、名称、路径和 UTC 启动时间
真实 GUI/UAC/0 秒/5 秒/30 秒回读仍是独立验收
```

Keep the current v1.8.1 source-version assertion unchanged.

- [ ] **Step 2: Run unit contracts and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
```

Expected: documentation assertions fail because the published text still describes Inventory Schema v1.

- [ ] **Step 3: Update release and security documentation**

Add one v1.8.1 changelog bullet describing the protected v2 identity handoff. In README, explain that HRWSCCtrl is selectable only after a complete privileged inventory and defaults unchecked. In SECURITY, document the three identity states, internal trusted-source marker, two live service snapshots, and administrator execution-time process revalidation. State that v1 packages are rejected and rescanned rather than migrated.

- [ ] **Step 4: Run every project-owned automated gate in both runtimes**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
pwsh -NoProfile -File tests/run-unit.ps1
pwsh -NoProfile -File tests/run-gui-tests.ps1
git diff --check
```

Run the exact PSScriptAnalyzer command recorded in `.github/workflows/ci.yml`. Expected: every command exits 0, all test counts report zero failures, analyzer reports zero errors, and `git diff --check` prints nothing.

- [ ] **Step 5: Commit Task 5**

```powershell
git add README.md SECURITY.md CHANGELOG.md tests/schema-tests.ps1
git commit -m "docs: describe privileged process identity handoff"
```

### Task 6: Controlled real Windows acceptance

**Files:**
- No repository files are modified by this task.

- [ ] **Step 1: Stop at the destructive-action gate**

Present the exact target (`HRWSCCtrl`, current PID, `wsctrl11.exe` path), explain that the next GUI action will really end that process, and obtain a fresh explicit user approval. Prior design or implementation approval does not authorize this step.

- [ ] **Step 2: Capture the baseline without mutation**

Run read-only checks:

```powershell
$svc = Get-CimInstance Win32_Service -Filter "Name='HRWSCCtrl'"
$proc = if ([int]$svc.ProcessId -gt 0) { Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $svc.ProcessId) }
$svc | Select-Object Name,State,StartMode,ProcessId,PathName
$proc | Select-Object ProcessId,Name,ExecutablePath,CreationDate
```

Record the actual service state, StartMode, PID, binary path, and start time. If identity cannot be read even in the elevated collector, stop and report `unavailable`; do not bypass the gate.

- [ ] **Step 3: Exercise the desktop GUI path**

Launch `C:\Users\34615\Desktop\鼠鼠 Cleaner.lnk` as a normal user, approve the read-only inventory UAC, and verify that HRWSCCtrl appears as an enabled, initially unchecked item with correct necessity, impact, and reason. Select only that item, confirm the manual-impact dialog, then approve the execution UAC.

- [ ] **Step 4: Verify actual state at three observation points**

Immediately, after 5 seconds, and after 30 seconds, read `Win32_Service` and the old PID. Acceptance requires:

```text
old PID is absent
StartMode remains Manual
no backup package was created solely for stop_service_process
GUI terminal status matches the observed state
replacement PID means failed/verification, never success
```

If Lenovo starts a replacement process, capture its PID and ensure the GUI reason reports the restart. Do not claim durable closure from the initial process exit alone.

- [ ] **Step 5: Run one fresh post-action scan**

Approve the read-only inventory UAC again. Confirm the new service/process state is represented truthfully and no stale pending identity remains selectable.

- [ ] **Step 6: Final branch handoff**

Run:

```powershell
git status --short --branch
git log -7 --oneline
git diff HEAD~5 --check
```

Expected: no uncommitted implementation changes and five focused implementation/test/documentation commits after this plan. Report automated results and real-machine results separately. Do not merge, push, tag, publish a GitHub Release, or replace the desktop shortcut unless the user separately requests that delivery step.
