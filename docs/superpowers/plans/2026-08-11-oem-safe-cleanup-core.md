# OEM Safe Cleanup Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make verified Lenovo service rules produce genuinely executable, provenance-bound cleanup actions while broad and incomplete detections remain observation-only, with truthful GUI controls and tested backup/restore behavior.

**Architecture:** Keep Schema 3.0 and pending v2 unchanged. Strengthen `ProfileEngine` so it selects the strongest matcher that actually matched the same current object, calibrate only verified stable Lenovo service names to `exact`, and keep authorization replay in `ActionEngine` as the final gate. Add a field-sufficient service fallback, fail-closed backup checks, and a GUI selection-state controller; do not add any broad-match override.

**Tech Stack:** Windows PowerShell 5.1, WPF/XAML, Pester 5.9.0, JSON Schema 3.0 profiles, Windows service/registry/task APIs.

---

## File map

- Modify `src/Core/ProfileEngine.ps1`: matcher evidence ranking and per-object selection.
- Modify `bloatware-profiles.json`: narrow only verified stable Lenovo service internal names.
- Modify `src/Core/Scanner.ps1`: distinguish a complete identity/state fallback from genuinely incomplete service collection.
- Modify `src/Core/ActionEngine.ps1`: gate actions on relevant scan health and reject failed backups before mutation.
- Modify `src/Core/BackupManager.ps1`: validate service registry backup output.
- Modify `gui-cleaner.ps1`: derive execute-button state from validated selectable rows and live checkbox state.
- Modify `src/Gui/MainWindow.xaml`: route checkbox changes through one GUI handler and start with execution disabled.
- Modify `tests/Pester/Schema3.Tests.ps1`: mixed matcher and production-profile integration coverage.
- Modify `tests/Pester/Scanner.Tests.ps1`: service fallback health coverage.
- Modify `tests/Pester/Pending.Tests.ps1`: degraded-category action suppression.
- Modify `tests/Pester/Clean.Tests.ps1`: backup failure and no-mutation coverage.
- Modify `tests/Pester/Restore.Tests.ps1`: manifest restoration invariants.
- Modify `tests/Gui.Tests.ps1`: execute-button selection-state coverage.

### Task 0: Close the already-tested runtime encoding slice

**Files:**
- Modify: `gui-cleaner.ps1:938-946`
- Modify: `tests/Gui.Tests.ps1:364-405`
- Create: `docs/superpowers/plans/2026-08-11-runtime-encoding.md`

- [ ] **Step 1: Verify the targeted regression remains green**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$c=New-PesterConfiguration; `$c.Run.Path='tests/Gui.Tests.ps1'; `$c.Filter.FullName='*preserves UTF-8 Chinese scanner output*'; `$c.Output.Verbosity='Detailed'; `$r=Invoke-Pester -Configuration `$c; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: one matching test passes and returns the exact text `==> 读取系统信息...`.

- [ ] **Step 2: Verify the complete GUI suite**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
```

Expected: `FailedCount = 0`.

- [ ] **Step 3: Commit only the encoding slice**

```powershell
git add -- gui-cleaner.ps1 tests/Gui.Tests.ps1 docs/superpowers/plans/2026-08-11-runtime-encoding.md
git diff --cached --check
git commit -m "fix: preserve UTF-8 scanner output in GUI job"
```

Expected: the three named files are committed; the OEM design and plan commits remain separate.

### Task 1: Select the strongest matcher that actually matched one object

**Files:**
- Modify: `src/Core/ProfileEngine.ps1:99-138`
- Modify: `tests/Pester/Schema3.Tests.ps1:274-342`

- [ ] **Step 1: Write failing mixed-order tests**

Add tests that use `Find-DetectMatch` directly:

```powershell
It 'prefers an actually matched exact rule even when contains is declared first' {
    $patterns = @(
        [pscustomobject]@{ match='Lenovo'; type='contains' },
        [pscustomobject]@{ match='LenovoExactService'; type='exact' }
    )
    $evidence = Find-DetectMatch $patterns @(
        [pscustomobject]@{ field='service_name'; value='LenovoExactService'; context=$null }
    )
    $evidence.matched_pattern | Should -BeExactly 'LenovoExactService'
    $evidence.matched_type | Should -BeExactly 'exact'
    $evidence.matched_field | Should -BeExactly 'service_name'
}

It 'does not borrow an exact matcher that did not match the current object' {
    $patterns = @(
        [pscustomobject]@{ match='Lenovo'; type='contains' },
        [pscustomobject]@{ match='LenovoExactService'; type='exact' }
    )
    $evidence = Find-DetectMatch $patterns @(
        [pscustomobject]@{ field='service_name'; value='LenovoOtherService'; context=$null }
    )
    $evidence.matched_pattern | Should -BeExactly 'Lenovo'
    $evidence.matched_type | Should -BeExactly 'contains'
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/Schema3.Tests.ps1 -PassThru; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

Expected: the first new test fails because current code returns the first declared `contains` match.

- [ ] **Step 3: Implement deterministic actual-match ranking**

Replace early return in `Find-DetectMatch` with collection and ranking. Use this ranking helper:

```powershell
function Get-DetectMatchStrength([string]$Type) {
    switch ($Type) {
        'exact' { return 0 }
        'path' { return 1 }
        'contains' { return 2 }
        'regex' { return 3 }
        default { return 4 }
    }
}
```

For every successful pattern/candidate pair append:

```powershell
[pscustomobject]@{
    matched_pattern = $n.match
    matched_type = $n.type
    matched_field = $field
    strength = Get-DetectMatchStrength $n.type
    declaration_index = $patternIndex
    candidate_index = $candidateIndex
}
```

Sort by `strength`, `declaration_index`, then `candidate_index`, return one new object containing only `matched_pattern`, `matched_type`, and `matched_field`. Do not rank or return matchers for which `Test-DetectMatch` returned false.

- [ ] **Step 4: Run Schema 3 tests and verify GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/Schema3.Tests.ps1 -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: all Schema 3 tests pass, including broad-only observation behavior.

- [ ] **Step 5: Commit**

```powershell
git add -- src/Core/ProfileEngine.ps1 tests/Pester/Schema3.Tests.ps1
git commit -m "fix: prefer strongest actual matcher evidence"
```

### Task 2: Activate only verified stable Lenovo service identities

**Files:**
- Modify: `bloatware-profiles.json:6-349`
- Modify: `tests/Pester/Schema3.Tests.ps1`

- [ ] **Step 1: Write failing production-profile integration tests**

Load the real profile file and assert the stable service names below are exact:

```powershell
It 'uses exact internal service names for verified Lenovo cleanup rules' {
    $db = Load-Profiles -Path (Join-Path $projectRoot 'bloatware-profiles.json')
    $expected = @{
        'lenovo-lemcpmanager'='LeMCPManagerService'
        'lenovo-xlsmart'='XLSmartService'
        'lenovo-lisf'='LISFService'
        'lenovo-serviceas'='LenovoServiceAS'
        'lenovo-gaserivce'='GAService'
        'lenovo-smartconnect'='SmartConnect'
        'lenovo-lnvvcam'='LnvVCamInstaller'
    }
    foreach ($id in $expected.Keys) {
        $profile = @($db.profiles | Where-Object id -eq $id)[0]
        $matcher = @($profile.detect.services | Where-Object match -ceq $expected[$id])[0]
        $matcher.type | Should -BeExactly 'exact'
        $profile.evidence.tested | Should -BeTrue
    }
}

It 'makes a real exact Lenovo service actionable but a suffixed lookalike observation-only' {
    $original = $script:ProfileFile
    try {
        $script:ProfileFile = Join-Path $projectRoot 'bloatware-profiles.json'
        $hits = @(Match-Profiles -Services @(
            [pscustomobject]@{Name='LeMCPManagerService';DisplayName='Real';State='Running';StartMode='Automatic'},
            [pscustomobject]@{Name='LeMCPManagerServiceFake';DisplayName='Fake';State='Running';StartMode='Automatic'}
        ) -AutoStarts @() -Tasks @() -TopProcs @())
        @($hits | Where-Object service_name -eq 'LeMCPManagerService')[0].action | Should -BeExactly 'disable_service'
        @($hits | Where-Object service_name -eq 'LeMCPManagerServiceFake')[0].action | Should -BeExactly 'investigate'
    } finally { $script:ProfileFile = $original }
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run the Schema 3 command from Task 1.

Expected: stable-service matcher assertions fail because the production rules are currently `contains`.

- [ ] **Step 3: Calibrate profile data minimally**

Change only the seven listed internal service-name matcher objects from `"type": "contains"` to `"type": "exact"`. Keep process matchers, autostart matchers, MagicCenter entries, task notification entries, untested vendors, and generic profiles unchanged. Keep `LeMcpManager` as `contains` unless independent evidence proves it is an exact internal service name.

- [ ] **Step 4: Validate JSON and tests**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$null=Get-Content bloatware-profiles.json -Raw -Encoding UTF8 | ConvertFrom-Json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/Schema3.Tests.ps1 -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: JSON parses and all Schema 3 tests pass.

- [ ] **Step 5: Commit**

```powershell
git add -- bloatware-profiles.json tests/Pester/Schema3.Tests.ps1
git commit -m "feat: activate verified Lenovo service rules"
```

### Task 3: Preserve truthful service health without blocking a complete fallback

**Files:**
- Modify: `src/Core/Scanner.ps1:2-23,200-264`
- Modify: `src/Core/ActionEngine.ps1:773-898`
- Modify: `tests/Pester/Scanner.Tests.ps1`
- Modify: `tests/Pester/Pending.Tests.ps1`

- [ ] **Step 1: Write failing service-fallback tests**

Add Pester mocks proving two cases:

```powershell
It 'keeps services actionable when Get-Service fallback supplies complete identity and state' {
    Mock Get-CimInstance { throw 'denied' } -ParameterFilter { $ClassName -eq 'Win32_Service' }
    Mock Get-Service { @([pscustomobject]@{Name='ExactSvc';DisplayName='Exact';Status='Running';StartType='Automatic'}) }
    $result = @(Get-ServicesInfo)
    $result[0].Name | Should -BeExactly 'ExactSvc'
    $script:ScanHealth.services | Should -BeExactly 'complete'
    @($script:ScanWarnings | Where-Object { $_ -match 'CIM' }).Count | Should -BeGreaterThan 0
}

It 'fails closed when fallback service identity is incomplete' {
    Mock Get-CimInstance { throw 'denied' } -ParameterFilter { $ClassName -eq 'Win32_Service' }
    Mock Get-Service { @([pscustomobject]@{Name='';DisplayName='Broken';Status='Running';StartType='Automatic'}) }
    { Get-ServicesInfo } | Should -Throw '*不完整*'
}
```

Add a pending test:

```powershell
It 'downgrades service actions when service collection is degraded' {
    Save-PendingActions -Hits @($exactServiceHit) -Suspicious @() -ScanHealth ([pscustomobject]@{system_info='complete';services='degraded';tasks='complete'}) -ScanWarnings @('service incomplete')
    $pending = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    @($pending.actions).Count | Should -Be 0
    @($pending.observations).Count | Should -Be 1
    $pending.observations[0].obs_reason | Should -Match '扫描信息不完整'
}
```

- [ ] **Step 2: Run Scanner and Pending tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester @('tests/Pester/Scanner.Tests.ps1','tests/Pester/Pending.Tests.ps1') -PassThru; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

Expected: complete fallback and degraded action suppression tests fail.

- [ ] **Step 3: Implement field-sufficient fallback health**

In `Get-ServicesInfo`, do not call `Set-ScanHealthDegraded services` merely because CIM failed. Add the warning, build fallback records, validate `Name`, `DisplayName`, `State`, and `StartMode`, and leave health `complete` when all are present. Set health to `degraded` immediately before throwing only when both CIM and fallback cannot provide those required fields. Continue leaving `PathName=''` and `ProcessId=0`; do not infer trigger hints from missing path metadata.

- [ ] **Step 4: Gate executable hits by relevant scan category**

In `Save-PendingActions`, map hit types to health keys:

```powershell
$healthKey = switch ($h.hit_type) {
    'service' { 'services' }
    'task' { 'tasks' }
    default { '' }
}
$categoryComplete = [string]::IsNullOrEmpty($healthKey) -or
    ($ScanHealth -and [string]$ScanHealth.$healthKey -ceq 'complete')
$executable = $actionAllowed -and $safeAllowed -and $testedAllowed -and $hasNarrowEvidence -and $categoryComplete
```

Place the incomplete-category observation reason before generic matcher reasons:

```powershell
elseif (-not $categoryComplete) { '扫描信息不完整，禁止自动处理' }
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the command from Step 2 without the `expected RED` inversion.

Expected: both files pass with zero failures.

- [ ] **Step 6: Commit**

```powershell
git add -- src/Core/Scanner.ps1 src/Core/ActionEngine.ps1 tests/Pester/Scanner.Tests.ps1 tests/Pester/Pending.Tests.ps1
git commit -m "fix: gate cleanup on truthful collector health"
```

### Task 4: Make service and task backup failure stop mutation

**Files:**
- Modify: `src/Core/BackupManager.ps1:2-11`
- Modify: `src/Core/ActionEngine.ps1:1113-1196`
- Modify: `tests/Pester/Clean.Tests.ps1`
- Modify: `tests/Pester/Restore.Tests.ps1`

- [ ] **Step 1: Write failing backup-failure tests**

Extract two focused helpers, then test their contracts with mocks:

```powershell
It 'does not configure or stop a service when backup creation fails' {
    Mock Get-ServiceBackupInfo { [pscustomobject]@{start_type_sc='auto';start_type_display='Automatic';status='Running';delayed_autostart=0} }
    Mock Backup-RegistryKey { throw 'backup failed' }
    Mock Invoke-ServiceConfigDisable {}
    $result = Invoke-ServiceDisableAction -Pending ([pscustomobject]@{service_name='ExactSvc'}) -BackupDir $TestDrive -Tag 'svc'
    $result.status | Should -BeExactly 'failed'
    Should -Invoke Invoke-ServiceConfigDisable -Times 0 -Exactly
}

It 'does not disable a task when XML backup cannot be verified' {
    Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
    Mock Export-ScheduledTask { '' }
    Mock Disable-ScheduledTask {}
    $result = Invoke-TaskDisableAction -Pending ([pscustomobject]@{task_path='\Vendor\Task'}) -BackupDir $TestDrive -Tag 'task'
    $result.status | Should -BeExactly 'failed'
    Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
}
```

- [ ] **Step 2: Run Clean tests and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester/Clean.Tests.ps1 -PassThru; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

Expected: helper functions are missing.

- [ ] **Step 3: Implement validated backup helpers**

Change `Backup-RegistryKey` to call `reg.exe export`, capture `$LASTEXITCODE`, then require a non-empty file. Throw on any failure.

Create `Invoke-ServiceConfigDisable` as the small wrapper around `sc.exe config` and `sc.exe stop`, preserving readback in `Invoke-ServiceDisableAction`. Create `Write-TaskXmlBackup` that rejects blank XML and verifies a non-empty UTF-8 file before `Disable-ScheduledTask`. Return objects containing `status`, `reason`, and manifest data so `Invoke-Clean` only appends verified backup metadata.

- [ ] **Step 4: Add restore invariant test**

Add:

```powershell
It 'restores a service manifest to its original start type and running state' {
    $manifest = [pscustomobject]@{type='service';name='ExactSvc';start_type_sc='auto';status='Running';delayed_autostart=0}
    $plan = Get-ServiceRestorePlan $manifest
    $plan.StartType | Should -BeExactly 'auto'
    $plan.ShouldStart | Should -BeTrue
}
```

Extract `Get-ServiceRestorePlan` from the current restore switch without changing behavior; keep old manifest compatibility tests green.

- [ ] **Step 5: Run Clean and Restore tests and verify GREEN**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester @('tests/Pester/Clean.Tests.ps1','tests/Pester/Restore.Tests.ps1') -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: zero failures and zero real system mutations because every external command is mocked.

- [ ] **Step 6: Commit**

```powershell
git add -- src/Core/BackupManager.ps1 src/Core/ActionEngine.ps1 tests/Pester/Clean.Tests.ps1 tests/Pester/Restore.Tests.ps1
git commit -m "fix: require verified backups before cleanup"
```

### Task 5: Keep the GUI execute button synchronized with validated selection

**Files:**
- Modify: `gui-cleaner.ps1:463-507,688-692,995-1053`
- Modify: `src/Gui/MainWindow.xaml:77-80`
- Modify: `tests/Gui.Tests.ps1:820-930,1225-1237`

- [ ] **Step 1: Write failing GUI state tests**

Add:

```powershell
It 'disables execute when review has no selected executable rows' {
    $list = $script:Win.FindName('PendingList')
    $list.ItemsSource = @([pscustomobject]@{CanExecute=$false;IsChecked=$false})
    Update-GuiExecuteAvailability -List $list
    $script:Win.FindName('BtnExecute').IsEnabled | Should -BeFalse
}

It 'tracks select and clear changes for executable rows' {
    $list = $script:Win.FindName('PendingList')
    $row = [pscustomobject]@{CanExecute=$true;IsChecked=$false}
    $list.ItemsSource = @($row)
    Update-GuiExecuteAvailability -List $list
    $script:Win.FindName('BtnExecute').IsEnabled | Should -BeFalse
    $row.IsChecked = $true
    Update-GuiExecuteAvailability -List $list
    $script:Win.FindName('BtnExecute').IsEnabled | Should -BeTrue
    Set-AllChecked $list $false
    Update-GuiExecuteAvailability -List $list
    $script:Win.FindName('BtnExecute').IsEnabled | Should -BeFalse
}
```

- [ ] **Step 2: Run focused GUI tests and verify RED**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$c=New-PesterConfiguration; `$c.Run.Path='tests/Gui.Tests.ps1'; `$c.Filter.FullName='*execute*selected*','*tracks select*'; `$r=Invoke-Pester -Configuration `$c; if(`$r.FailedCount -eq 0){throw 'expected RED'}"
```

Expected: `Update-GuiExecuteAvailability` is missing or button remains enabled.

- [ ] **Step 3: Implement one availability controller**

Add:

```powershell
function Update-GuiExecuteAvailability {
    param($List = $window.FindName('PendingList'))
    $eligible = @($List.Items | Where-Object { $_.CanExecute -eq $true -and $_.IsChecked -eq $true })
    $window.FindName('BtnExecute').IsEnabled = ($eligible.Count -gt 0 -and -not $script:ExecutionInProgress)
}
```

Call it after review items load, after select all, after clear all, when entering/exiting execution, and after checkbox click. In XAML add `Click="OnPendingSelectionChanged"` to the bound checkbox; register that named handler in `gui-cleaner.ps1` to call the controller. Set `BtnExecute IsEnabled="False"` in XAML so empty review never flashes enabled.

- [ ] **Step 4: Run the full GUI suite**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
```

Expected: zero failures; observations remain disabled and cannot enter `Resolve-GuiReviewedActions`.

- [ ] **Step 5: Commit**

```powershell
git add -- gui-cleaner.ps1 src/Gui/MainWindow.xaml tests/Gui.Tests.ps1
git commit -m "fix: disable cleanup when nothing is selected"
```

### Task 6: Full automated and real read-only acceptance

**Files:**
- Modify only if evidence exposes a defect; otherwise no source changes.

- [ ] **Step 1: Run all automated suites**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$r=Invoke-Pester tests/Pester -PassThru; if(`$r.FailedCount -gt 0){exit 1}"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests/run-gui-tests.ps1
```

Expected: all legacy, Schema, core Pester, and GUI tests pass.

- [ ] **Step 2: Validate source and data**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$errors=@(); Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { `$tokens=`$null; `$parseErrors=`$null; [void][System.Management.Automation.Language.Parser]::ParseFile(`$_.FullName,[ref]`$tokens,[ref]`$parseErrors); `$errors += `$parseErrors }; if(`$errors.Count){`$errors | Format-List; exit 1}"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$null=Get-Content bloatware-profiles.json -Raw -Encoding UTF8 | ConvertFrom-Json"
git diff --check
```

Expected: zero AST errors, JSON parses, and no whitespace errors.

- [ ] **Step 3: Run a real read-only scan**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\cpu-cleaner.ps1 -Mode scan
```

Expected: Chinese phase text is correct; `pending_actions.json` has schema 2; real exact Lenovo services, if present and service health is complete, appear under `actions`; lookalikes and broad rules remain under `observations`. No system state is changed.

- [ ] **Step 4: Run real GUI review acceptance**

Start the GUI normally, click “开始安全扫描”, wait for Results, click “查看处理建议”, and verify:

- the window stays responsive;
- exact verified Lenovo rows are selectable when present;
- broad rows are disabled;
- clearing every selection disables “处理已选择项目”;
- reselecting one valid action enables it;
- do not click the final cleanup button on a real OEM service during this acceptance.

- [ ] **Step 5: Review branch evidence before merge or push**

```powershell
git status --short
git log --oneline --decorate -8
git diff b31d631..HEAD --stat
```

Expected: changes are classified into small commits, no unexplained files exist, and merge/push remains a separate decision after the suspicious-process plan and final review.
