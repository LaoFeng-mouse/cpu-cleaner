# Restore Missing Manifest and GUI Process State Design

## Goal

Close two fail-closed gaps without changing the visual design or performing real restore/UAC operations.

## Core boundary

`Get-TrustedRestorePackage` checks `manifest.json` with `Test-Path -LiteralPath -PathType Leaf -ErrorAction Stop` before ACL validation and reading. A reliable `false` result becomes an explicit `CandidateRejected`, allowing `latest` to continue to an older package. Any exception from the existence check, ACL check, file read, or later I/O remains unclassified and propagates to exit code 1. `Read-BackupManifestEntries` performs the actual read without a preceding `File.Exists` fallback, so a post-check race cannot be misreported as an ordinary missing candidate.

## GUI boundary

`Invoke-GuiRestoreLatest` uses a restore-specific in-progress guard and a local `processStarted` flag. The restore button is disabled before `Start-Process`; a second call returns without starting another process. Only failures before a non-null process is returned use `RestoreNotStarted`. Failures from `WaitForExit` or reading `ExitCode` use a new localized status-unknown message stating that the process started and partial modification may have occurred. A `finally` block restores the guard and button availability while preserving the resulting completed/error GUI state.

## Tests

- Core: empty newest candidate plus valid older candidate selects the older package; a manifest existence-check exception propagates and does not inspect the older package.
- GUI: `WaitForExit` failure and `ExitCode` getter failure both show the started/status-unknown warning, restore button availability, and one `Start-Process` call.
- Verification: Restore, GUI, full Core, legacy suites, PowerShell AST, XAML parse, and `git diff --check`.

## Safety

All elevated process, ACL, existence-check failure, and restore actions are mocked. No real GUI, UAC, restore, ACL mutation, or system mutation is allowed.
