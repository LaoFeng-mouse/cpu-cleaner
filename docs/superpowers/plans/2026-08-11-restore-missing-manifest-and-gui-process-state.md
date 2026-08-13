# Restore Missing Manifest and GUI Process State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reliably skip candidates with an explicitly absent manifest and report GUI restore uncertainty after an elevated process has started.

**Architecture:** Core separates reliable absence from access/I/O failure at the manifest boundary. GUI tracks restore launch state independently and restores its button guard in `finally`.

**Tech Stack:** Windows PowerShell 5.1, Pester 5.9.0, WPF/XAML.

---

### Task 1: Core manifest absence classification

**Files:**
- Modify: `src/Core/ActionEngine.ps1`
- Modify: `src/Core/BackupManager.ps1`
- Test: `tests/Pester/Restore.Tests.ps1`

- [ ] Add a test where the newest candidate directory has no manifest and the older candidate has a valid process manifest; assert the older package is selected.
- [ ] Add an entry test that mocks `Test-Path` to throw while checking `manifest.json`; assert exit code 1 and no older candidate validation.
- [ ] Run Restore tests and confirm the new cases fail for the expected missing-manifest classification reason.
- [ ] Add a manifest presence helper using `Test-Path -LiteralPath -PathType Leaf -ErrorAction Stop`; mark only a returned `false` as `CandidateRejected`.
- [ ] Remove the `File.Exists` empty-array fallback from `Read-BackupManifestEntries` so access/race failures reach `Get-Content` and propagate.
- [ ] Run Restore tests and require zero failures.

### Task 2: GUI restore process-started state

**Files:**
- Modify: `gui-cleaner.ps1`
- Test: `tests/Gui.Tests.ps1`

- [ ] Add a test where `Start-Process` returns a process and `WaitForExit` throws; assert the started/status-unknown warning, error state, enabled restore button, and one launch.
- [ ] Add a test where waiting succeeds but reading `ExitCode` throws; assert the same safety result and one launch.
- [ ] Run GUI tests and confirm both cases fail because the current catch reports `RestoreNotStarted`.
- [ ] Add localized `RestoreStatusUnknown`, `$script:RestoreInProgress`, a pre-launch button guard, `processStarted`, and a `finally` reset.
- [ ] Keep `RestoreNotStarted` only for pre-start/null-process failures and use `RestoreStatusUnknown` after launch.
- [ ] Run GUI tests and require zero failures.

### Task 3: Verification and commit

**Files:**
- Verify all modified PowerShell, XAML, and test files.

- [ ] Run Restore, GUI, full Core, and legacy suites.
- [ ] Parse modified PowerShell files with the PowerShell AST parser and parse `src/Gui/MainWindow.xaml` with `XamlReader` in STA mode.
- [ ] Run `git diff --check` and review the exact diff.
- [ ] Commit the implementation with a focused follow-up message and verify a clean worktree.
