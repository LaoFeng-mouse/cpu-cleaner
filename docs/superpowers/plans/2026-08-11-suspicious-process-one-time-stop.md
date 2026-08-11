# Suspicious Process One-Time Stop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users explicitly stop a suspicious background process once, with PID/name/path/start-time identity replay and no path from “suspicious” to persistent cleanup.

**Architecture:** Add immutable process-start identity to scanner and pending records, then implement a separate `stop_process` entrypoint that consumes a hash-bound selected suspicious subset and rewrites per-item terminal status. The GUI gets a separate list and button; it never feeds suspicious rows into the OEM cleanup action allowlist.

**Tech Stack:** Windows PowerShell 5.1, `System.Diagnostics.Process`, WPF/XAML, Pester 5.9.0, pending Schema 2 envelope.

---

## File map

- Modify `src/Core/Scanner.ps1`: capture process start time and produce actionable suspicious identity only when complete.
- Modify `src/Core/ActionEngine.ps1`: strict suspicious row validation, identity replay, one-time stop, and result serialization.
- Modify `cpu-cleaner.ps1`: add separate `stop_process` mode.
- Modify `gui-cleaner.ps1`: project suspicious rows, build a selected hash-bound subset, launch/poll the stop process, and display results.
- Modify `src/Gui/MainWindow.xaml`: separate suspicious-process section and confirmation button.
- Modify `tests/Pester/Scanner.Tests.ps1`: start-time capture and protected/incomplete identity behavior.
- Create `tests/Pester/ProcessStop.Tests.ps1`: identity replay and stop-result tests.
- Modify `tests/Pester/Pending.Tests.ps1`: suspicious schema serialization tests.
- Modify `tests/Gui.Tests.ps1`: selection separation and GUI lifecycle tests.

### Task 1: Capture immutable-enough process identity

**Files:**
- Modify: `src/Core/Scanner.ps1:116-196`
- Modify: `tests/Pester/Scanner.Tests.ps1`

- [ ] **Step 1: Write failing scanner tests**

Add tests around a supplied top-process record:

```powershell
It 'preserves PID name path and UTC start time on suspicious records' {
    $top = [pscustomobject]@{
        PID=4242; Name='suspect'; 'CPU%'=8; MemMB=50
        Path='C:\Temp\suspect.exe'; StartTimeUtc='2026-08-11T00:00:00.0000000Z'
    }
    $s = @(Get-SuspiciousProcesses @($top))[0]
    $s.PID | Should -Be 4242
    $s.Name | Should -BeExactly 'suspect'
    $s.Path | Should -BeExactly 'C:\Temp\suspect.exe'
    $s.StartTimeUtc | Should -BeExactly '2026-08-11T00:00:00.0000000Z'
    $s.CanStop | Should -BeTrue
}

It 'marks a suspicious row non-stoppable when path or start time is unavailable' {
    $top = [pscustomobject]@{PID=4242;Name='suspect';'CPU%'=8;MemMB=50;Path='';StartTimeUtc=''}
    $s = @(Get-SuspiciousProcesses @($top))[0]
    $s.CanStop | Should -BeFalse
    $s.StopBlockReason | Should -Match '身份不完整'
}
```

- [ ] **Step 2: Run Scanner tests and verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/Scanner.Tests.ps1 -PassThru; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

Expected: `StartTimeUtc`, `CanStop`, and `StopBlockReason` are absent.

- [ ] **Step 3: Implement capture and classification**

When sampling processes, capture start time safely:

```powershell
$startTimeUtc = ''
try { $startTimeUtc = $_.StartTime.ToUniversalTime().ToString('o') } catch {}
```

Persist it in top-process records. In `Get-SuspiciousProcesses`, set:

```powershell
$completeIdentity = [int64]$p.PID -gt 0 -and
    -not [string]::IsNullOrWhiteSpace([string]$p.Name) -and
    [System.IO.Path]::IsPathRooted([string]$p.Path) -and
    -not [string]::IsNullOrWhiteSpace([string]$p.StartTimeUtc)
```

Return `StartTimeUtc`, `CanStop=$completeIdentity`, and a concrete `StopBlockReason`. The existing system-process deny list remains non-stoppable even if a caller supplies a complete identity.

- [ ] **Step 4: Run Scanner tests and commit**

Expected: all Scanner tests pass.

```powershell
git add -- src/Core/Scanner.ps1 tests/Pester/Scanner.Tests.ps1
git commit -m "feat: capture suspicious process identity"
```

### Task 2: Validate and serialize suspicious pending rows strictly

**Files:**
- Modify: `src/Core/ActionEngine.ps1:624-653,773-898`
- Modify: `tests/Pester/Pending.Tests.ps1`

- [ ] **Step 1: Write failing pending-shape tests**

```powershell
It 'serializes complete suspicious process identity with pending status' {
    $s = [pscustomobject]@{PID=42;Name='suspect';'CPU%'=8;MemMB=50;Path='C:\Temp\suspect.exe';Reason='temp';StartTimeUtc='2026-08-11T00:00:00.0000000Z';CanStop=$true;StopBlockReason=''}
    Save-PendingActions -Hits @() -Suspicious @($s)
    $pending = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $pending.suspicious[0].status | Should -BeExactly 'pending'
    $pending.suspicious[0].StartTimeUtc | Should -BeExactly $s.StartTimeUtc
}

It 'rejects a selected suspicious row with array or missing identity fields' {
    $row = [pscustomobject]@{PID=@(42);Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z';status='pending'}
    { Assert-SuspiciousPendingRow $row } | Should -Throw '*PID*'
}
```

- [ ] **Step 2: Run Pending tests and verify RED**

Expected: required fields and validator do not exist.

- [ ] **Step 3: Implement strict suspicious shape**

Add `Assert-SuspiciousPendingRow` requiring:

- scalar positive `Int32`/`Int64` PID;
- nonblank scalar `Name`, rooted scalar `Path`, and round-trip UTC `StartTimeUtc`;
- exact status in `pending/success/failed/skipped`;
- Boolean `CanStop=true` for selected subsets.

Preserve non-stoppable observations in the main scan file, but `Build-SuspiciousSubsetPayload` must accept only rows that pass the strict selected shape. Keep them under `suspicious`; never copy them into `actions`.

- [ ] **Step 4: Run Pending tests and commit**

```powershell
git add -- src/Core/ActionEngine.ps1 tests/Pester/Pending.Tests.ps1
git commit -m "feat: validate suspicious process pending identity"
```

### Task 3: Add a separate hash-bound stop entrypoint

**Files:**
- Modify: `cpu-cleaner.ps1:18-29,61-97`
- Modify: `src/Core/ActionEngine.ps1`
- Create: `tests/Pester/ProcessStop.Tests.ps1`

- [ ] **Step 1: Write failing identity-replay tests**

Use wrapper functions so tests never stop the Pester host:

```powershell
Describe 'one-time suspicious process stop' {
    It 'skips when PID now belongs to a different path' {
        Mock Get-CurrentProcessIdentity { [pscustomobject]@{PID=42;Name='suspect';Path='C:\Other\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'} }
        Mock Stop-Process {}
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'skipped'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'stops only an exact identity and confirms exit' {
        Mock Get-CurrentProcessIdentity { [pscustomobject]@{PID=42;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'} } -ParameterFilter { -not $script:afterStop }
        Mock Stop-Process { $script:afterStop=$true }
        Mock Get-Process { $null } -ParameterFilter { $script:afterStop }
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'success'
        Should -Invoke Stop-Process -Times 1 -Exactly
    }
}
```

Also test name mismatch, start-time mismatch, missing path, protected-process deny list, PID disappearance, stop failure, and process still present after stop.

- [ ] **Step 2: Run the new test and verify RED**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/ProcessStop.Tests.ps1 -PassThru; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

- [ ] **Step 3: Implement identity replay**

Add:

```powershell
function Test-SameProcessIdentity($Expected, $Current) {
    return $Expected.PID -eq $Current.PID -and
        [string]::Equals($Expected.Name,$Current.Name,[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([IO.Path]::GetFullPath($Expected.Path),[IO.Path]::GetFullPath($Current.Path),[StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($Expected.StartTimeUtc,$Current.StartTimeUtc,[StringComparison]::Ordinal)
}
```

`Invoke-OneTimeProcessStop` must validate shape, deny protected names, retrieve current identity, compare all four fields, call `Stop-Process -Id ... -Force -ErrorAction Stop`, then use `Get-Process -Id ... -ErrorAction SilentlyContinue` to verify exit. Return a copy with terminal `status` and `result_reason`.

- [ ] **Step 4: Add `stop_process` mode**

Extend `ValidateSet` to include `stop_process`. In that mode require both `PendingFileArg` and a valid `PendingSha256Arg`, open and lock the file through the existing size/link/reparse defenses, verify SHA-256, require `actions` and `observations` empty, process each selected suspicious row, and rewrite the same locked file with terminal results. Do not require administrator elevation and do not call `Invoke-Clean`.

- [ ] **Step 5: Run ProcessStop plus Auth tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester @('tests/Pester/ProcessStop.Tests.ps1','tests/Pester/Auth.Tests.ps1') -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: all pass and every `Stop-Process` call is mocked.

- [ ] **Step 6: Commit**

```powershell
git add -- cpu-cleaner.ps1 src/Core/ActionEngine.ps1 tests/Pester/ProcessStop.Tests.ps1
git commit -m "feat: add identity-bound one-time process stop"
```

### Task 4: Add a separate suspicious-process GUI flow

**Files:**
- Modify: `src/Gui/MainWindow.xaml:77-83`
- Modify: `gui-cleaner.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Write failing GUI projection and separation tests**

```powershell
It 'projects suspicious rows separately and never includes them in reviewed actions' {
    $pending = New-GuiReviewPendingFixture
    $pending.suspicious = @([pscustomobject]@{PID=42;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z';Reason='temp';CanStop=$true;StopBlockReason='';status='pending'})
    $rows = @(Get-GuiSuspiciousViewItems $pending)
    $rows.Count | Should -Be 1
    $rows[0].IsChecked | Should -BeFalse
    $rows[0].CanStop | Should -BeTrue
    @(Resolve-GuiReviewedActions -List $script:Win.FindName('PendingList')).Count | Should -Be 0
}

It 'enables stop only after an explicit stoppable selection' {
    $list = $script:Win.FindName('SuspiciousList')
    $row = [pscustomobject]@{IsChecked=$false;CanStop=$true}
    $list.ItemsSource=@($row)
    Update-GuiStopProcessAvailability -List $list
    $script:Win.FindName('BtnStopProcesses').IsEnabled | Should -BeFalse
    $row.IsChecked=$true
    Update-GuiStopProcessAvailability -List $list
    $script:Win.FindName('BtnStopProcesses').IsEnabled | Should -BeTrue
}
```

- [ ] **Step 2: Run GUI tests and verify RED**

Expected: new controls and functions do not exist.

- [ ] **Step 3: Implement separate XAML section**

Under Review add `SuspiciousList`, a boundary text stating “只结束本次进程，不删除文件或关闭自启”, and `BtnStopProcesses` with `IsEnabled="False"`. Its checkbox binds `IsChecked` and `CanStop`; it is never selected by `BtnSelectAll` for OEM actions.

- [ ] **Step 4: Implement hash-bound GUI lifecycle**

Create `Get-GuiSuspiciousViewItems`, `Update-GuiStopProcessAvailability`, `New-GuiSuspiciousSubsetPayload`, `Start-GuiSuspiciousStop`, and `Complete-SuspiciousStopPoll`. Use a temp filename prefix distinct from cleanup subsets, write only selected suspicious rows, compute SHA-256, and start:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode stop_process -PendingFileArg <path> -PendingSha256Arg <hash>
```

Poll asynchronously, require a zero exit code plus strict result shape, and display each terminal status. On unknown process status, preserve the exact diagnostic subset as the existing cleanup flow does.

- [ ] **Step 5: Run full GUI tests and commit**

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
git add -- src/Gui/MainWindow.xaml gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: add explicit suspicious process stop UI"
```

Expected: GUI suite passes; OEM cleanup and suspicious stop remain separate allowlists and buttons.

### Task 5: Controlled end-to-end acceptance and full regression

**Files:**
- Modify only if acceptance exposes a defect.

- [ ] **Step 1: Run every automated suite and static check**

Use all commands from Task 6 of the OEM core plan, plus:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/ProcessStop.Tests.ps1 -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: zero failures, AST clean, JSON valid, and `git diff --check` clean.

- [ ] **Step 2: Run a controlled real process test**

Start a disposable `powershell.exe` process that only waits, capture its PID, executable path, and UTC start time with `Get-Process`, build a one-row pending v2 subset, hash it, and run `cpu-cleaner.ps1 -Mode stop_process` against that subset. Never target an existing user or system process.

Expected: the disposable process exits, the subset records `status=success`, and no file/service/task/registry state changes.

- [ ] **Step 3: Verify stale identity refusal**

Create another disposable process but alter the saved start time or path in the subset before hashing it.

Expected: `status=skipped`; the disposable process remains running and is then closed using its exact captured PID as test teardown.

- [ ] **Step 4: Run the real GUI path**

Click through scan and Review. If a naturally suspicious process is listed, verify it is unselected and the stop button disabled; do not terminate it. Use only the disposable test process for an actual GUI stop acceptance.

- [ ] **Step 5: Final review gate**

Review commit scope, latest automated output, real scan evidence, GUI evidence, controlled stop evidence, and any remaining degraded collectors. Only then decide whether to merge into the release branch and push to GitHub; public release packaging remains a separate task.
