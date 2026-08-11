# GUI Runtime Encoding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve UTF-8 Chinese scanner output across the Windows PowerShell `Start-Job` boundary so the WPF GUI displays real scan phases without mojibake.

**Architecture:** Keep the scanner and GUI transcript pipeline unchanged. Configure the background job host to decode the native scanner process as UTF-8 before launching `powershell.exe`, then transport the resulting .NET strings through `Receive-Job` as today.

**Tech Stack:** Windows PowerShell 5.1, WPF, `Start-Job`, Pester 5.9.0.

---

### Task 1: Reproduce the native-output encoding failure

**Files:**
- Modify: `tests/Gui.Tests.ps1`

- [x] **Step 1: Add a real job-boundary regression test**

Created a temporary UTF-8 PowerShell script that sets its native output encoding to UTF-8 and writes `==> 读取系统信息...`. The regression launches it through the production `$script:ScanJobScript`, waits for completion, and asserts that `Receive-Job` returns the exact Chinese text rather than mojibake.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 5.9.0; `$c=New-PesterConfiguration; `$c.Run.Path='.\tests\Gui.Tests.ps1'; `$c.Filter.FullName='*preserves UTF-8 Chinese scanner output*'; `$c.Output.Verbosity='Detailed'; `$r=Invoke-Pester -Configuration `$c; if(`$r.FailedCount -gt 0){exit 1}"
```

Actual RED evidence before the production fix: the background job decoded the native UTF-8 bytes as `==> 璇诲彇绯荤粺淇℃伅...` instead of `==> 读取系统信息...`.

### Task 2: Configure the actual background job boundary

**Files:**
- Modify: `gui-cleaner.ps1`
- Test: `tests/Gui.Tests.ps1`

- [x] **Step 1: Apply the minimal production fix**

At the start of `$script:ScanJobScript`, set `[Console]::OutputEncoding` and `$OutputEncoding` to a BOM-less `System.Text.UTF8Encoding`. Do this before invoking the native child `powershell.exe`; preserve exit-code handling and all existing scan logic.

- [x] **Step 2: Run the focused test and verify GREEN**

Actual GREEN evidence: the same filtered Pester command passed 1/1 and returned the exact output `==> 读取系统信息...`.

- [x] **Step 3: Run the complete GUI gate**

Run:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
```

Actual result: 150/150 GUI tests passed with zero failures.

### Task 3: Verify the complete software path without destructive cleanup

**Files:**
- No additional production files expected.

- [x] **Step 1: Run all core and legacy tests**

Actual results: core Pester 235/235, legacy 38/38, schema 12/12, PowerShell AST parsing passed, JSON parsing passed, and `git diff --check` passed.

- [ ] **Step 2: Run a real read-only scanner process**

Run `cpu-cleaner.ps1 -Mode scan` without elevation, capture its exit code and output, verify Chinese phase text is intact, and inspect `scan_health`/warnings instead of treating exit code alone as success. Do not run clean or restore.

- [ ] **Step 3: Launch the WPF application for user acceptance**

Start `gui-cleaner.ps1` visibly from the isolated worktree. The user confirms the UI and scan transcript; no cleanup action is performed unless separately authorized in the application.

- [x] **Step 4: Review branch scope before any integration**

The user selected execution after reviewing `git status`, `git diff`, and the recorded test evidence. The runtime-encoding slice was committed as `f4165b0`; it was not pushed.
