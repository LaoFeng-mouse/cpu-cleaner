# Selectable OEM Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make precisely identified Lenovo notification tasks and HRWSCCtrl selectable and safely cleanable, while displaying necessity, reason, impact, already-treated state, and recovery guarantees.

**Architecture:** Keep automatic-safe authorization separate from explicit high-impact authorization. Profile schema v3 gains validated optional `manual_actions` and `cleanup_policy`; pending files move to schema 3 with `actions`, `resolved`, and `observations`. Elevated clean revalidates the exact matcher and rule class, and high-impact actions additionally require a digest bound to the reviewed subset.

**Tech Stack:** Windows PowerShell 5.1/PowerShell 7, WPF XAML, Pester 5.9.0, JSON profile rules, existing backup/restore engine.

---

## File map

- Modify `bloatware-profiles.json`: exact Lenovo identities, manual HRWSCCtrl action, cleanup copy.
- Modify `src/Core/ProfileEngine.ps1`: validate cleanup metadata and produce execution-class evidence.
- Modify `src/Core/ActionEngine.ps1`: pending schema 3, resolved-state rows, manual authorization and confirmation digest.
- Modify `cpu-cleaner.ps1`: accept and constrain the confirmation-digest argument.
- Modify `gui-cleaner.ps1`: view models, counters, default selection, confirmation and digest propagation.
- Modify `src/Gui/MainWindow.xaml`: larger review cards, labels, impact copy and summary counter.
- Modify `src/Gui/Presentation.ps1`: stable user-facing labels.
- Modify `tests/Pester/Profile.Tests.ps1`, `Pending.Tests.ps1`, `Auth.Tests.ps1`, `Clean.Tests.ps1`, `Restore.Tests.ps1`: core regressions.
- Modify `tests/Gui.Tests.ps1`, `tests/GuiPresentation.Tests.ps1`: GUI behavior and tamper resistance.
- Modify `README.md`, `零基础操作指南.md`: explain automatic versus optional cleanup.

### Task 1: Lock profile policy and exact Lenovo identities

**Files:**
- Modify: `tests/Pester/Profile.Tests.ps1`
- Modify: `tests/Pester/Schema3.Tests.ps1`
- Modify: `src/Core/ProfileEngine.ps1`
- Modify: `bloatware-profiles.json`

- [ ] **Step 1: Write failing profile-policy tests**

Add tests that load a v3 profile with this exact shape and assert normalization succeeds:

```powershell
manual_actions = [pscustomobject]@{ service = 'disable_service' }
cleanup_policy = [pscustomobject]@{
    execution_class = 'manual_impact'
    necessity = 'optional'
    default_selected = $false
    requires_confirmation = $true
    impact_cn = '可能影响联想电脑管家的安全状态、主动防护和通知'
    cleanup_reason_cn = '不使用联想电脑管家时可减少常驻后台'
}
```

Also test rejection of blank copy, non-Boolean selection/confirmation fields, a dangerous `manual_actions` entry without `manual_impact`, and `manual_impact` with `requires_confirmation=false`.

- [ ] **Step 2: Run RED tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Profile.Tests.ps1','.\tests\Pester\Schema3.Tests.ps1' -EnableExit"
```

Expected: FAIL because `manual_actions` and `cleanup_policy` are not validated or exposed.

- [ ] **Step 3: Add strict policy helpers**

Add `Get-ManualActionFor`, `Get-CleanupPolicy`, and exact validation in `Load-Profiles`. Allowed classes are exactly `automatic_safe` and `manual_impact`; `manual_impact` requires tested evidence, a dangerous manual action, `default_selected=false`, `requires_confirmation=true`, and nonblank Chinese reason/impact.

```powershell
function Get-ManualActionFor($profile, [string]$hitType) {
    if ($null -eq $profile -or $profile.PSObject.Properties.Name -notcontains 'manual_actions') { return 'none' }
    return Get-ActionFor $profile.manual_actions $hitType
}
```

- [ ] **Step 4: Update exact Lenovo rules**

For `lenovo-task-notify`, add exact task-name matchers before the existing contains fallbacks and attach `automatic_safe` cleanup copy. For `lenovo-hrwscctrl`, add `{ "match": "HRWSCCtrl", "type": "exact" }`, keep broad discovery rules, preserve `safe:false`, add `manual_actions.service=disable_service`, and attach the confirmed `manual_impact` copy.

- [ ] **Step 5: Run GREEN profile tests and commit**

Expected: all selected profile/schema tests PASS.

```powershell
git add bloatware-profiles.json src/Core/ProfileEngine.ps1 tests/Pester/Profile.Tests.ps1 tests/Pester/Schema3.Tests.ps1
git commit -m "feat: model explicit OEM cleanup policy"
```

### Task 2: Produce execution classes and preserve actual matcher provenance

**Files:**
- Modify: `tests/Pester/Profile.Tests.ps1`
- Modify: `src/Core/ProfileEngine.ps1`

- [ ] **Step 1: Write failing hit-classification tests**

Cover these exact outcomes:

```text
safe=true + tested + exact declared action => automatic_safe
safe=false + tested + exact manual action => manual_impact
same manual rule reached through contains => observation
missing impact metadata => profile load rejection
exact and contains both match => exact evidence wins
```

- [ ] **Step 2: Run RED test and confirm the missing properties**

Expected failure: hit objects do not expose `execution_class`, `necessity`, `default_selected`, `requires_confirmation`, `impact_cn`, or `cleanup_reason_cn`.

- [ ] **Step 3: Implement `Get-HitExecutionDecision`**

Return an immutable-shaped object containing `Action`, `ExecutionClass`, and display metadata. Automatic actions still require `safe=true`, `tested=true`, and `exact/path`. Manual actions require `tested=true`, validated manual policy, and `exact/path`; otherwise return observation with action `investigate`.

- [ ] **Step 4: Copy decision fields in `New-Hit` and run GREEN tests**

Run the targeted profile tests in Windows PowerShell 5.1 and PowerShell 7.

- [ ] **Step 5: Commit**

```powershell
git add src/Core/ProfileEngine.ps1 tests/Pester/Profile.Tests.ps1
git commit -m "feat: classify exact OEM hits for user cleanup"
```

### Task 3: Introduce pending schema 3 and resolved-state rows

**Files:**
- Modify: `tests/Pester/Pending.Tests.ps1`
- Modify: `tests/Pester/Inventory.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1`

- [ ] **Step 1: Write failing pending tests**

Assert schema 3 payload shape:

```powershell
$pending.pending_schema_version | Should -Be 3
@($pending.actions).Count | Should -Be 1
@($pending.resolved).Count | Should -Be 1
@($pending.observations).Count | Should -Be 1
$pending.actions[0].execution_class | Should -BeExactly 'manual_impact'
$pending.resolved[0].current_state | Should -BeExactly 'disabled'
```

Test enabled exact task -> action; disabled exact task -> resolved; exact HRWSCCtrl -> manual action; broad matches -> observation; incomplete inventory -> observation; malformed policy fields -> fail closed.

- [ ] **Step 2: Run RED pending tests**

Expected: FAIL because schema is 2 and resolved rows do not exist.

- [ ] **Step 3: Implement schema 3 payload builders**

Update `Test-PendingSchemaSupported`, strict duplicate-key readers, `Build-PendingV2Payload` (rename to `Build-PendingPayload`), subset builders, and atomic writers. Every schema 3 file must contain arrays `actions`, `resolved`, `observations`, and `suspicious`; schema 2 must be rejected with the existing rescan message.

- [ ] **Step 4: Classify already-target-state hits into `resolved`**

Move the current `$skip` checks before action emission. Emit a copy with `current_state='disabled'`, `status='success'`, and the same exact provenance/display fields. Never emit resolved rows when inventory health for that category is incomplete.

- [ ] **Step 5: Run GREEN pending/inventory tests and commit**

```powershell
git add src/Core/ActionEngine.ps1 tests/Pester/Pending.Tests.ps1 tests/Pester/Inventory.Tests.ps1
git commit -m "feat: persist actionable and already-treated OEM states"
```

### Task 4: Bind high-impact confirmation to the exact subset

**Files:**
- Modify: `tests/Pester/Auth.Tests.ps1`
- Modify: `tests/Pester/Clean.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1`
- Modify: `cpu-cleaner.ps1`

- [ ] **Step 1: Write failing authorization tests**

Test that automatic-safe exact actions authorize without an impact digest; manual-impact exact actions reject a missing, malformed, stale, or different-identity-set digest; the same manual identities in a different input order produce the same canonical digest; manual-impact contains matches reject regardless of digest; profile action/class changes after scan reject.

- [ ] **Step 2: Run RED auth tests**

Expected: manual-impact actions are rejected because no separate authorization path exists.

- [ ] **Step 3: Add canonical manual-impact digest**

Create `Get-ManualImpactDigest` over sorted `Get-PendingIdentityKey` values for only `execution_class='manual_impact'`, encoded as UTF-8 and SHA-256. Add `-ConfirmedImpactSha256Arg` to `cpu-cleaner.ps1`; reject it outside clean mode and reject non-64-hex values.

- [ ] **Step 4: Extend final authorization without weakening automatic rules**

`Test-PendingActionAuthorized` must branch by exact `execution_class`: automatic uses existing `safe/tested/actions`; manual uses `tested/manual_actions/cleanup_policy`, requires matching confirmation digest, and then performs the same current-target exact matcher verification.

- [ ] **Step 5: Run GREEN auth/clean tests and commit**

```powershell
git add cpu-cleaner.ps1 src/Core/ActionEngine.ps1 tests/Pester/Auth.Tests.ps1 tests/Pester/Clean.Tests.ps1
git commit -m "feat: bind optional cleanup confirmation to reviewed actions"
```

### Task 5: Build truthful GUI groups, defaults and counters

**Files:**
- Modify: `tests/Gui.Tests.ps1`
- Modify: `tests/GuiPresentation.Tests.ps1`
- Modify: `gui-cleaner.ps1`
- Modify: `src/Gui/Presentation.ps1`
- Modify: `src/Gui/MainWindow.xaml`

- [ ] **Step 1: Write failing GUI model tests**

Assert automatic rows are checked/selectable, manual rows are unchecked/selectable and marked `NeedsConfirmation`, resolved rows are unchecked/nonselectable with green “已处理”, and observations are unchecked/nonselectable. Assert “选择全部安全项” never checks manual-impact rows.

- [ ] **Step 2: Run RED GUI tests**

Expected: FAIL because the view only knows actions versus observations.

- [ ] **Step 3: Extend presentation models**

Add stable properties `GroupKey`, `NecessityLabel`, `ImpactText`, `CleanupReasonText`, `CurrentStateLabel`, `NeedsConfirmation`, `CanExecute`, and `IsChecked`. Add `Get-GuiReviewCounts` returning automatic/manual/resolved/observation counts.

- [ ] **Step 4: Update XAML cards and review capacity**

Increase `PendingList.MaxHeight`, show colored group/necessity/state labels, reason and impact on separate wrapped lines, and add `ReviewCountsText`. Preserve keyboard navigation and accessibility names.

- [ ] **Step 5: Run GREEN GUI model/XAML tests and commit**

```powershell
git add gui-cleaner.ps1 src/Gui/Presentation.ps1 src/Gui/MainWindow.xaml tests/Gui.Tests.ps1 tests/GuiPresentation.Tests.ps1
git commit -m "feat: explain selectable OEM cleanup decisions"
```

### Task 6: Require GUI confirmation before elevation

**Files:**
- Modify: `tests/Gui.Tests.ps1`
- Modify: `gui-cleaner.ps1`

- [ ] **Step 1: Write failing confirmation tests**

Mock the confirmation wrapper, not `MessageBox` directly. Verify No/close returns without temp file or `Start-Process`; Yes computes a digest from the resolved reviewed actions and passes `-ConfirmedImpactSha256Arg`; automatic-only selection does not show the high-impact dialog.

- [ ] **Step 2: Run RED GUI tests**

Expected: FAIL because `Start-GuiExecution` elevates immediately.

- [ ] **Step 3: Implement `Confirm-GuiImpactActions`**

Build a Chinese message listing each target, necessity, cleanup reason, impact and recovery statement. Return false unless the exact response is Yes. Do not mutate the reviewed snapshot.

- [ ] **Step 4: Bind confirmation digest and launch**

After resolving selected rows, confirm manual items, build the subset, compute its manual-impact digest, and append the argument only when manual actions exist. Preserve pending SHA-256 binding and lifecycle fail-closed behavior.

- [ ] **Step 5: Run GREEN GUI tests and commit**

```powershell
git add gui-cleaner.ps1 tests/Gui.Tests.ps1
git commit -m "feat: confirm high-impact cleanup before UAC"
```

### Task 7: Verify service/task execution and restore regressions

**Files:**
- Modify: `tests/Pester/Clean.Tests.ps1`
- Modify: `tests/Pester/Restore.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1`
- Modify: `src/Core/BackupManager.ps1`

- [ ] **Step 1: Add failing end-state and restore tests**

Cover service original start type/running state, task enabled state, backup failure before mutation, command success with unchanged state, one failed item among successful items, and restore to exact original state.

- [ ] **Step 2: Run RED tests**

Expected: any missing postcondition or metadata assertion fails for the intended reason.

- [ ] **Step 3: Make the smallest backup/verification changes**

Reuse existing `Invoke-ServiceDisableAction` and `Invoke-TaskDisableAction`; add only missing binary-path digest/manifest fields and explicit post-state assertions. Do not change unrelated restore formats.

- [ ] **Step 4: Run GREEN clean/restore tests in PS5.1 and PS7**

- [ ] **Step 5: Commit**

```powershell
git add src/Core/ActionEngine.ps1 src/Core/BackupManager.ps1 tests/Pester/Clean.Tests.ps1 tests/Pester/Restore.Tests.ps1
git commit -m "test: close OEM cleanup and restore state loop"
```

### Task 8: Documentation and full non-mutating verification

**Files:**
- Modify: `README.md`
- Modify: `零基础操作指南.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update user documentation**

Document the three groups, default-selection rules, exact-match boundary, HRWSCCtrl impact, UAC confirmation, backup and restore. State that already-disabled entries are complete rather than pending.

- [ ] **Step 2: Run full Windows PowerShell 5.1 suite**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester' -EnableExit"
```

Expected: 0 failed.

- [ ] **Step 3: Run PowerShell 7 and GUI suites**

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path '.\tests\Pester' -EnableExit"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\unit-logic.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\schema-tests.ps1
```

Expected: all pass.

- [ ] **Step 4: Run static checks**

```powershell
Invoke-ScriptAnalyzer -Path .\cpu-cleaner.ps1,.\gui-cleaner.ps1,.\src -Recurse -Severity Error
git diff --check
```

Expected: zero analyzer errors and clean diff check.

- [ ] **Step 5: Commit docs and verification state**

```powershell
git add README.md 零基础操作指南.md CHANGELOG.md
git commit -m "docs: explain selectable OEM cleanup impact"
```

- [ ] **Step 6: Real UAC acceptance checkpoint**

Launch the GUI, rescan, and inspect group counts. Do not perform system mutation silently. Ask the user to approve UAC and the selected high-impact action, then observe the service/task state and recovery round trip. Record this gate separately from automated-test completion.
