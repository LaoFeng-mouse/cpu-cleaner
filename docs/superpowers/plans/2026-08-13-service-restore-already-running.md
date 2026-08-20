# Service Restore Already-Running Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a correctly restored, already-running Windows service from being falsely reported as a restore failure when `sc start` returns error 1056.

**Architecture:** Keep the change inside the existing service branch of `Invoke-RestorePlanAction`. Interpret only Windows service-control code `1056` as a nonfatal start result, then rely on the existing strict final-state checks; all other nonzero codes continue to fail immediately.

**Tech Stack:** Windows PowerShell 5.1, Pester 5.9.0, WPF GUI regression suite, PSScriptAnalyzer.

---

## File structure

- Modify `tests/Pester/Restore.Tests.ps1`: add one regression test beside the existing nonzero `sc start` test.
- Modify `src/Core/ActionEngine.ps1`: permit only exit codes `0` and `1056` to reach final service verification.
- Do not change scanner, backup trust, GUI, profiles, or packaging code.

### Task 1: Reproduce and fix service error 1056

**Files:**
- Modify: `tests/Pester/Restore.Tests.ps1:388`
- Modify: `src/Core/ActionEngine.ps1:1555`

- [ ] **Step 1: Add the failing regression test**

Insert this test immediately before the existing test named `服务原状态 Running 时 sc start 非零不得报告 success`:

```powershell
    It '服务已被其他组件启动且 sc start 返回 1056 时继续最终回读' {
        $plan = [pscustomobject]@{Type='service';Name='ExactSvc';StartType='auto';ExpectedStatus='Running';ShouldStart=$true;HasDelayed=$false;DelayedAutoStart=0}
        Mock Invoke-ServiceControlCommand {
            if ($Arguments[0] -eq 'start') { return 1056 }
            return 0
        }
        Mock Get-Service { [pscustomobject]@{StartType='Automatic';Status='Running'} }

        $result = Invoke-RestorePlanAction -Plan $plan

        $result.success | Should -BeTrue
        $result.reason | Should -Match '回读一致'
    }
```

- [ ] **Step 2: Run the targeted test file and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; $r = Invoke-Pester .\tests\Pester\Restore.Tests.ps1 -PassThru; exit [int]($r.FailedCount -gt 0)"
```

Expected: one new failure because the result reason is `sc start 失败 (exit=1056)` and `success` is false. Existing tests remain passing.

- [ ] **Step 3: Apply the minimal production change**

Replace the service-start check in `Invoke-RestorePlanAction` with:

```powershell
            if ($Plan.ExpectedStatus -ceq 'Running') {
                $startExit = Invoke-ServiceControlCommand -Arguments @('start', $Plan.Name)
                if ($startExit -notin @(0, 1056)) {
                    return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="sc start 失败 (exit=$startExit)"}
                }
            }
```

This preserves the existing final reads of start type, delayed-auto-start, and runtime status. Do not special-case any other exit code.

- [ ] **Step 4: Run the targeted test file and verify GREEN**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; $r = Invoke-Pester .\tests\Pester\Restore.Tests.ps1 -PassThru; exit [int]($r.FailedCount -gt 0)"
```

Expected: all restore tests pass, including the new 1056 regression and the existing exit-code-5 failure test.

- [ ] **Step 5: Run the complete automated acceptance suite**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; $r = Invoke-Pester .\tests\Pester -PassThru; exit [int]($r.FailedCount -gt 0)"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-unit.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module PSScriptAnalyzer; $all = @(); foreach ($f in @('cpu-cleaner.ps1','gui-cleaner.ps1') + @(Get-ChildItem .\src\Core -Filter *.ps1 | ForEach-Object { $_.FullName })) { $all += @(Invoke-ScriptAnalyzer -Path $f -Severity Error) }; if ($all.Count -gt 0) { $all | Format-Table; exit 1 }"
git diff --check
```

Expected: Pester reports 336 passed and 0 failed; GUI reports 169 passed and 0 failed; legacy logic reports 38 passed; schema reports 12 passed; PSScriptAnalyzer reports no Error-severity findings; `git diff --check` emits no output.

- [ ] **Step 6: Review the scoped diff**

Run:

```powershell
git diff -- tests/Pester/Restore.Tests.ps1 src/Core/ActionEngine.ps1
git status --short
```

Expected: only the new regression test and the `@(0, 1056)` condition are tracked implementation changes. Existing `artifacts/` and `gui-live-idle.png` remain untracked test artifacts and are not staged.

- [ ] **Step 7: Commit the verified fix**

Run:

```powershell
git add -- tests/Pester/Restore.Tests.ps1 src/Core/ActionEngine.ps1
git commit -m "fix: accept already-running service restore"
```

Expected: one commit containing exactly the regression test and production fix.

### Task 2: Re-run the real restore boundary

**Files:**
- No source changes.

- [ ] **Step 1: Confirm the machine is back at its original service state**

Run:

```powershell
Get-Service -Name GAService | Select-Object Name,Status,StartType
```

Expected: `GAService`, `Running`, `Automatic`.

- [ ] **Step 2: Run an idempotent elevated restore against the latest trusted package**

Run the following and approve the Windows UAC prompt:

```powershell
$scriptPath = (Resolve-Path -LiteralPath '.\cpu-cleaner.ps1').Path
$process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-Mode','restore','-BackupDir','latest') -WorkingDirectory (Get-Location) -Wait -PassThru
$process.ExitCode
```

Expected: exit code `0`. The trusted package is validated before mutation, and service state remains `Running/Automatic`.

- [ ] **Step 3: Reconfirm final state and document the independent environment gate**

Run:

```powershell
Get-Service -Name GAService | Select-Object Name,Status,StartType
Get-Service -Name Schedule | Select-Object Name,Status,StartType
```

Expected: both services are running with automatic startup. Record separately that normal-user Task Scheduler enumeration currently fails through PowerShell cmdlet, `schtasks`, and COM; do not describe the scanner as fully accepted until that Windows condition is repaired and a normal-user scan succeeds.
