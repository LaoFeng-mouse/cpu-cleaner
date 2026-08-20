# Service restore already-running design

## Context

During the merged local end-to-end test, cleanup successfully changed `GAService` from `Running/Automatic` to `Stopped/Disabled`. Restoring the trusted backup returned exit code `2`, although the final service state was correctly restored to `Running/Automatic`.

Windows reports service-control error `1056` as "An instance of the service is already running." A service can be started by another component after its startup configuration is restored but before the restore code issues `sc start`. The current implementation treats every nonzero `sc start` exit code as a restore failure and skips final-state verification.

## Approved behavior

For a restore plan whose expected service state is `Running`:

- `sc start` exit code `0` proceeds to final-state verification.
- Exit code `1056` also proceeds to final-state verification because it means the desired running state may already have been reached.
- Every other nonzero exit code remains an immediate failure.
- Success is still determined by strict final reads of startup type, delayed-auto-start configuration when applicable, and runtime status.

No Task Scheduler behavior changes are included. If `Get-ScheduledTask`, `schtasks`, and Task Scheduler COM cannot read tasks, scanning remains fail-closed and must not report an empty task set.

## Implementation boundary

Change only the service branch of `Invoke-RestorePlanAction` in `src/Core/ActionEngine.ps1`. Treat `1056` as a nonfatal start result and continue through the existing verification path. Do not add retries, suppress other errors, or alter backup trust validation.

## Tests

Use test-driven development:

1. Add a regression test where service configuration succeeds, `sc start` returns `1056`, and final service state matches the restore plan. The test must fail before the implementation change and pass afterward.
2. Preserve or add coverage showing another nonzero start error remains a failure.
3. Run the targeted restore tests, the complete Pester suite, GUI tests, legacy logic/schema tests, static analysis, and `git diff --check`.

## Acceptance criteria

- A service already running at start time is not falsely reported as a restore failure when all final-state checks match.
- Real service-control errors remain visible and fail safely.
- Backup trust checks and Task Scheduler fail-closed behavior are unchanged.
- The full automated suite remains green.
