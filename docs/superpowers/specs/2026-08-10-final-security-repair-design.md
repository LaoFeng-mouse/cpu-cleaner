# Final Security Repair Design

## Scope

This repair closes four reviewed gaps without performing real clean operations or mutating real Run keys, services, or scheduled tasks during automated verification.

## Locked pending-file lifecycle

`Open-LockedPendingFile` rejects a reparse-point input and opens the pending file once with `FileMode.Open`, `FileAccess.ReadWrite`, and `FileShare.Read`. Validation reads size-limited strict UTF-8 from that stream and keeps the same handle alive through authorization, user interaction, action processing, and final state persistence. `Write-PendingToLockedStream` rewinds, truncates, writes strict UTF-8 without BOM to that same stream, and calls `Flush(true)`. `Invoke-Clean` owns the stream and disposes it in `finally` for normal return, cancellation, and exceptions. `Read-LimitedPendingJsonFile` remains a compatibility wrapper that promptly disposes its stream.

This removes the path replacement/reparse race between read and write. It does not claim protection against hard links that cannot be verified with the available APIs.

## Pending v2 state persistence

`Build-PendingV2Payload` is the single state-envelope builder. It preserves `pending_schema_version = 2`, `generated`, all `actions`, all `observations`, all `suspicious`, and any existing non-conflicting safety-envelope fields. Every status transition is persisted through the locked stream, including initial authorization rejection. Cancellation or an empty selection performs no status transition and therefore does not invent one. GUI subset files retain the full v2 envelope and merge only selected action statuses back into the main envelope.

## Autostart value provenance

`New-Hit` accepts and stores `autostart_value`. Both autostart name and value matches pass the original scanner value through `Match-Profiles`, `Save-PendingActions`, and elevated `Test-PendingActionAuthorized`. An integration test exercises this complete path for exact/path value matching.

## Literal Run-value deletion

`Remove-LiteralAutostartValue` accepts only the existing Run-key whitelist, maps HKCU/HKLM paths to `Microsoft.Win32.RegistryKey`, opens the exact subkey writable, and calls `DeleteValue(name, false)`. Every key is disposed in `finally`. Production `remove_autostart` calls this helper; it never passes an unescaped value name to `Remove-ItemProperty`.

## Test strategy and safety

Tests first reproduce all four gaps. Pending-file tests use temporary files and prove lock denial, same-object writeback after path replacement, and exception release. Registry tests use only a random HKCU test subkey and delete that exact subkey in teardown; all production Run-key reads/mutations, services, and scheduled tasks are mocked. No test invokes a real clean or GUI Run mutation.
