# Final Security Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the pending-file race, preserve the complete v2 envelope, carry autostart values end to end, and delete Run values literally.

**Architecture:** `ActionEngine.ps1` owns locked pending streams, envelope construction, and literal RegistryKey deletion. `ProfileEngine.ps1` captures original autostart values. Pester tests exercise real file/JSON/data-flow behavior while mocking all production system state and mutation.

**Tech Stack:** Windows PowerShell 5.1, .NET FileStream/RegistryKey APIs, Pester 5.9.0.

---

### Task 1: Record RED for locked pending files and v2 persistence

**Files:**
- Modify: `tests/Pester/Auth.Tests.ps1`
- Modify: `tests/Pester/Pending.Tests.ps1`

- [ ] Add tests that call `Open-LockedPendingFile` and verify concurrent write/delete/replace denial, same-handle writeback after path replacement, rejection of a reparse-point input when available, and disposal after a thrown callback.
- [ ] Add Invoke-Clean AST/controlled-process tests proving one locked stream owns validation through writeback, rejected actions become `skipped`, and v2/generated/actions/observations/suspicious plus extra envelope fields survive.
- [ ] Run the two files with Pester and record the exact failing count and missing/incorrect behavior.

### Task 2: Implement locked stream and complete v2 writes

**Files:**
- Modify: `src/Core/ActionEngine.ps1`
- Modify: `gui-cleaner.ps1`

- [ ] Implement `Open-LockedPendingFile`, strict stream reading, `Write-PendingToLockedStream`, and the compatibility wrapper.
- [ ] Implement `Build-PendingV2Payload` and use it for every status-changing clean path.
- [ ] Wrap all of `Invoke-Clean` after open in `try/finally`; replace cancellation `exit` statements inside the lock with `return` so `finally` always disposes.
- [ ] Preserve observations and safety-envelope fields in GUI subset payloads and status merge behavior.
- [ ] Run the focused Pester files until GREEN.

### Task 3: Record RED and implement autostart-value provenance

**Files:**
- Modify: `tests/Pester/Schema3.Tests.ps1`
- Modify: `src/Core/ProfileEngine.ps1`

- [ ] Add an integration test that mocks profile loading and current Run-key reads, then executes `Match-Profiles`, `Save-PendingActions`, and `Test-PendingActionAuthorized` for exact/path value matches.
- [ ] Run the test and record failure because `autostart_value` is absent.
- [ ] Add the `autostartValue` parameter/property to `New-Hit` and pass `$a.Value` from `Match-Profiles`.
- [ ] Re-run the focused test until GREEN.

### Task 4: Record RED and implement literal RegistryKey deletion

**Files:**
- Modify: `tests/Pester/AutostartValue.Tests.ps1`
- Modify: `tests/Pester/Auth.Tests.ps1`
- Modify: `src/Core/ActionEngine.ps1`

- [ ] Create only a random HKCU test subkey, populate literal `*`, `?`, `[x]`, and control values, and verify each helper call deletes only the named value; teardown deletes the exact random test subkey.
- [ ] Add an AST/mock assertion that production `remove_autostart` calls the helper and does not call `Remove-ItemProperty`.
- [ ] Run the tests and record failure because the helper is missing and production still uses `Remove-ItemProperty`.
- [ ] Implement whitelist parsing and `RegistryKey.OpenSubKey(..., true).DeleteValue(name, false)` with deterministic disposal.
- [ ] Re-run focused tests until GREEN.

### Task 5: Verify and commit

**Files:**
- Modify only files listed above plus these design/plan documents.

- [ ] Run all Pester tests and capture passed/failed/skipped totals.
- [ ] Run `tests/run-unit.ps1` and the GUI runner under `powershell -STA`.
- [ ] Parse all PowerShell files with the PowerShell AST parser and all JSON files with `ConvertFrom-Json`.
- [ ] Run `git diff --check`, inspect `git diff`, and confirm no real system mutation occurred.
- [ ] Commit in two or three reviewable commits and report hashes and exact RED/GREEN counts.
