# HRWSCCtrl Process Stop and Result Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace HRWSCCtrl's incorrect service-disable action with an identity-bound one-time service-process stop and carry truthful per-item result reasons from the elevated executor to the completed GUI.

**Architecture:** Add `stop_service_process` as a manual-impact-only action produced from an exact service matcher. The elevated clean executor revalidates the scanned service and process identity immediately before `Stop-Process`, verifies both old-PID exit and service restart state, and skips the backup pipeline because the operation is non-persistent. Terminal result metadata is validated, persisted, merged, and rendered end-to-end.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, WMI/CIM (`Win32_Service`, `Win32_Process`), Pester, WPF/XAML, JSON Schema 3 profile and pending envelopes.

---

## File map

- Modify `bloatware-profiles.json`: change HRWSCCtrl to the new one-time action and truthful copy.
- Modify `src/Core/ProfileEngine.ps1`: validate and authorize the new action only for the confirmed manual-impact shape.
- Modify `src/Core/Scanner.ps1`: enrich the exact service hit with a complete service/process identity or downgrade it to observation.
- Modify `src/Core/ActionEngine.ps1`: validate the identity, stop and verify the service process, avoid backup creation for this action, and persist result metadata.
- Modify `src/Gui/Presentation.ps1`: render terminal `result_reason` and `failure_stage`.
- Modify `gui-cleaner.ps1`: strictly read and merge immutable result metadata.
- Modify `src/Gui/MainWindow.xaml`: expose the concrete result reason in the completed list if the existing binding does not already show `Reason`.
- Modify `tests/Pester/Profile.Tests.ps1`, `tests/Pester/Clean.Tests.ps1`, `tests/Pester/ProcessStop.Tests.ps1`: profile and executor regression coverage.
- Modify `tests/GuiPresentation.Tests.ps1`, `tests/Gui.Tests.ps1`: result transport and visible copy coverage.
- Modify `tests/schema-tests.ps1`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `cpu-cleaner.ps1`: schema validation, documentation, and patch version.

### Task 1: Profile contract and complete scan identity

**Files:**
- Modify: `tests/Pester/Profile.Tests.ps1`
- Modify: `tests/schema-tests.ps1`
- Modify: `src/Core/ProfileEngine.ps1`
- Modify: `src/Core/Scanner.ps1`
- Modify: `bloatware-profiles.json`

- [ ] **Step 1: Write failing profile tests**

Add tests that load a minimal tested `manual_impact` profile with:

```powershell
manual_actions = [pscustomobject]@{ service = 'stop_service_process' }
cleanup_policy = [pscustomobject]@{
    execution_class='manual_impact'; necessity='optional'; default_selected=$false
    requires_confirmation=$true
    impact_cn='只结束当前实例；不可恢复；服务可能重新拉起'
    cleanup_reason_cn='不使用联想电脑管家时减少当前常驻后台'
}
```

Assert that exact `HRWSCCtrl` evidence returns `Action='stop_service_process'`, while `contains`, `tested=false`, `default_selected=true`, `requires_confirmation=false`, or `automatic_safe` shapes fail closed or become observations. Assert `actions.service=stop_service_process` is rejected because this action is manual-only.

The accepted JSON contract remains `default_selected=false` and `requires_confirmation=true`; the PowerShell fixture above expresses the same values as `$false` and `$true`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Profile.Tests.ps1 -Output Detailed"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
```

Expected: tests fail because `stop_service_process` is not in the valid action contract and the production profile still declares `disable_service`.

- [ ] **Step 3: Implement the minimal profile contract**

In `ProfileEngine.ps1`, introduce distinct action sets:

```powershell
$script:ValidActions = @('disable_service','stop_service_process','remove_autostart','disable_task','uninstall','investigate','none')
$script:PersistentDangerousActions = @('disable_service','remove_autostart','disable_task','uninstall')
$script:ManualImpactActions = @('disable_service','stop_service_process','remove_autostart','disable_task','uninstall')
```

Use `PersistentDangerousActions` for automatic authorization and `ManualImpactActions` for manual authorization. Add explicit validation that `stop_service_process` appears only in `manual_actions.service`, requires `manual_impact`, and cannot coexist with an automatic dangerous service action.

Update `lenovo-hrwscctrl`:

```json
"manual_actions": { "service": "stop_service_process" },
"cleanup_policy": {
  "execution_class": "manual_impact",
  "necessity": "optional",
  "default_selected": false,
  "requires_confirmation": true,
  "impact_cn": "只结束当前 wsctrl11.exe 实例；不可恢复；联想服务可能自动重新拉起",
  "cleanup_reason_cn": "不使用联想电脑管家时可结束当前安全中心后台进程"
}
```

Keep `actions.service=none`; keep the exact service matcher before the contains fallback.

- [ ] **Step 4: Add scan-time identity enrichment**

Add a focused helper in `Scanner.ps1`:

```powershell
function Get-ServiceProcessExecutionIdentity {
    param([Parameter(Mandatory=$true)]$Service)
    # Require running service, positive ProcessId, rooted service binary path,
    # one matching Win32_Process, exact executable name, hashable path and strict UTC CreationDate.
    # Return $null on any incomplete or inconsistent field.
}
```

Copy the returned values onto the hit as `service_binary_path`, `process_id`, `process_name`, `process_path`, and `process_start_time_utc`. If `action=stop_service_process` and the helper returns `$null`, change the hit to `action='investigate'`, `execution_class='observation'`, and explain the missing identity in `obs_reason`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the same two commands from Step 2. Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```powershell
git add bloatware-profiles.json src/Core/ProfileEngine.ps1 src/Core/Scanner.ps1 tests/Pester/Profile.Tests.ps1 tests/schema-tests.ps1
git commit -m "feat: model HRWSCCtrl one-time process stop"
```

### Task 2: Elevated identity-bound executor without backup mutation

**Files:**
- Modify: `tests/Pester/Clean.Tests.ps1`
- Modify: `tests/Pester/ProcessStop.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1`

- [ ] **Step 1: Write failing executor tests**

Create a pending fixture with `action='stop_service_process'`, exact service provenance, the five recorded identity fields, and confirmed manual-impact digest. Cover these cases:

```powershell
@(
  'service binary path drift', 'PID drift', 'process name drift',
  'process path drift', 'start time drift', 'Stop-Process access denied',
  'old PID remains', 'service rebinds to a new PID', 'verified exit'
)
```

Assert all identity drift cases return `skipped` without calling `Stop-Process`; runtime failures return `failed`; verified exit returns `success`. Assert each terminal result has nonblank `result_reason`, failed results have the correct `failure_stage`, and single-action execution never calls `Initialize-ProtectedBackupDirectory`.

- [ ] **Step 2: Run focused executor tests and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Clean.Tests.ps1,tests/Pester/ProcessStop.Tests.ps1 -Output Detailed"
```

Expected: FAIL because no `stop_service_process` executor exists and clean currently initializes a backup package before every action.

- [ ] **Step 3: Implement identity capture and comparison helpers**

Add to `ActionEngine.ps1`:

```powershell
function Get-CurrentServiceProcessIdentity {
    param([string]$ServiceName)
    # Return service name/path/PID plus process name/path/start UTC from one current snapshot.
}

function Test-ServiceProcessIdentityEqual {
    param($Pending, $Current)
    # OrdinalIgnoreCase for names and paths; exact integer PID; exact normalized UTC instant.
}
```

Return a structured mismatch reason rather than a Boolean-only result so `skipped` explains which identity changed without exposing arbitrary command-line data.

- [ ] **Step 4: Implement the transaction helper**

Add:

```powershell
function Invoke-ServiceProcessStopAction {
    param($Pending)
    # authorization -> mutation -> verification
    # Stop-Process -Id $current.process_id -Force -ErrorAction Stop
    # verify old PID absent; then re-read service PID to detect immediate restart
    # return status/result_reason/failure_stage; never create backup or manifest
}
```

Use these terminal rules:

```powershell
success: old PID absent and service has no positive replacement PID
skipped: recorded/current identity mismatch before mutation
failed/mutation: Stop-Process throws
failed/verification: old PID remains or service binds a new PID
```

- [ ] **Step 5: Route clean actions by persistence class**

Before initializing the backup directory, branch on the action. `stop_service_process` invokes its helper directly. Existing `disable_service`, `remove_autostart`, and `disable_task` retain the current protected backup-first path. Assign all returned result fields to the pending action before writing the subset.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all focused tests pass with zero failures and no backup helper invocation for the one-time action. This proves the one-time action does not create a restore package（不创建恢复包）.

- [ ] **Step 7: Commit Task 2**

```powershell
git add src/Core/ActionEngine.ps1 tests/Pester/Clean.Tests.ps1 tests/Pester/ProcessStop.Tests.ps1
git commit -m "feat: stop exact HRWSCCtrl process identity"
```

### Task 3: Persist and display truthful result diagnostics

**Files:**
- Modify: `tests/GuiPresentation.Tests.ps1`
- Modify: `tests/Gui.Tests.ps1`
- Modify: `src/Gui/Presentation.ps1`
- Modify: `gui-cleaner.ps1`
- Modify: `src/Gui/MainWindow.xaml`

- [ ] **Step 1: Write failing GUI transport tests**

Build execution results containing:

```powershell
[pscustomobject]@{
  status='failed'
  result_reason='当前实例已结束，但服务已自动重新拉起 PID 4321'
  failure_stage='verification'
}
```

Assert `Read-GuiStrictExecutionResult` rejects missing `result_reason`, rejects failed results without a legal `failure_stage`, preserves both fields in `Actions`, and exposes immutable result records to `Merge-PendingStatus`. Assert the merged main pending and `ConvertTo-GuiExecutionRows` contain the same reason and stage. Add a WPF assertion that the completed row displays the concrete reason, not `reason_cn` or the bare word “失败”.

- [ ] **Step 2: Run GUI tests and verify RED**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests/GuiPresentation.Tests.ps1,tests/Gui.Tests.ps1 -Output Detailed"
```

Expected: FAIL because the strict reader and merge currently retain only `status`, and the presentation uses `reason_cn`.

- [ ] **Step 3: Implement strict terminal-result validation**

Add a helper in `gui-cleaner.ps1` that accepts only nonblank scalar `result_reason` and a case-sensitive failure stage from:

```powershell
@('authorization','backup','mutation','verification','result_persistence')
```

Require an empty/absent stage for non-failed terminal states and a nonblank legal stage for failed state. Replace `Tuple<string,string>` merge records with immutable result objects carrying `IdentityKey`, `Status`, `ResultReason`, and `FailureStage`.

- [ ] **Step 4: Merge and render the metadata**

Update `Merge-PendingStatus` to copy the three terminal fields under the existing locked-generation check and rollback behavior. Update `ConvertTo-GuiExecutionRows`:

```powershell
Reason = [string]$item.result_reason
FailureStage = [string]$item.failure_stage
```

Update the completed-row XAML binding so `Reason` is visible and wraps. Preserve the existing summary counts.

- [ ] **Step 5: Run GUI tests and verify GREEN**

Run the Step 2 command. Expected: all GUI tests pass with zero failures.

- [ ] **Step 6: Commit Task 3**

```powershell
git add gui-cleaner.ps1 src/Gui/Presentation.ps1 src/Gui/MainWindow.xaml tests/Gui.Tests.ps1 tests/GuiPresentation.Tests.ps1
git commit -m "fix: show per-item cleanup failure reasons"
```

### Task 4: Documentation, patch release, and full verification

**Files:**
- Modify: `cpu-cleaner.ps1`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `SECURITY.md`

- [ ] **Step 1: Write documentation assertions first**

Extend existing text/schema tests to require version `1.8.1`, the `stop_service_process` safety wording, non-restorable semantics, restart detection, and visible `result_reason` behavior.

- [ ] **Step 2: Run documentation/schema tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
```

Expected: FAIL because source and docs still describe v1.8.0 service disable behavior.

- [ ] **Step 3: Update version and documentation**

Set `$script:Version = '1.8.1'`. Add a changelog entry describing the real failure, the corrected one-time process action, restart detection, and persisted reasons. Update README/SECURITY to distinguish persistent backup-backed actions from non-restorable process termination.

- [ ] **Step 4: Run the complete automated suite**

Run all project-owned verification entrypoints in both supported runtimes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
pwsh -NoProfile -File tests/run-unit.ps1
pwsh -NoProfile -File tests/run-gui-tests.ps1
git diff --check
```

Also run PSScriptAnalyzer with the repository's CI command from `.github/workflows/ci.yml`. Expected: every suite exits 0, zero failed tests, analyzer zero errors, and diff check is clean.

- [ ] **Step 5: Commit Task 4**

```powershell
git add cpu-cleaner.ps1 CHANGELOG.md README.md SECURITY.md tests/schema-tests.ps1
git commit -m "release: prepare v1.8.1 HRWSCCtrl fix"
```

- [ ] **Step 6: Perform controlled real-machine acceptance**

Launch the GUI from the existing desktop shortcut, run a fresh complete scan, select only HRWSCCtrl, confirm the manual-impact dialog, and accept UAC. Record before PID/start mode and after PID/start mode at 0, 5, and 30 seconds. Acceptance requires:

The final observation window is 30 秒 so an immediate Lenovo service restart cannot be mistaken for a durable result.

```text
old PID absent
StartMode remains Manual
no restore package created solely for this action
GUI displays the exact terminal reason
if a new PID appears, result is failed/verification and names the replacement PID
```

Do not claim real acceptance from automated tests or from process exit code alone.

- [ ] **Step 7: Final branch verification**

Run:

```powershell
git status --short --branch
git log -5 --oneline
git diff HEAD~4 --check
```

Expected: no uncommitted source changes and four focused implementation commits after the design/plan commits.
