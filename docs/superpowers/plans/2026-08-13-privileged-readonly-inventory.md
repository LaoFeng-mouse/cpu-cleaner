# Privileged Read-Only Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the normal-privilege GUI perform a complete, trustworthy OEM service and scheduled-task scan through one minimal elevated read-only inventory collector, while preserving fail-closed cleanup authorization and an explicit limited-scan fallback when UAC is cancelled.

**Architecture:** Add an internal `scan_inventory` mode that writes a nonce-bound, ACL-protected package under `%ProgramData%\MouseCleaner\ScanResults`. The normal scanner consumes that package through a strict one-snapshot verifier and continues to generate reports and pending actions through the existing rule engine. The GUI owns a separate asynchronous UAC collector lifecycle before starting its existing normal scan job; cancelled UAC starts only `-AllowLimited` mode.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, WPF, Pester, Windows ACL APIs, CIM, ScheduledTasks/Task Scheduler COM, SHA-256, PSScriptAnalyzer.

---

## Task 1: Build the trusted inventory package reader

**Files:**

- Create: `src/Core/InventoryManager.ps1`
- Create: `tests/Pester/Inventory.Tests.ps1`
- Modify: `cpu-cleaner.ps1:51-60`

- [ ] **Step 1: Add failing nonce, path, ACL, and parser tests**

Create `tests/Pester/Inventory.Tests.ps1`. Dot-source the same core modules as production, then cover these cases:

```powershell
Describe 'trusted privileged inventory' {
    It 'accepts only a 64-character lowercase hexadecimal nonce' {
        Test-InventoryNonce ('a' * 64) | Should -BeTrue
        Test-InventoryNonce ('A' * 64) | Should -BeFalse
        Test-InventoryNonce ('a' * 63) | Should -BeFalse
        Test-InventoryNonce ('g' * 64) | Should -BeFalse
        Test-InventoryNonce '..\inventory.json' | Should -BeFalse
    }

    It 'resolves inventory.json only below the fixed trust root' {
        Mock Get-SecureInventoryRoot { 'C:\ProgramData\MouseCleaner\ScanResults' }
        Resolve-InventoryPackagePath ('b' * 64) |
            Should -Be 'C:\ProgramData\MouseCleaner\ScanResults\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\inventory.json'
    }

    It 'rejects an inventory file writable by the reader SID' {
        Mock Get-InventoryAclDescriptor {
            [pscustomobject]@{
                OwnerSid = 'S-1-5-18'; AreAccessRulesProtected = $true
                Rules = @([pscustomobject]@{ Sid=$script:ReaderSid; Type='Allow'; Rights='Write, Read' })
            }
        }
        { Assert-TrustedInventoryPathAcl 'C:\trusted\inventory.json' $script:ReaderSid } |
            Should -Throw '*write*'
    }

    It 'rejects duplicate JSON properties before conversion' {
        { ConvertFrom-StrictInventoryJson '{"nonce":"a","nonce":"b"}' } |
            Should -Throw '*duplicate*'
    }

    It 'rejects a stale package, nonce mismatch, SID mismatch, and incomplete health' {
        $base = New-TestInventoryPackage
        foreach ($mutation in @(
            { param($p) $p.generated_utc = [DateTime]::UtcNow.AddMinutes(-6).ToString('o') },
            { param($p) $p.nonce = 'c' * 64 },
            { param($p) $p.collector_sid = 'S-1-5-21-999' },
            { param($p) $p.health.tasks = 'unavailable' }
        )) {
            $copy = $base | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            & $mutation $copy
            { Test-InventoryPackageShape $copy ('a' * 64) $script:ReaderSid } | Should -Throw
        }
    }
}
```

Also add focused tests for unprotected DACLs, untrusted owners, reparse points in every path component, excessive size, excessive JSON depth, scalar/array confusion, null records, invalid service/task fields, final-path mismatch, hardlink count greater than one, and replacement between metadata lookup and locked-stream read.

- [ ] **Step 2: Run the new tests and confirm they fail for missing commands**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Inventory.Tests.ps1' -EnableExit"
```

Expected: nonzero exit; failures name `Test-InventoryNonce`, `Read-TrustedInventoryPackage`, and related missing functions.

- [ ] **Step 3: Implement strict path and package validation**

Create `src/Core/InventoryManager.ps1` with these public entry points and constants:

```powershell
$script:InventorySchemaVersion = 1
$script:MaxInventoryJsonBytes = 8MB
$script:MaxInventoryJsonDepth = 12
$script:MaxInventoryRecords = 20000

function Test-InventoryNonce([string]$Nonce) {
    return -not [string]::IsNullOrEmpty($Nonce) -and $Nonce -cmatch '^[0-9a-f]{64}$'
}

function Get-SecureInventoryRoot {
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrWhiteSpace($programData)) { throw 'ProgramData is unavailable.' }
    return [IO.Path]::GetFullPath((Join-Path $programData 'MouseCleaner\ScanResults'))
}

function Resolve-InventoryPackagePath([string]$Nonce) {
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    $root = Get-SecureInventoryRoot
    $path = [IO.Path]::GetFullPath((Join-Path (Join-Path $root $Nonce) 'inventory.json'))
    $prefix = $root.TrimEnd('\') + '\'
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inventory path escaped the trusted root.'
    }
    return $path
}

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function ConvertFrom-StrictInventoryJson([string]$Json) {
    Assert-JsonPropertyNamesUnique $Json
    return ConvertFrom-JsonCompat $Json
}
```

Implement inventory-specific `Get-InventoryAclDescriptor`, `Test-TrustedInventoryAclDescriptor`, `Assert-TrustedInventoryPathAcl`, and `Assert-InventoryPathIsNotReparsePoint`. Trust only SYSTEM (`S-1-5-18`) or BUILTIN Administrators (`S-1-5-32-544`) as owner, require protected DACLs, allow write/delete/change-permission/ownership only to those two principals, and require the supplied reader SID to have read/read-control without mutation rights.

Implement `Open-TrustedInventoryReadStream` by reusing the existing native final-path and hardlink helpers from `ActionEngine.ps1`: open once with read access and `FileShare.Read`, reject any reparse component, verify final path and one link, then keep the stream locked until all bytes are read. Implement `Read-TrustedInventoryPackage` so the same bounded byte array is used for strict JSON parsing and SHA-256 calculation.

Implement `Test-InventoryPackageShape` with an allowlist of top-level fields and strict scalar checks. Require schema 1, exact nonce and SID, timestamp in `[UtcNow-5m, UtcNow+1m]`, `services/tasks` arrays, both health fields equal to `complete`, warning strings, and bounded record arrays. Require service fields `Name`, `DisplayName`, `State`, `StartMode`, `PathName`, `ProcessId`; require task fields `TaskName`, `TaskPath`, `State`, `Author`, `Description`, `Actions`.

- [ ] **Step 4: Load the module after its dependencies**

In `cpu-cleaner.ps1`, append `InventoryManager` after `BackupManager`:

```powershell
$coreModules = @(
    'Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine',
    'ActionEngine','BackupManager','InventoryManager'
)
```

- [ ] **Step 5: Run targeted tests**

Run both shells:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Inventory.Tests.ps1' -EnableExit"
pwsh -NoProfile -Command "Invoke-Pester -Path './tests/Pester/Inventory.Tests.ps1' -EnableExit"
```

Expected: all inventory reader tests pass in PowerShell 5.1 and PowerShell 7.

- [ ] **Step 6: Commit**

```powershell
git add cpu-cleaner.ps1 src/Core/InventoryManager.ps1 tests/Pester/Inventory.Tests.ps1
git commit -m "feat: verify trusted privileged inventory"
```

## Task 2: Add the elevated read-only inventory writer

**Files:**

- Modify: `src/Core/InventoryManager.ps1`
- Modify: `cpu-cleaner.ps1:19-45,75-140`
- Modify: `tests/Pester/Inventory.Tests.ps1`

- [ ] **Step 1: Add failing collector and ACL-writer tests**

Add tests proving:

```powershell
It 'refuses scan_inventory outside an administrator token' { ... }
It 'does not invoke any mutation command while collecting inventory' { ... }
It 'writes through a temporary file and atomically publishes inventory.json' { ... }
It 'does not leave a consumable package when flush, move, or ACL recheck fails' { ... }
It 'creates protected ACLs with reader read-only access' { ... }
It 'deletes only trusted 64-hex packages older than 24 hours' { ... }
It 'retains uncertain or untrusted stale entries' { ... }
```

Mock `Disable-Service`, `Stop-Service`, `Set-Service`, `Unregister-ScheduledTask`, registry mutation commands, and action-engine mutation entry points; assert zero calls.

- [ ] **Step 2: Run tests and confirm writer cases fail**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Inventory.Tests.ps1' -EnableExit"
```

Expected: reader cases remain green; new writer cases fail.

- [ ] **Step 3: Implement protected ACL creation and atomic publication**

Add:

```powershell
function New-ProtectedInventorySecurity([string]$ReaderSid, [switch]$Directory) {
    $security = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $security.SetAccessRuleProtection($true, $false)
    $inherit = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else { [Security.AccessControl.InheritanceFlags]::None }
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity, [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit, $none, $allow)
        $null = $security.AddAccessRule($rule)
    }
    $reader = [Security.Principal.SecurityIdentifier]::new($ReaderSid)
    $readRights = [Security.AccessControl.FileSystemRights]'ReadAndExecute, ReadPermissions, Synchronize'
    $readerRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $reader, $readRights, $inherit, $none, $allow)
    $null = $security.AddAccessRule($readerRule)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    return $security
}
```

Add `Write-TrustedInventoryPackage` that creates the fixed root and nonce directory with protected ACLs, writes UTF-8 without BOM to `inventory.<guid>.tmp`, calls `Flush($true)`, applies and verifies the file ACL, atomically renames to `inventory.json`, then reopens and verifies the published package. On any failure, remove only the validated nonce-local temporary file; never follow a reparse point.

Add `Remove-StaleTrustedInventoryPackages` that considers only direct child directories matching `^[0-9a-f]{64}$`, older than 24 hours, with trusted ACL and no reparse point. Retain anything uncertain.

- [ ] **Step 4: Add `scan_inventory` mode**

Extend the script parameters:

```powershell
[ValidateSet('scan','scan_inventory','clean','restore','update','stop_process')]
[string]$Mode = 'scan',
[string]$InventoryNonce = '',
[switch]$AllowLimited
```

Add:

```powershell
function Invoke-ScanInventory([string]$Nonce) {
    if (-not (Is-Admin)) { throw 'scan_inventory requires administrator rights.' }
    if (-not (Test-InventoryNonce $Nonce)) { throw 'Invalid inventory nonce.' }
    $readerSid = Get-CurrentUserSid
    $services = @(Get-ServicesInfo -RequireComplete)
    $tasks = @(Get-TasksInfo -RequireComplete)
    if ($services.Count -eq 0 -or $tasks.Count -eq 0) {
        throw 'Privileged inventory collection returned an incomplete category.'
    }
    $package = [ordered]@{
        inventory_schema_version = 1
        nonce = $Nonce
        generated_utc = [DateTime]::UtcNow.ToString('o')
        collector_sid = $readerSid
        services = $services
        tasks = $tasks
        health = [ordered]@{ services='complete'; tasks='complete' }
        warnings = @($script:ScanWarnings)
    }
    Remove-StaleTrustedInventoryPackages
    Write-TrustedInventoryPackage $Nonce $readerSid $package
}
```

Dispatch it before normal scan logic, return nonzero on every validation or collection failure, and do not create reports or pending actions in this mode.

- [ ] **Step 5: Run focused and mutation-regression tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Inventory.Tests.ps1','.\tests\Pester\Clean.Tests.ps1','.\tests\Pester\Restore.Tests.ps1' -EnableExit"
```

Expected: zero failures; writer tests prove the collector is read-only.

- [ ] **Step 6: Commit**

```powershell
git add cpu-cleaner.ps1 src/Core/InventoryManager.ps1 tests/Pester/Inventory.Tests.ps1
git commit -m "feat: collect privileged readonly inventory"
```

## Task 3: Consume trusted inventory and make limited scanning explicit

**Files:**

- Modify: `cpu-cleaner.ps1:75-140`
- Modify: `src/Core/Scanner.ps1:1-30,213-430`
- Modify: `tests/Pester/Scanner.Tests.ps1`
- Modify: `tests/Pester/Pending.Tests.ps1`

- [ ] **Step 1: Add failing full/limited scan tests**

Add tests for these contracts:

```powershell
It 'uses only the verified package services and tasks when InventoryNonce is supplied' { ... }
It 'fails closed when the trusted package is invalid' { ... }
It 'fails default scan when complete task inventory is unavailable' { ... }
It 'marks tasks unavailable and emits a warning in AllowLimited mode' { ... }
It 'marks services degraded when normal-token service collection fails' { ... }
It 'keeps task and service hits as observations when their health is not complete' { ... }
It 'still allows an independently healthy autostart exact hit' { ... }
```

Reuse the existing `Save-PendingActions` health downgrade tests. Add only missing cross-category assertions; do not create a second authorization gate.

- [ ] **Step 2: Run the scanner/pending tests and confirm the new cases fail**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Scanner.Tests.ps1','.\tests\Pester\Pending.Tests.ps1' -EnableExit"
```

Expected: new inventory/limited cases fail; existing health downgrade cases remain green.

- [ ] **Step 3: Route full scans through the verified package**

At the start of normal scan dispatch:

```powershell
$inventory = $null
if (-not [string]::IsNullOrEmpty($InventoryNonce)) {
    $inventory = Read-TrustedInventoryPackage $InventoryNonce (Get-CurrentUserSid)
}

if ($null -ne $inventory) {
    $services = @($inventory.Package.services)
    $tasks = @($inventory.Package.tasks)
    Set-ScanHealth -Category services -State complete
    Set-ScanHealth -Category tasks -State complete
} else {
    $services = @(Get-ServicesInfo)
    if ($AllowLimited) {
        $tasks = @()
        Set-ScanHealth -Category tasks -State unavailable
        Add-ScanWarning '计划任务未通过管理员只读清单检查；本次结果不代表系统干净。'
    } else {
        $tasks = @(Get-TasksInfo -RequireComplete)
    }
}
```

Make `Get-ServicesInfo -RequireComplete` and `Get-TasksInfo -RequireComplete` throw if their category is not complete. In `-AllowLimited`, catch normal service collection errors, return an empty or degraded partial array as appropriate, set `services=degraded`, and add a warning. Never reinterpret task access denial as an empty complete list.

- [ ] **Step 4: Keep the existing pending health gate authoritative**

Do not duplicate `Save-PendingActions` policy. Verify its current rule still enforces:

```powershell
$category = if ($hit.hit_type -eq 'service') { 'services' }
            elseif ($hit.hit_type -eq 'task') { 'tasks' }
            else { $null }
if ($category -and $ScanHealth.$category -ne 'complete') {
    # observation only; never add to actions
}
```

If production code already has equivalent logic, leave it unchanged and retain the new regression test.

- [ ] **Step 5: Run core regression suites**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester' -EnableExit"
pwsh -NoProfile -Command "Invoke-Pester -Path './tests/Pester' -EnableExit"
```

Expected: zero failed tests in both shells; pass count is higher than the 336-test baseline.

- [ ] **Step 6: Commit**

```powershell
git add cpu-cleaner.ps1 src/Core/Scanner.ps1 tests/Pester/Scanner.Tests.ps1 tests/Pester/Pending.Tests.ps1
git commit -m "feat: enforce full and limited scan health"
```

## Task 4: Add the GUI's asynchronous UAC inventory lifecycle

**Files:**

- Modify: `gui-cleaner.ps1:90-160,850-1120,1488-1738`
- Modify: `tests/Gui.Tests.ps1:340-650,1540-2050`

- [ ] **Step 1: Add failing GUI lifecycle tests**

Add tests that mock `Start-Process`, timers, and scan jobs:

```powershell
It 'generates a cryptographic 64-lowercase-hex nonce' { ... }
It 'starts scan_inventory with RunAs and passes only the nonce' { ... }
It 'starts the normal scan job with InventoryNonce only after confirmed exit 0' { ... }
It 'starts AllowLimited after Win32Exception 1223 UAC cancellation' { ... }
It 'does not downgrade collector exit failure to a full scan' { ... }
It 'times the collector out at 60 seconds' { ... }
It 'never consumes inventory while process status is unknown' { ... }
It 'blocks duplicate scan, clean, restore, and stop-process entry points while latched' { ... }
It 'keeps the mutation latch after timeout until process exit is confirmed' { ... }
It 'cleans up timers and process handles on each terminal path' { ... }
```

- [ ] **Step 2: Run GUI tests and confirm lifecycle tests fail**

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
```

Expected: existing GUI tests pass; new inventory lifecycle tests fail.

- [ ] **Step 3: Add nonce generation and independent lifecycle state**

Add:

```powershell
function New-GuiInventoryNonce {
    $bytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

$script:InventoryProcess = $null
$script:InventoryTimer = $null
$script:InventoryNonce = ''
$script:InventoryDeadlineUtc = [DateTime]::MinValue
$script:InventoryUnknownProbeCount = 0
$script:InventoryInProgress = $false
```

Reuse the semantics of `Get-GuiExecutionProcessStatus` for a separate `Get-GuiInventoryProcessStatus`: `running`, `exited`, or `unknown`; never infer success from process object existence.

- [ ] **Step 4: Split the scan job starter from the UAC collector**

Refactor the existing job code into:

```powershell
function Start-GuiNormalScanJob([string]$InventoryNonce = '', [switch]$AllowLimited) {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:CoreScript,'-Mode','scan')
    if ($AllowLimited) { $args += '-AllowLimited' }
    elseif ($InventoryNonce) { $args += @('-InventoryNonce',$InventoryNonce) }
    # Start the existing normal-token Start-Job lifecycle with these arguments.
}
```

Implement `Start-GuiInventoryCollection` using `Start-Process powershell.exe -Verb RunAs -PassThru` with only `-Mode scan_inventory -InventoryNonce <nonce>`. Catch `ComponentModel.Win32Exception` with `NativeErrorCode -eq 1223` and call `Start-GuiNormalScanJob -AllowLimited`. Other launch failures enter the error state and offer retry or an explicit limited scan.

Poll every 250 ms. On confirmed exit 0 call `Start-GuiNormalScanJob -InventoryNonce $script:InventoryNonce`; on nonzero exit show the real collector failure; after 60 seconds stop polling but retain the mutation latch until exit is confirmed. Keep the existing normal scan's 180-second timeout.

- [ ] **Step 5: Add truthful localized status text**

Add Chinese and English keys equivalent to:

```powershell
scan_requesting_inventory = '正在请求管理员只读授权'
scan_collecting_inventory = '正在读取完整服务和计划任务'
scan_validating_inventory = '正在验证受保护扫描结果'
scan_limited_warning = '计划任务和完整服务信息未检查，本次结果不能判断电脑干净。'
scan_inventory_readonly = '只读取服务和计划任务，不会修改系统设置。'
```

Ensure limited results use warning presentation and never show the clean/healthy empty-state copy.

- [ ] **Step 6: Run GUI tests in STA**

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
```

Expected: zero failures; pass count is higher than the 169-test baseline.

- [ ] **Step 7: Commit**

```powershell
git add gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: add readonly inventory UAC scan flow"
```

## Task 5: Update product documentation and presentation regression coverage

**Files:**

- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `design-qa.md`
- Modify: `tests/GuiPresentation.Tests.ps1`

- [ ] **Step 1: Add a failing presentation assertion**

Add a test that feeds limited scan health into the results presentation and requires warning state/copy while forbidding the clean empty-state string.

- [ ] **Step 2: Run the presentation tests and confirm failure**

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\GuiPresentation.Tests.ps1' -EnableExit"
```

- [ ] **Step 3: Document the permission model and limitations**

Document:

- GUI remains normal privilege.
- One UAC prompt grants read-only service/task inventory collection.
- Cancellation produces an explicitly incomplete scan.
- Incomplete service/task categories cannot authorize cleanup.
- Cleanup still requires user selection, subset hash binding, administrator revalidation, trusted backup, and restore.
- Task-file ACLs are never modified and task XML is not parsed directly.

Update `design-qa.md` with the expected idle, UAC request, privileged collection, normal scan, complete results, limited warning, and error states.

- [ ] **Step 4: Run presentation and encoding checks**

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\GuiPresentation.Tests.ps1' -EnableExit"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-unit.ps1
```

Expected: zero failures and no mojibake markers.

- [ ] **Step 5: Commit**

```powershell
git add README.md CHANGELOG.md design-qa.md tests/GuiPresentation.Tests.ps1
git commit -m "docs: explain privileged readonly scan flow"
```

## Task 6: Run full automation and real Windows acceptance

**Files:**

- Create: `docs/acceptance/2026-08-13-privileged-readonly-inventory.md`
- Modify only if a failure proves a defect: relevant source/test files above

- [ ] **Step 1: Run all automated gates from a normal console**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester' -EnableExit"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-unit.ps1
pwsh -NoProfile -Command "Invoke-Pester -Path './tests/Pester' -EnableExit"
```

Expected: zero failed tests in every command.

- [ ] **Step 2: Run static analysis and repository hygiene checks**

```powershell
Invoke-ScriptAnalyzer -Path .\cpu-cleaner.ps1,.\gui-cleaner.ps1,.\src -Recurse -Severity Error
git diff --check
git status --short
```

Expected: no analyzer errors; no whitespace errors; only intentional files plus pre-existing untracked `artifacts/` and `gui-live-idle.png` appear.

- [ ] **Step 3: Perform the approved-UAC live scan**

Launch the normal GUI, click safe scan, approve UAC, and record:

- GUI itself is not elevated.
- collector exits 0 within 60 seconds.
- pending health says `services=complete`, `tasks=complete`.
- task count is nonzero; compare with the current elevated host snapshot (previously 297, but do not hard-code that changing machine count).
- OEM service/task findings appear through existing profiles.
- Chinese UI and logs have no mojibake.

- [ ] **Step 4: Perform the cancelled-UAC live scan**

Start a second scan and cancel UAC. Record that `-AllowLimited` completes, task health is `unavailable`, the warning is visible, no clean-system conclusion is shown, and service/task matches are observations rather than actions.

- [ ] **Step 5: Perform one reversible clean/restore cycle**

Only if the complete scan produces a user-selected, narrow, currently revalidated action, run clean with UAC. Verify the selected target changed, a trusted backup exists, then restore and verify the original state. If no safe candidate exists, record the gate as not exercised instead of inventing or broadening a target.

- [ ] **Step 6: Record exact evidence and rerun affected tests after any fix**

Create the acceptance file with command, timestamp, exit code, pass/fail counts, inventory health, task/service counts, screenshots/log paths, selected cleanup identity, backup path, and final restored state. Do not claim full acceptance if either UAC branch or restore remains untested.

- [ ] **Step 7: Commit acceptance evidence**

```powershell
git add docs/acceptance/2026-08-13-privileged-readonly-inventory.md
git commit -m "test: record privileged inventory acceptance"
```

## Completion gate

Implementation is complete only when all six task commits exist, PowerShell 5.1 and 7 suites are green, GUI STA tests are green, static analysis and `git diff --check` are clean, approved-UAC full scan passes, cancelled-UAC limited scan is truthful and non-actionable for incomplete categories, and any exercised clean target is restored to its original state. Packaging, GitHub push, release creation, and public publication remain separate, explicitly authorized steps.
