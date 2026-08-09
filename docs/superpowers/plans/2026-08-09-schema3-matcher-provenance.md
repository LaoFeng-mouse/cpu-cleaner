# Schema 3.0 Matcher Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the mixed-matcher authorization vulnerability by carrying the exact matcher evidence from scan through elevated clean and allowing dangerous actions only for the same revalidated `exact` or `path` match.

**Architecture:** Keep profile files on Schema 3.0, but move execution eligibility from profile-level matcher inspection to per-hit evidence. `ProfileEngine.ps1` will produce structured matcher provenance and an effective per-hit action; `ActionEngine.ps1` will serialize pending format v2 and fail closed unless the elevated process can find the identical matcher in the current profile and reproduce it against the same current system field.

**Tech Stack:** Windows PowerShell 5.1+, Pester 5.9.0, JSON profile and pending files, existing dot-sourced `src/Core/*.ps1` architecture.

---

## File map

- Modify `src/Core/ProfileEngine.ps1`: literal matcher semantics, structured matcher evidence, per-hit dangerous-action gate, and `Match-Profiles` evidence capture.
- Modify `src/Core/ActionEngine.ps1`: pending v2 serialization, evidence preservation, pending envelope validation, and elevated same-matcher reauthorization.
- Modify `tests/Pester/Schema3.Tests.ps1`: safe test bootstrap plus matcher, mixed-rule, provenance, and authorization regression coverage.
- Modify `tests/Pester/Pending.Tests.ps1`: pending v2 and observation/action evidence coverage; update executable fixtures to include narrow evidence.
- Modify `README.md`, `CHANGELOG.md`, and `SECURITY.md`: document the hard boundary, old-pending incompatibility, and `allow_auto` deprecation for broad execution.

No production file split is needed. The two affected core files already own the correct responsibilities.

### Task 1: Make `contains` and `path` literal

**Files:**
- Modify: `tests/Pester/Schema3.Tests.ps1:8-35`
- Modify: `src/Core/ProfileEngine.ps1:65-88`

- [ ] **Step 1: Make the Schema3 test bootstrap side-effect free**

Replace the current `BeforeAll` block, which dot-sources the executable script, with the same definition-only loader used by `tests/run-unit.ps1`:

```powershell
BeforeAll {
    $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
    $idx = $src.IndexOf("switch (`$Mode)")
    if ($idx -lt 0) { throw '主流程 switch 未找到' }
    $defs = $src.Substring(0, $idx)
    $defs = $defs -replace "(?s)# ---------- v1\.7\.0 模块化.*?\n\}", ''
    $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
    Invoke-Expression $defs
    foreach ($f in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
        . (Join-Path $projectRoot ('src\Core\' + $f + '.ps1'))
    }
}
```

Run the existing Schema3 suite once and require zero failures before adding the regression tests. This check confirms the test harness change did not alter behavior and prevents a test import from launching a real scan.

- [ ] **Step 2: Add failing literal-semantics tests**

Replace the current broad `contains` and `path` examples with explicit case-insensitive and wildcard-literal assertions:

```powershell
It 'contains 是大小写不敏感的字面量子串' {
    Test-DetectMatch 'LenovoServiceAS' @{ match = 'lenovo'; type = 'contains' } | Should -BeTrue
    Test-DetectMatch 'abc*def' @{ match = '*'; type = 'contains' } | Should -BeTrue
    Test-DetectMatch 'abcdef' @{ match = '*'; type = 'contains' } | Should -BeFalse
    Test-DetectMatch 'abc?def' @{ match = '?'; type = 'contains' } | Should -BeTrue
    Test-DetectMatch 'abcXdef' @{ match = '?'; type = 'contains' } | Should -BeFalse
    Test-DetectMatch 'abc[def]' @{ match = '[def]'; type = 'contains' } | Should -BeTrue
    Test-DetectMatch 'abcdef' @{ match = '[def]'; type = 'contains' } | Should -BeFalse
}

It 'path 是大小写不敏感的字面量前缀' {
    Test-DetectMatch 'c:\PROGRAM FILES\Lenovo\app.exe' @{ match = 'C:\Program Files\Lenovo'; type = 'path' } | Should -BeTrue
    Test-DetectMatch 'C:\Apps\[*]\app.exe' @{ match = 'C:\Apps\[*]'; type = 'path' } | Should -BeTrue
    Test-DetectMatch 'C:\Apps\x\app.exe' @{ match = 'C:\Apps\[*]'; type = 'path' } | Should -BeFalse
}
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```powershell
$r = Invoke-Pester -Path tests\Pester\Schema3.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -eq 0) { throw 'Expected wildcard-literal regression tests to fail before implementation' }
```

Expected: the `*`, `?`, or bracket negative cases fail because `-like` treats the matcher as a wildcard expression.

- [ ] **Step 4: Implement literal comparisons**

Change only the relevant `Test-DetectMatch` branches:

```powershell
'exact' {
    return [string]::Equals(
        [string]$target,
        [string]$n.match,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}
'contains' {
    return ([string]$target).IndexOf(
        [string]$n.match,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}
'path' {
    return ([string]$target).StartsWith(
        [string]$n.match,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}
```

Keep `regex` unchanged. Replace the runtime `default` branch with `return $false`; Schema 3.0 validation already rejects unknown types, so runtime must fail closed.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```powershell
$r = Invoke-Pester -Path tests\Pester\Schema3.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -gt 0) { exit 1 }
```

Expected: all matcher dispatch tests pass. Update the old “unknown type falls back to contains” test to expect false before accepting GREEN.

- [ ] **Step 6: Commit**

```powershell
git add src/Core/ProfileEngine.ps1 tests/Pester/Schema3.Tests.ps1
git commit -m "fix: make schema matchers literal"
```

### Task 2: Produce matcher provenance and gate each hit

**Files:**
- Modify: `tests/Pester/Schema3.Tests.ps1:37-123`
- Modify: `src/Core/ProfileEngine.ps1:90-330`

- [ ] **Step 1: Add failing mixed-matcher and evidence tests**

Add a helper inside the Schema3 test file that writes a temporary profile, temporarily points `$script:ProfileFile` at it, and restores the old path in `finally`:

```powershell
function Invoke-WithSchema3Profile([string]$Json, [scriptblock]$Body) {
    $tmp = Join-Path $TestDrive 'profiles.json'
    [System.IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding($false)))
    $old = $script:ProfileFile
    try {
        $script:ProfileFile = $tmp
        & $Body
    } finally {
        $script:ProfileFile = $old
    }
}
```

Add these tests:

```powershell
It '混合规则仅由 contains 命中时识别但禁止危险动作' {
    $json = '{"schema_version":3,"profiles":[{"id":"mixed","vendor":"T","name_cn":"混合","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[{"match":"LenovoExactService","type":"exact"},{"match":"Lenovo","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}'
    Invoke-WithSchema3Profile $json {
        $svc = [pscustomobject]@{ Name='LenovoOtherService'; DisplayName='Other'; State='Running'; StartMode='Automatic' }
        $hit = @(Match-Profiles @($svc) @() @() @())[0]
        $hit.action | Should -Be 'investigate'
        $hit.matched_pattern | Should -Be 'Lenovo'
        $hit.matched_type | Should -Be 'contains'
        $hit.matched_field | Should -Be 'service_name'
    }
}

It '混合规则由 exact 命中时保留危险动作及证据' {
    $json = '{"schema_version":3,"profiles":[{"id":"mixed","vendor":"T","name_cn":"混合","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"detect":{"services":[{"match":"LenovoExactService","type":"exact"},{"match":"Lenovo","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}'
    Invoke-WithSchema3Profile $json {
        $svc = [pscustomobject]@{ Name='LenovoExactService'; DisplayName='Exact'; State='Running'; StartMode='Automatic' }
        $hit = @(Match-Profiles @($svc) @() @() @())[0]
        $hit.action | Should -Be 'disable_service'
        $hit.matched_pattern | Should -Be 'LenovoExactService'
        $hit.matched_type | Should -Be 'exact'
        $hit.matched_field | Should -Be 'service_name'
    }
}

It 'allow_auto 不能让宽命中执行危险动作' {
    $json = '{"schema_version":3,"profiles":[{"id":"wide","vendor":"T","name_cn":"宽","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[{"match":"Lenovo","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}'
    Invoke-WithSchema3Profile $json {
        $svc = [pscustomobject]@{ Name='LenovoOtherService'; DisplayName='Other'; State='Running'; StartMode='Automatic' }
        @(Match-Profiles @($svc) @() @() @())[0].action | Should -Be 'investigate'
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run the focused Pester command from Task 1.

Expected: failures report missing `matched_pattern`, `matched_type`, and `matched_field`, and the mixed/broad hits retain `disable_service` under current behavior.

- [ ] **Step 3: Add structured match selection**

Add this focused helper after `Test-DetectMatch`:

```powershell
function Find-DetectMatch($Patterns, $Candidates, [switch]$NormalizeProcess) {
    foreach ($pattern in @($Patterns)) {
        $n = Normalize-DetectItem $pattern
        foreach ($candidate in @($Candidates)) {
            $value = [string]$candidate.value
            $matched = $false
            if ($NormalizeProcess -and $candidate.field -eq 'process_name' -and $n.type -in @('exact','contains')) {
                $targetName = Normalize-ProcessName $value
                $patternName = [pscustomobject]@{ match = (Normalize-ProcessName $n.match); type = $n.type }
                $matched = Test-DetectMatch $targetName $patternName
            } else {
                $matched = Test-DetectMatch $value $n -Context $candidate.context
            }
            if ($matched) {
                return [pscustomobject]@{
                    matched_pattern = $n.match
                    matched_type    = $n.type
                    matched_field   = [string]$candidate.field
                }
            }
        }
    }
    return $null
}

function Get-EffectiveHitAction($profile, $hitType, $matchEvidence) {
    $declared = Get-ActionFor $profile.actions $hitType
    if ($script:DangerousActions -notcontains $declared) { return $declared }
    if (-not $profile.safe) { return 'investigate' }
    if (-not ($profile.evidence -and $profile.evidence.tested)) { return 'investigate' }
    if (-not $matchEvidence -or $matchEvidence.matched_type -notin @('exact','path')) { return 'investigate' }
    return $declared
}
```

Delete the profile-category execution mutation loop in `Load-Profiles`. Keep `execution.allow_auto` type validation and migration fields for compatibility, but do not consult it for authorization.

Rewrite the old load-time gate assertions accordingly: loading a valid profile preserves its declared action, while the `Match-Profiles` assertions above prove that each actual hit receives either the declared action or `investigate`. In particular, replace the old expectation that a pure `contains` profile is mutated during `Load-Profiles` with an expectation that its scanned hit is downgraded, and replace the old `allow_auto=true` preservation test with the per-hit denial test above.

- [ ] **Step 4: Thread evidence through hits**

Extend `New-Hit` with a final `$matchEvidence` parameter and properties:

```powershell
matched_pattern = if ($matchEvidence) { $matchEvidence.matched_pattern } else { '' }
matched_type    = if ($matchEvidence) { $matchEvidence.matched_type } else { '' }
matched_field   = if ($matchEvidence) { $matchEvidence.matched_field } else { '' }
```

Also add `process_id` and `process_path` parameters/properties to `New-Hit`. Pass `$tp.PID` and `$tp.Path` from the process branch; pass `0` and `''` from non-process branches. This gives elevated reauthorization a stable way to retrieve the current process before accepting a `process_name` or `process_path` matcher.

For each scanned object, build ordered candidates and call `Find-DetectMatch`. Service candidates must be:

```powershell
@(
    [pscustomobject]@{ field='service_name'; value=$s.Name; context=$null }
    [pscustomobject]@{ field='service_display_name'; value=$s.DisplayName; context=$null }
)
```

Use corresponding candidate pairs for autostart name/value, task name/path, and process name/path. Call `Get-EffectiveHitAction` with the returned evidence and pass the same evidence to `New-Hit`. Preserve detect-array order and candidate-field order.

- [ ] **Step 5: Run focused and full Schema3 tests**

Run:

```powershell
$r = Invoke-Pester -Path tests\Pester\Schema3.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -gt 0) { exit 1 }
```

Expected: mixed broad hit is observation-grade, exact hit retains its action, and provenance fields match the actual rule and field.

- [ ] **Step 6: Commit**

```powershell
git add src/Core/ProfileEngine.ps1 tests/Pester/Schema3.Tests.ps1
git commit -m "fix: bind actions to matched rule evidence"
```

### Task 3: Serialize pending format v2

**Files:**
- Modify: `tests/Pester/Pending.Tests.ps1:1-100`
- Modify: `src/Core/ActionEngine.ps1:3-95`

- [ ] **Step 1: Add failing pending evidence tests**

For every existing executable hit fixture, add:

```powershell
matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
```

Use the corresponding exact target and field for autostart/task fixtures. Add tests:

```powershell
It 'pending v2 保存窄匹配证据' {
    $hit = [pscustomobject]@{
        id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'
        detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''
        task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }
        matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
    }
    Save-PendingActions @($hit) @()
    $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $p.pending_schema_version | Should -Be 2
    $p.actions[0].matched_pattern | Should -Be 'S1'
    $p.actions[0].matched_type | Should -Be 'exact'
    $p.actions[0].matched_field | Should -Be 'service_name'
}

It '宽匹配即使携带危险 action 也只能进入 observations' {
    $hit = [pscustomobject]@{
        id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'
        detail='LenovoOther'; reason_cn='r'; service_name='LenovoOther'; autostart_source=''; autostart_name=''
        task_path=''; process_name=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }
        matched_pattern='Lenovo'; matched_type='contains'; matched_field='service_name'
    }
    Save-PendingActions @($hit) @()
    $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
    @($p.actions).Count | Should -Be 0
    @($p.observations).Count | Should -Be 1
    $p.observations[0].matched_type | Should -Be 'contains'
}
```

- [ ] **Step 2: Run Pending tests and verify RED**

Run:

```powershell
$r = Invoke-Pester -Path tests\Pester\Pending.Tests.ps1 -Output Detailed -PassThru
if ($r.FailedCount -eq 0) { throw 'Expected pending v2 tests to fail before implementation' }
```

Expected: `pending_schema_version` and matcher evidence are absent; a forged broad dangerous hit enters actions.

- [ ] **Step 3: Enforce narrow evidence during serialization**

Change executable eligibility to:

```powershell
$hasNarrowEvidence = $h.matched_pattern -and
    ($h.matched_type -in @('exact','path')) -and
    $h.matched_field
$executable = ($h.action -in $script:DangerousActions) -and
    $h.safe -and
    ($h.evidence -and $h.evidence.tested) -and
    $hasNarrowEvidence
```

Copy `matched_pattern`, `matched_type`, and `matched_field` into both action and observation objects. When a dangerous action lacks narrow evidence, set `obs_reason` to `实际命中不是 exact/path，禁止自动处理`.

Copy `process_id` and `process_path` into both objects as well. Existing non-process fixtures use `process_id=0` and `process_path=''`; process fixtures use the values captured by `Match-Profiles`.

Add `pending_schema_version = 2` as the first payload property.

- [ ] **Step 4: Run Pending tests and verify GREEN**

Run the focused Pending command from Step 2 and require `FailedCount = 0`.

- [ ] **Step 5: Commit**

```powershell
git add src/Core/ActionEngine.ps1 tests/Pester/Pending.Tests.ps1
git commit -m "fix: persist matcher evidence in pending v2"
```

### Task 4: Reauthorize the identical matcher and field

**Files:**
- Modify: `tests/Pester/Schema3.Tests.ps1:106-end`
- Modify: `src/Core/ActionEngine.ps1:97-126`

- [ ] **Step 1: Add failing authorization tests**

Create a mixed profile in memory and a valid narrow pending object:

```powershell
$profiles = [pscustomobject]@{ profiles = @([pscustomobject]@{
    id='mixed'; safe=$true; evidence=[pscustomobject]@{ tested=$true }
    actions=[pscustomobject]@{ service='disable_service' }
    detect=[pscustomobject]@{ services=@(
        [pscustomobject]@{ match='LenovoExactService'; type='exact' },
        [pscustomobject]@{ match='Lenovo'; type='contains' }
    ); autostarts=@(); tasks=@(); processes=@() }
}) }
$pending = [pscustomobject]@{
    id='mixed'; hit_type='service'; action='disable_service'; service_name='LenovoExactService'
    autostart_source=''; autostart_name=''; task_path=''; process_name=''
    matched_pattern='LenovoExactService'; matched_type='exact'; matched_field='service_name'
}
```

Mock `Get-Service` to return the current service. Assert:

```powershell
Test-PendingActionAuthorized $pending $profiles | Should -BeTrue

$pending.matched_pattern = 'Lenovo'
$pending.matched_type = 'contains'
Test-PendingActionAuthorized $pending $profiles | Should -BeFalse

$pending.matched_pattern = 'LenovoExactService'
$pending.matched_type = 'exact'
$pending.matched_field = 'service_display_name'
Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
```

Add separate cases for missing evidence, a pattern not present in the current profile, a changed target, and an `allow_auto=true` broad pending item. Each must return false.

- [ ] **Step 2: Run Schema3 tests and verify RED**

Expected: current authorization accepts any matcher and does not require evidence identity or field identity.

- [ ] **Step 3: Add current-field resolution**

Implement a helper that returns the current candidate value or `$null`. The service branch must be complete and mockable:

```powershell
function Get-CurrentPendingMatchValue($pending) {
    switch ($pending.hit_type) {
        'service' {
            $svc = Get-Service -Name $pending.service_name -ErrorAction SilentlyContinue
            if (-not $svc) { return $null }
            if ($pending.matched_field -eq 'service_name') { return [string]$svc.Name }
            if ($pending.matched_field -eq 'service_display_name') { return [string]$svc.DisplayName }
            return $null
        }
        'autostart' {
            if (-not $pending.autostart_source -or -not $pending.autostart_name) { return $null }
            if ($pending.matched_field -eq 'autostart_name') { return [string]$pending.autostart_name }
            if ($pending.matched_field -ne 'autostart_value') { return $null }
            $key = Get-ItemProperty -Path $pending.autostart_source -ErrorAction SilentlyContinue
            $prop = @($key.PSObject.Properties | Where-Object Name -eq $pending.autostart_name) | Select-Object -First 1
            if ($prop) { return [string]$prop.Value }
            return $null
        }
        'task' {
            if (-not $pending.task_path) { return $null }
            $taskName = $pending.task_path.Split('\')[-1]
            $taskFolder = if ($pending.task_path.Length -gt $taskName.Length) {
                $pending.task_path.Substring(0, $pending.task_path.Length - $taskName.Length)
            } else { '\' }
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
            if (-not $task) { return $null }
            if ($pending.matched_field -eq 'task_name') { return [string]$task.TaskName }
            if ($pending.matched_field -eq 'task_path') { return [string]$task.TaskPath + [string]$task.TaskName }
            return $null
        }
        'process' {
            if (-not $pending.process_id) { return $null }
            $proc = Get-Process -Id $pending.process_id -ErrorAction SilentlyContinue
            if (-not $proc) { return $null }
            if ($pending.matched_field -eq 'process_name') { return Normalize-ProcessName $proc.Name }
            if ($pending.matched_field -eq 'process_path') {
                try { return [string]$proc.Path } catch { return $null }
            }
            return $null
        }
        default { return $null }
    }
}
```

Add Pester mocks for `Get-Process` covering both `process_name` and `process_path`. A missing PID, exited process, changed name, or changed path must fail authorization. Process actions currently end as `manual_required`, but they still use the same fail-closed identity rules so later automation cannot inherit a weaker boundary.

- [ ] **Step 4: Replace authorization rule-level matching**

After existing ID, tested, safe, and action checks, require all of the following:

```powershell
if (-not $p.matched_pattern -or -not $p.matched_type -or -not $p.matched_field) { return $false }
if ($p.matched_type -notin @('exact','path')) { return $false }

$items = switch ($p.hit_type) {
    'service'   { @($rule.detect.services) }
    'autostart' { @($rule.detect.autostarts) }
    'task'      { @($rule.detect.tasks) }
    'process'   { @($rule.detect.processes) }
    default     { @() }
}
$sameMatcher = @($items | Where-Object {
    $n = Normalize-DetectItem $_
    $n.type -eq $p.matched_type -and $n.match -ceq $p.matched_pattern
}).Count -gt 0
if (-not $sameMatcher) { return $false }

$currentValue = Get-CurrentPendingMatchValue $p
if ($null -eq $currentValue) { return $false }
return Test-DetectMatch $currentValue ([pscustomobject]@{
    match = $p.matched_pattern
    type  = $p.matched_type
})
```

The pattern identity comparison is case-sensitive (`-ceq`) because pending must carry the same serialized rule, while the actual target comparison remains case-insensitive according to matcher semantics.

- [ ] **Step 5: Run authorization tests and verify GREEN**

Run the focused Schema3 suite. Expected: valid identical evidence passes; every broad, missing, changed, or field-swapped case returns false.

- [ ] **Step 6: Commit**

```powershell
git add src/Core/ActionEngine.ps1 tests/Pester/Schema3.Tests.ps1
git commit -m "fix: revalidate identical matcher before clean"
```

### Task 5: Reject legacy pending files before clean

**Files:**
- Modify: `tests/Pester/Pending.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1:170-191`

- [ ] **Step 1: Add failing pending-envelope tests**

Add a pure helper test:

```powershell
It '仅 pending_schema_version=2 可进入 clean' {
    Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version=2 }) | Should -BeTrue
    Test-PendingSchemaSupported ([pscustomobject]@{}) | Should -BeFalse
    Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version=1 }) | Should -BeFalse
    Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version='2' }) | Should -BeFalse
}
```

- [ ] **Step 2: Run Pending tests and verify RED**

Expected: `Test-PendingSchemaSupported` is not defined.

- [ ] **Step 3: Implement the envelope gate**

Add:

```powershell
function Test-PendingSchemaSupported($pending) {
    if (-not $pending) { return $false }
    if ($pending.PSObject.Properties.Name -notcontains 'pending_schema_version') { return $false }
    return ($pending.pending_schema_version -is [int]) -and ($pending.pending_schema_version -eq 2)
}
```

Immediately after parsing pending JSON in `Invoke-Clean`, before selecting actions or loading profiles, add:

```powershell
if (-not (Test-PendingSchemaSupported $pending)) {
    Write-Host '待办清单版本过旧或缺少匹配证据。为保证安全，请重新扫描后再处理。' -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 4: Run Pending tests and verify GREEN**

Run the focused Pending suite and require zero failures.

- [ ] **Step 5: Commit**

```powershell
git add src/Core/ActionEngine.ps1 tests/Pester/Pending.Tests.ps1
git commit -m "fix: reject legacy pending files"
```

### Task 6: Update security documentation and run full verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `SECURITY.md`

- [ ] **Step 1: Document the boundary**

Add release notes that state all of the following exactly in substance:

- mixed matcher rules are authorized per actual hit, never per profile category;
- `allow_auto` cannot bypass `exact/path` for dangerous actions;
- `contains` and `path` are literal and case-insensitive;
- pending v1 files are rejected and users must rescan;
- broad hits remain visible but are observation-only.

Do not claim that automated service/task/autostart mutations were exercised during testing.

- [ ] **Step 2: Run focused security suites**

Run:

```powershell
$config = New-PesterConfiguration
$config.Run.Path = @('tests\Pester\Schema3.Tests.ps1','tests\Pester\Pending.Tests.ps1')
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$r = Invoke-Pester -Configuration $config
if ($r.FailedCount -gt 0) { exit 1 }
```

Expected: zero failed tests and explicit passes for mixed matcher, literal wildcard, provenance serialization, tampering, and legacy pending rejection.

- [ ] **Step 3: Run the complete Pester suite**

Run:

```powershell
$r = Invoke-Pester -Path tests\Pester -Output Detailed -PassThru
if ($r.FailedCount -gt 0) { exit 1 }
```

Expected: zero failed tests. No real clean action is invoked.

- [ ] **Step 4: Run legacy unit and GUI suites**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-unit.ps1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-gui-tests.ps1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: both runners exit 0.

- [ ] **Step 5: Perform static closeout checks**

Run:

```powershell
git diff --check
rg -n "matched_pattern|matched_type|matched_field|pending_schema_version" src tests README.md CHANGELOG.md SECURITY.md
rg -n -- "-like \"\*\$|allow_auto.*continue|Get-DetectTypesFor" src/Core
git status --short
```

Expected: `git diff --check` exits 0; provenance is present across scan, pending, and authorization; the old wildcard matching and rule-level `allow_auto` bypass are absent. Only intended files are modified.

- [ ] **Step 6: Commit documentation**

```powershell
git add README.md CHANGELOG.md SECURITY.md
git commit -m "docs: document matcher provenance hardening"
```

- [ ] **Step 7: Record final evidence**

Capture the exact Pester passed/failed counts, legacy runner exit codes, final commit list, and `git status --short`. Do not claim runtime mutation acceptance; verification is automated and non-mutating.
