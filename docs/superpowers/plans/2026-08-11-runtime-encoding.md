# GUI Runtime Encoding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve UTF-8 Chinese scanner output across the Windows PowerShell `Start-Job` boundary so the WPF GUI displays real scan phases without mojibake.

**Architecture:** Keep the scanner and GUI transcript pipeline unchanged. Configure the background job host to decode the native scanner process as UTF-8 before launching `powershell.exe`, then transport the resulting .NET strings through `Receive-Job` as today.

**Tech Stack:** Windows PowerShell 5.1, WPF, `Start-Job`, Pester 5.9.0.

---

### Task 1: Reproduce the native-output encoding failure

**Files:**
- Modify: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Add a real job-boundary regression test**

Create a temporary UTF-8 PowerShell script that sets its native output encoding to UTF-8 and writes `读取系统信息`. Launch it through the production `$script:ScanJobScript`, wait for completion, and assert that `Receive-Job` returns the exact Chinese text and not `璇诲彇绯荤粺淇℃伅`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$c=New-PesterConfiguration; `$c.Run.Path='.\tests\Gui.Tests.ps1'; `$c.Filter.FullName='*preserves UTF-8 Chinese scanner output*'; `$c.Output.Verbosity='Detailed'; `$r=Invoke-Pester -Configuration `$c; if(`$r.FailedCount -gt 0){exit 1}"
```

Expected: FAIL because the default background job encoding is GB2312 and the native UTF-8 bytes are decoded as mojibake.

### Task 2: Configure the actual background job boundary

**Files:**
- Modify: `gui-cleaner.ps1`
- Test: `tests/Gui.Tests.ps1`

- [ ] **Step 1: Apply the minimal production fix**

At the start of `$script:ScanJobScript`, set `[Console]::OutputEncoding` and `$OutputEncoding` to a BOM-less `System.Text.UTF8Encoding`. Do this before invoking the native child `powershell.exe`; preserve exit-code handling and all existing scan logic.

- [ ] **Step 2: Run the focused test and verify GREEN**

Run the same filtered Pester command. Expected: PASS with the exact `读取系统信息` string.

- [ ] **Step 3: Run the complete GUI gate**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
```

Expected: all GUI tests pass with zero failures.

### Task 3: Verify the complete software path without destructive cleanup

**Files:**
- No additional production files expected.

- [ ] **Step 1: Run all core and legacy tests**

Run the 235-test Pester suite, `tests\run-unit.ps1`, PowerShell AST parsing, JSON parsing, and `git diff --check`. Expected: zero failures.

- [ ] **Step 2: Run a real read-only scanner process**

Run `cpu-cleaner.ps1 -Mode scan` without elevation, capture its exit code and output, verify Chinese phase text is intact, and inspect `scan_health`/warnings instead of treating exit code alone as success. Do not run clean or restore.

- [ ] **Step 3: Launch the WPF application for user acceptance**

Start `gui-cleaner.ps1` visibly from the isolated worktree. The user confirms the UI and scan transcript; no cleanup action is performed unless separately authorized in the application.

- [ ] **Step 4: Review branch scope before any integration**

Inspect `git status`, `git diff`, test evidence, and the GitHub `master` baseline. Do not merge, commit, or push until the complete verification evidence supports it and the user requests that integration step.
