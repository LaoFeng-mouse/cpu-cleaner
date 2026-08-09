# Schema 3.0 Matcher Provenance Hardening

## Status

- Priority: P0 security boundary
- Scope: profile matching, hit serialization, pending authorization, and matcher semantics
- Profile schema: remains Schema 3.0
- Pending file format: introduce `pending_schema_version: 2`

## Problem

Schema 3.0 currently decides whether a dangerous action is eligible by inspecting all matcher types declared for a hit category. If any matcher is `exact` or `path`, the whole category is treated as narrow. `Match-Profiles` then stores only the target and action, not the matcher that produced the hit. During elevated clean, `Test-PendingActionAuthorized` accepts the target if it matches any current detect rule.

This creates an authorization expansion. A profile containing both:

```json
{
  "services": [
    { "match": "LenovoExactService", "type": "exact" },
    { "match": "Lenovo", "type": "contains" }
  ],
  "actions": { "service": "disable_service" }
}
```

can detect `LenovoOtherService` through `contains` while retaining and later authorizing `disable_service` because the profile also contains an unrelated `exact` matcher.

The security invariant must be:

> Detection may be broad. A dangerous action may execute only when the matcher that produced this hit is `exact` or `path`, and the elevated process can reproduce that same match against the current target field.

`execution.allow_auto=true` must not bypass this invariant.

## Chosen approach

Carry matcher provenance through the complete scan-to-clean pipeline.

The alternatives were rejected:

- Splitting mixed profiles at load time changes profile semantics and complicates migration.
- Searching for any narrow matcher only during clean does not prove that the scan and the elevated authorization used the same matcher.

## Matching model

### Match result

Matching must return structured evidence rather than only a Boolean. A successful result contains:

```json
{
  "matched_pattern": "LenovoExactService",
  "matched_type": "exact",
  "matched_field": "service_name"
}
```

`matched_field` identifies the concrete candidate value used during scanning. Supported field names are:

- service: `service_name`, `service_display_name`
- autostart: `autostart_name`, `autostart_value`
- task: `task_name`, `task_path`
- process: `process_name`, `process_path`

The current detect array order remains authoritative. The first matcher/field pair that succeeds becomes the hit evidence. This is deliberately fail-closed: if a broad matcher appears before a narrow matcher and produces the hit, the hit is observation-only.

### Literal semantics

- `exact`: ordinal, case-insensitive equality.
- `contains`: ordinal, case-insensitive literal substring using `IndexOf`; `*`, `?`, and `[...]` have no wildcard meaning.
- `path`: ordinal, case-insensitive literal prefix using `StartsWith`; wildcard characters remain literal.
- `regex`: the only expression matcher; invalid expressions return false.
- `publisher` and `sha256`: remain detection-only for dangerous actions in this change. They are not treated as `exact` or `path`.
- Unknown matcher types continue to be rejected by Schema validation. Runtime fallback must not silently turn an unknown type into `contains` for loaded Schema 3.0 profiles.

Process-name normalization remains in place before `exact` or `contains` comparison, but the recorded pattern and type are the original normalized detect item.

## Scan and action eligibility

`Match-Profiles` records `matched_pattern`, `matched_type`, and `matched_field` on every hit.

The declared profile action is converted to an effective hit action:

- Non-dangerous actions remain unchanged.
- A dangerous action remains executable only when all are true:
  - `safe=true`
  - `evidence.tested=true`
  - `matched_type` is `exact` or `path`
- Otherwise the effective hit action becomes `investigate` and the hit remains visible as an observation.

This decision occurs per hit, not per profile category. `Load-Profiles` no longer grants a dangerous action because some other matcher in the category is narrow.

`execution.allow_auto` remains parseable for backward compatibility and audit notes, but it cannot turn a broad hit into an executable action. Broad dangerous-action profiles may produce a compatibility warning so maintainers can replace them with narrow matchers.

## Pending format

`Save-PendingActions` writes:

```json
{
  "pending_schema_version": 2,
  "generated": "2026-08-09 20:00:00",
  "actions": [
    {
      "id": "lenovo-x",
      "hit_type": "service",
      "action": "disable_service",
      "service_name": "LenovoExactService",
      "matched_pattern": "LenovoExactService",
      "matched_type": "exact",
      "matched_field": "service_name",
      "status": "pending"
    }
  ]
}
```

Matcher evidence is preserved on observations as well, so the UI and reports can explain why a broad match was detected but not executable.

Pending files without `pending_schema_version: 2`, or executable entries missing any matcher evidence field, are rejected by clean with an instruction to scan again. They are never silently upgraded because the missing provenance cannot be reconstructed safely.

## Elevated reauthorization

`Test-PendingActionAuthorized` must fail closed unless all checks pass:

1. The profile ID still exists.
2. The current profile is `safe=true` and, when evidence is present, `evidence.tested=true`.
3. The requested action exactly equals the current action declared for the hit type.
4. `matched_type` is `exact` or `path`.
5. The current profile still contains an identical detect item with the same `matched_pattern` and `matched_type` in the hit category.
6. `matched_field` is valid for the hit category.
7. The elevated process retrieves the current value for that field and the saved matcher matches it again.
8. The actionable identity still exists and corresponds to the pending target.

For example, a service hit on `service_display_name` requires clean to retrieve the service identified by `service_name`, read its current display name, and apply the same matcher to that current display name. It must not substitute the service name or another detect rule.

Tampering with the pending pattern, type, field, action, ID, or target causes `skipped`, with no system mutation.

## Error handling and compatibility

- Authorization failures are reported as skipped with a reason suitable for the GUI and CLI report.
- Old pending files require a fresh scan.
- Existing profile files remain Schema 3.0; no automatic profile rewrite is required.
- `allow_auto=true` on a broad matcher no longer grants execution. This is an intentional security tightening.
- The change does not alter backup or restore behavior.

## Test strategy

Tests follow red-green-refactor and must include:

1. Mixed service matchers: `LenovoOtherService` is detected by `contains` but cannot enter the executable queue.
2. The same mixed profile: `LenovoExactService` records `exact` evidence and may enter the queue.
3. `allow_auto=true` cannot authorize a `contains` or `regex` dangerous hit.
4. Hit and pending serialization preserve pattern, type, and field.
5. Elevated authorization succeeds only with the identical current matcher and field.
6. Changed profile, pattern, type, field, action, ID, or target is rejected.
7. Old or incomplete pending entries are rejected and require rescan.
8. `contains` treats `*`, `?`, `[` and `]` literally and compares case-insensitively.
9. `path` treats wildcard characters literally and performs a case-insensitive prefix comparison.
10. Existing pure exact/path behavior and the complete test suite remain green.

No test may execute a real service, task, autostart, uninstall, or process mutation.

## Acceptance criteria

- A target matched only by a broad matcher can never produce or pass authorization for a dangerous action, even when the same profile contains a narrow matcher or `allow_auto=true`.
- Every executable pending action contains auditable matcher provenance.
- Elevated clean reproduces the same match against the same current field before mutation.
- Literal matcher semantics do not interpret wildcard syntax.
- All automated tests pass without mutating the host system.
