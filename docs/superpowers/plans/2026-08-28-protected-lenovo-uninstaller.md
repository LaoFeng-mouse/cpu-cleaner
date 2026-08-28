# Protected Lenovo Official Uninstaller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect PPL-protected `HRWSCCtrl` truthfully and, only after explicit review and fresh security validation, open Lenovo's signed official uninstaller without silent arguments or a false cleanup-success claim.

**Architecture:** Add one shared, fail-closed `ProtectedServiceHandoff` core module for native service-protection collection, strict Lenovo uninstall evidence discovery, and launch-time revalidation. Bind that evidence into protected inventory schema v3 and pending identities. Keep non-PPL service stopping in the existing elevated ActionEngine path; route `open_official_uninstaller` through a separate standard-user GUI handoff that returns `manual_required` after process creation.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, WPF, P/Invoke (`advapi32!QueryServiceConfig2W`, `kernel32!GetFileInformationByHandle`), Windows registry, Authenticode, Pester 5, existing non-Pester and GUI test runners.

---

## Contract decisions fixed by this plan

- Protected inventory schema becomes integer `3`; schema v2, missing fields, unknown protection values, and future versions fail closed and require a fresh scan.
- The new profile action is exactly `open_official_uninstaller` and is legal only for an exact `service_name` hit with `LaunchProtectedStatus=complete`, `LaunchProtectedLevel=3`, and complete trusted uninstall evidence.
- Every inventory service record has these additional exact-shape fields:

  ```text
  LaunchProtectedStatus       complete | unavailable
  LaunchProtectedLevel        0..3 when complete; -1 when unavailable
  UninstallEvidenceStatus     complete | unavailable
  UninstallRegistryPath       non-empty only when complete
  UninstallDisplayName        non-empty only when complete
  UninstallPublisher          non-empty only when complete
  UninstallDisplayVersion     scalar string; may be empty
  UninstallInstallLocation    rooted canonical directory only when complete
  UninstallString             reviewed scalar command only when complete
  UninstallExecutablePath     rooted canonical .exe only when complete
  ```

- Uninstall evidence is collected only for exact service name `HRWSCCtrl`; all other service records carry `unavailable`, `-1`, and empty uninstall fields.
- Accepted uninstall entries are under the two standard HKLM uninstall roots (64-bit and 32-bit views), have a display name beginning with `联想电脑管家`, a Lenovo publisher from the explicit allowlist, a rooted existing `InstallLocation`, and an `UninstallString` that parses to one local `.exe` with zero arguments.
- `msiexec`, `cmd`, PowerShell, script hosts, environment variables, relative paths, URI targets, non-EXE files, and any command arguments are rejected.
- Launch-time drift, reparse, hardlink, path containment, signature, publisher, or stable-file-identity failures produce `skipped` with no `failure_stage`. Only a process creation API failure produces `failed/launch`.
- Successful process creation produces `manual_required`: opening the uninstaller is not proof of uninstall.
- Mixed GUI selections are supported: local handoffs are completed first and converted to terminal result records; remaining ordinary actions continue through the existing elevated clean pipeline. The two result sets are merged only against the same reviewed pending generation.

## Task 1: Add the shared protection and uninstall-evidence primitives

**Files:**

- Create: `src/Core/ProtectedServiceHandoff.ps1`
- Create: `tests/Pester/ProtectedServiceHandoff.Tests.ps1`
- Modify: `cpu-cleaner.ps1:62`
- Modify: `gui-cleaner.ps1:11-15`
- Modify: `tests/run-unit.ps1:14-16`

- [ ] Write failing tests for native protection result normalization.

  Cover `0`, `1`, `2`, and `3` as `complete`; a missing service, access failure, native error, negative value, array value, and value above `3` as `unavailable/-1`. Mock the native boundary through an injectable `-NativeQuery` scriptblock so unit tests never require SCM mutation.

- [ ] Write failing table tests for strict uninstall-command parsing.

  The accepted cases are exactly:

  ```powershell
  'C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe'
  '"C:\Program Files (x86)\Lenovo\PCManager\5.1\uninst.exe"'
  ```

  The rejected cases must include `uninst.exe /S`, `msiexec /x {GUID}`, `cmd /c`, `powershell -File`, `wscript`, `%ProgramFiles%`, `..\uninst.exe`, `file:///...`, `.bat`, an unclosed quote, and trailing whitespace after a quoted command.

- [ ] Run the focused tests and confirm RED.

  ```powershell
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/ProtectedServiceHandoff.Tests.ps1 -Output Detailed"
  ```

  Expected: failures because `Get-ServiceLaunchProtectedState` and `ConvertFrom-StrictOfficialUninstallString` do not exist.

- [ ] Implement the native and parser boundary in the new module.

  Use these public contracts:

  ```powershell
  function Get-ServiceLaunchProtectedState {
      param([Parameter(Mandatory=$true)][string]$ServiceName, [scriptblock]$NativeQuery)
      # Returns only: [pscustomobject]@{ Status='complete'; Level=[int]0..3 }
      # or:          [pscustomobject]@{ Status='unavailable'; Level=[int]-1 }
  }

  function ConvertFrom-StrictOfficialUninstallString {
      param([Parameter(Mandatory=$true)][string]$Command)
      # Returns a canonical rooted .exe path or $null. It never returns arguments.
  }
  ```

  `Initialize-ServiceProtectionNativeApi` must P/Invoke `OpenSCManagerW`, `OpenServiceW`, `QueryServiceConfig2W` with `SERVICE_QUERY_CONFIG`, info level `SERVICE_CONFIG_LAUNCH_PROTECTED=12`, and close all safe handles. Native exceptions and nonzero Win32 errors are converted to `unavailable`; do not leak raw service paths or handles into pending data.

  The parser must use an anchored grammar, not `Invoke-Expression`, `CommandLineToArgvW`, environment expansion, or shell parsing:

  ```powershell
  $candidate = if ($Command -cmatch '^"([^"\r\n]+\.exe)"$') {
      $Matches[1]
  } elseif ($Command -cmatch '^([^"\r\n]+\.exe)$') {
      $Matches[1]
  } else { return $null }
  ```

  Then require `Path.IsPathFullyQualified` when available (with a PS5.1 drive/UNC fallback), canonicalize with `GetFullPath`, reject UNC for this feature, and reject filenames matching `cmd.exe`, `powershell.exe`, `pwsh.exe`, `msiexec.exe`, `wscript.exe`, or `cscript.exe`.

- [ ] Load the module before consumers.

  Add `ProtectedServiceHandoff` after `Utils` and before `ProfileEngine` in `cpu-cleaner.ps1` and `tests/run-unit.ps1`. Dot-source it before `ProfileEngine` in `gui-cleaner.ps1`.

- [ ] Run the focused tests and confirm GREEN on PS7, then PS5.1.

  ```powershell
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/ProtectedServiceHandoff.Tests.ps1 -Output Detailed"
  powershell.exe -NoProfile -Command "Invoke-Pester -Path tests/Pester/ProtectedServiceHandoff.Tests.ps1 -Output Detailed"
  ```

  Expected: all parser/native-normalization tests pass.

- [ ] Commit.

  ```powershell
  git add src/Core/ProtectedServiceHandoff.ps1 tests/Pester/ProtectedServiceHandoff.Tests.ps1 cpu-cleaner.ps1 gui-cleaner.ps1 tests/run-unit.ps1
  git commit -m "feat: add protected Lenovo handoff primitives"
  ```

## Task 2: Discover a strict Lenovo uninstall registry snapshot

**Files:**

- Modify: `src/Core/ProtectedServiceHandoff.ps1`
- Modify: `tests/Pester/ProtectedServiceHandoff.Tests.ps1`

- [ ] Add failing discovery tests using an injected registry reader.

  Verify one deterministic result only when all fields agree. Test duplicate matching entries, wrong hive, empty source key, wrong display name, non-Lenovo publisher, missing install location, executable outside install location, command arguments, and multiple candidates. Every ambiguous case must return `unavailable` rather than choosing the first item.

- [ ] Implement `Get-LenovoOfficialUninstallEvidence`.

  Return this exact ordered shape for both success and failure:

  ```powershell
  [pscustomobject][ordered]@{
      UninstallEvidenceStatus  = 'complete' # otherwise unavailable
      UninstallRegistryPath    = $registryPath
      UninstallDisplayName     = $displayName
      UninstallPublisher       = $publisher
      UninstallDisplayVersion  = $displayVersion
      UninstallInstallLocation = $installLocation
      UninstallString          = $uninstallString
      UninstallExecutablePath  = $executablePath
  }
  ```

  Failure returns `unavailable` plus seven empty strings. Query only:

  ```text
  HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*
  HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*
  ```

  Use ordinal-ignore-case canonical containment with a separator boundary:

  ```powershell
  $root = $installLocation.TrimEnd('\') + '\'
  if (-not $executablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { reject }
  ```

  Allow display names beginning with `联想电脑管家`; allow publishers exactly `联想（北京）有限公司`, `联想(北京)有限公司`, or `Lenovo (Beijing) Limited`. Keep the allowlists in module-scope constants and test every accepted value.

- [ ] Run the focused tests on both PowerShell editions.

  Expected: one complete snapshot for one valid registry item; all ambiguity and malformed input cases return the exact unavailable shape.

- [ ] Commit.

  ```powershell
  git add src/Core/ProtectedServiceHandoff.ps1 tests/Pester/ProtectedServiceHandoff.Tests.ps1
  git commit -m "feat: discover strict Lenovo uninstall evidence"
  ```

## Task 3: Upgrade protected inventory to schema v3

**Files:**

- Modify: `src/Core/InventoryManager.ps1:2,298-427,943-1019`
- Modify: `src/Core/Scanner.ps1:713-738`
- Modify: `tests/Pester/Inventory.Tests.ps1`
- Modify: `tests/Pester/Scanner.Tests.ps1`

- [ ] Add failing inventory shape tests.

  Update valid fixtures to schema `3` and the ten new service fields. Add explicit rejection tests for schema v2, missing/extra/case-variant fields, non-integer protection level, complete with a value outside `0..3`, unavailable with a value other than `-1`, partially empty complete uninstall evidence, non-empty unavailable evidence, non-canonical/rootless paths, and uninstall executable outside install location.

- [ ] Add failing collector tests.

  Mock `Get-ServiceLaunchProtectedState` and `Get-LenovoOfficialUninstallEvidence`. Prove exact `HRWSCCtrl` receives both snapshots, another service receives only its protection state and an unavailable uninstall shape, and collector failure remains represented as unavailable without changing inventory health to false success.

- [ ] Run RED.

  ```powershell
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester/Inventory.Tests.ps1,tests/Pester/Scanner.Tests.ps1 -Output Detailed"
  ```

  Expected: exact-field and version assertions fail until InventoryManager and Scanner are updated.

- [ ] Set `$script:InventorySchemaVersion = 3` and extend `Assert-InventoryServiceRecord`.

  Add two focused validators:

  ```powershell
  function Assert-InventoryLaunchProtectedShape($Record) { ... }
  function Assert-InventoryUninstallEvidenceShape($Record) { ... }
  ```

  Both must validate exact scalar types and cross-field invariants. Do not coerce strings to integers and do not accept arrays with one valid element.

- [ ] Extend `ConvertTo-InventoryServiceRecord`.

  Always call `Get-ServiceLaunchProtectedState -ServiceName $Record.Name`. Call `Get-LenovoOfficialUninstallEvidence` only when `Record.Name` equals `HRWSCCtrl` ordinal-ignore-case. Append all ten fields in the exact order fixed above.

- [ ] Extend trusted inventory conversion in `Get-ScanServiceTaskInventory`.

  Copy all ten fields unchanged and update the internal marker to `trusted_inventory_v3`. Never derive protection status or registry evidence in the ordinary scanner.

- [ ] Run GREEN on PS7 and PS5.1.

  Expected: inventory v3 accepted, v2 rejected, trusted fields copied byte-for-value, and all malformed shapes rejected.

- [ ] Commit.

  ```powershell
  git add src/Core/InventoryManager.ps1 src/Core/Scanner.ps1 tests/Pester/Inventory.Tests.ps1 tests/Pester/Scanner.Tests.ps1
  git commit -m "feat: bind protected service evidence to inventory v3"
  ```

## Task 4: Select PPL handoff versus ordinary runtime stop in ProfileEngine

**Files:**

- Modify: `src/Core/ProfileEngine.ps1:3-9,499-589`
- Modify: `bloatware-profiles.json:350-406`
- Modify: `tests/Pester/Profile.Tests.ps1`
- Modify: `tests/Pester/Pending.Tests.ps1`
- Modify: `tests/Pester/Schema3.Tests.ps1`

- [ ] Add failing decision matrix tests.

  Use an exact `service_name=HRWSCCtrl` match and assert:

  | Protection/evidence | Expected action |
  |---|---|
  | complete / 3 + complete uninstall | `open_official_uninstaller` |
  | complete / 3 + unavailable uninstall | `investigate` |
  | complete / 0 + complete process identity | `stop_service_runtime` |
  | unavailable / -1 | `investigate` |
  | missing, string `3`, array `[3]`, value `4` | `investigate` |
  | contains matcher on the same service | `investigate` |

  Assert the PPL hit includes every reviewed uninstall field and does not include executable process-stop identity fields.

- [ ] Register `open_official_uninstaller` as a manual-impact action only.

  Add it to `$script:ValidActions`, `$script:ManualImpactActions`, and `$script:DangerousActions`, but not `$script:PersistentDangerousActions`. Extend profile validation so it is legal only as `manual_actions.service`, with `manual_impact`, `default_selected=false`, `requires_confirmation=true`, and tested evidence.

- [ ] Implement service-specific decision refinement in `Match-Profiles`.

  Keep profile policy declaration as the intent, then refine the exact HRWS action from trusted service fields:

  ```powershell
  if ($decision.Action -ceq 'open_official_uninstaller') {
      if (Test-PplOfficialUninstallServiceShape -Service $s -MatchEvidence $matchEvidence) {
          # copy reviewed protection and uninstall snapshot to New-Hit
      } elseif (Test-NonProtectedExactServiceShape -Service $s -MatchEvidence $matchEvidence) {
          $decision.Action = 'stop_service_runtime'
          # retain the existing process identity path
      } else {
          # downgrade to investigate with a fixed truthful observation reason
      }
  }
  ```

  Do not let profile JSON alone assert that the live service is PPL. Only `trusted_inventory_v3` service fields authorize the new handoff.

- [ ] Update the HRWS profile.

  Change `manual_actions.service` to `open_official_uninstaller`. Use these Chinese policy values:

  ```json
  {
    "necessity": "optional",
    "default_selected": false,
    "requires_confirmation": true,
    "impact_cn": "可能移除联想电脑管家的安全、防护、通知和相关后台组件",
    "cleanup_reason_cn": "Windows 受保护服务阻止普通管理员实时停止；不需要联想电脑管家时可按需打开联想官方卸载程序"
  }
  ```

- [ ] Run focused tests on both PowerShell editions.

  Expected: PPL produces only the handoff, non-PPL preserves runtime stop, and every missing/broad/untrusted case is observation-only.

- [ ] Commit.

  ```powershell
  git add src/Core/ProfileEngine.ps1 bloatware-profiles.json tests/Pester/Profile.Tests.ps1 tests/Pester/Pending.Tests.ps1 tests/Pester/Schema3.Tests.ps1
  git commit -m "feat: route protected HRWS to official uninstall handoff"
  ```

## Task 5: Bind the official handoff into pending identity and subset validation

**Files:**

- Modify: `src/Core/ActionEngine.ps1:514-539,1040-1104`
- Modify: `gui-cleaner.ps1:437-576,1870-1944`
- Modify: `tests/Pester/Pending.Tests.ps1`
- Modify: `tests/Gui.Tests.ps1`

- [ ] Add failing tamper tests.

  A valid handoff action must bind: action, exact matcher provenance, service name, protection status/level, registry path, display name, publisher, version, install location, reviewed uninstall string, and canonical executable path. Mutating, deleting, case-renaming, array-wrapping, or adding an internal `ProcessIdentitySource` marker must make shape validation/digest/selection fail.

- [ ] Add `Test-OfficialUninstallerActionShape`.

  Require `safe=false`, manual-impact policy, exact `service_name`, service `HRWSCCtrl`, `LaunchProtectedStatus=complete`, integer level `3`, and all complete uninstall evidence fields. Reuse the strict parser and containment check so pending cannot carry a path shape that inventory would reject.

- [ ] Extend `Get-PendingIdentityKey` and manual-impact digest validation.

  For `open_official_uninstaller`, append the ten protected/uninstall fields to the ordered identity object. This makes reviewed selection, confirmation digest, subset creation, strict result reading, and merge use the same immutable identity.

- [ ] Explicitly prevent elevated ActionEngine execution.

  `Test-ActionMatchesHitType` may recognize the action as a service handoff for pending validation, but `Invoke-Clean` must return a fixed `skipped` result if it ever receives `open_official_uninstaller`. The GUI is the only authorized launcher; CLI clean must never start third-party uninstall UI under its elevated process.

- [ ] Run focused pending and GUI tests.

  Expected: exact reviewed copies pass; every identity mutation fails before process start; the CLI clean path cannot launch the uninstaller.

- [ ] Commit.

  ```powershell
  git add src/Core/ActionEngine.ps1 gui-cleaner.ps1 tests/Pester/Pending.Tests.ps1 tests/Gui.Tests.ps1
  git commit -m "feat: bind official uninstall handoff identity"
  ```

## Task 6: Implement launch-time registry, file, and signature revalidation

**Files:**

- Modify: `src/Core/ProtectedServiceHandoff.ps1`
- Modify: `tests/Pester/ProtectedServiceHandoff.Tests.ps1`

- [ ] Add failing revalidation tests with injected boundaries.

  Cover exact success plus: registry source drift, display/publisher/location/string/path drift, missing file, directory target, any reparse component, `nNumberOfLinks != 1`, final path outside install root, pre/post file identity mismatch, pre/post hash mismatch, invalid Authenticode status, absent certificate, wrong signer organization, and exceptions from every injected reader. Assert no launch callback is called in all rejection cases.

- [ ] Implement stable file snapshot and Lenovo signer checks.

  Use `FileStream` with read access and `FileShare.Read`, existing-style `GetFileInformationByHandle`, and `GetFinalPathNameByHandleW`. Capture volume serial, file index, link count, length, last-write UTC, final DOS path, and SHA-256. Require one link and no reparse point in every existing path component. Parse the certificate subject with `System.Security.Cryptography.X509Certificates.X500DistinguishedName`; accept organization values exactly `LENOVO (BEIJING) LIMITED`, `Lenovo (Beijing) Limited`, or `联想（北京）有限公司` after trim, ordinal-ignore-case for Latin values.

- [ ] Implement `Test-ReviewedLenovoUninstaller`.

  The function takes the reviewed action plus injectable registry/signature/file readers and returns only:

  ```powershell
  [pscustomobject]@{ Status='validated'; ExecutablePath='C:\...\uninst.exe'; Code='' }
  [pscustomobject]@{ Status='skipped';   ExecutablePath=''; Code='REGISTRY_DRIFT' }
  ```

  Codes are fixed allowlisted identifiers and never contain paths or exceptions. Re-read the exact reviewed registry source, rebuild evidence through the same strict parser, compare every bound field ordinally (paths ordinal-ignore-case), snapshot the file, validate signature, snapshot again, and require identical file identity/hash before returning `validated`.

- [ ] Implement `Invoke-ReviewedLenovoUninstallerHandoff`.

  Accept an injectable launcher; production launcher must call exactly:

  ```powershell
  Start-Process -FilePath $validated.ExecutablePath -PassThru -ErrorAction Stop
  ```

  It must not pass `ArgumentList`, `Verb RunAs`, `WorkingDirectory`, shell text, or the raw uninstall command. Return:

  ```powershell
  manual_required / "联想官方卸载程序已打开，请在其中确认或取消" / empty stage
  skipped         / fixed rescan reason                                  / empty stage
  failed          / "无法启动联想官方卸载程序"                           / launch
  ```

- [ ] Run focused tests on both PowerShell editions.

  Expected: only the exact stable, single-link, signed Lenovo executable reaches the launcher; launch receives one named `FilePath` and no arguments.

- [ ] Commit.

  ```powershell
  git add src/Core/ProtectedServiceHandoff.ps1 tests/Pester/ProtectedServiceHandoff.Tests.ps1
  git commit -m "feat: revalidate and open Lenovo official uninstaller"
  ```

## Task 7: Add truthful GUI presentation and local handoff coordination

**Files:**

- Modify: `gui-cleaner.ps1:28-80,603-730,1946-2013,2172-2213,2337-2405`
- Modify: `src/Gui/Presentation.ps1:185-255`
- Modify: `src/Gui/MainWindow.xaml`
- Modify: `tests/Gui.Tests.ps1`
- Modify: `tests/GuiPresentation.Tests.ps1`

- [ ] Add failing presentation tests.

  Assert the review row shows `Windows 受保护服务`, `必要性：按需卸载`, and action label `打开联想官方卸载程序`; remains unchecked after “select all”; and uses `不自动恢复（由联想卸载程序决定）` instead of claiming a restore package.

- [ ] Add failing confirmation and execution tests.

  Confirmation must say that only the official uninstaller will open and all later choices remain with the user. Decline means no launcher call and no pending merge. Success yields `manual_required`, launch failure accepts only `failure_stage=launch`, and drift yields `skipped` with an empty stage. Add a mixed-selection test proving one local handoff result and one elevated-clean result are merged once against the unchanged reviewed generation.

- [ ] Update labels and failure-stage presentation.

  Add `open_official_uninstaller` to `Get-ActionLabel`, add the protected status/necessity/restorability text in `Get-PendingViewItems`, and map `launch` to `失败阶段：启动卸载程序`. Extend strict terminal-result validation to permit `launch` only for failed official-handoff actions; reject `launch` for all other actions.

- [ ] Refactor `Start-GuiExecution` into two explicit partitions.

  After existing reviewed allowlist resolution and one confirmation:

  ```powershell
  $handoffs = @($payload.actions | Where-Object action -CEQ 'open_official_uninstaller')
  $core     = @($payload.actions | Where-Object action -CNE 'open_official_uninstaller')
  ```

  Execute each handoff through `Invoke-ReviewedLenovoUninstallerHandoff`. Convert results to the same immutable four-field terminal records used by `Merge-PendingStatus`. If `$core.Count -gt 0`, continue through the existing hashed subset/elevated clean path. Aggregate only after each branch has a terminal result; if the reviewed main-file generation changed, refuse the merge and preserve diagnostics. Keep the existing execution-in-progress close lock for either branch.

- [ ] Update GUI text.

  Replace “全部需要管理员” wording with conditional text: ordinary cleanup may request UAC; opening Lenovo's official uninstaller lets that program request UAC itself. Do not add an uninstall progress percentage or completion claim.

- [ ] Run GUI tests.

  ```powershell
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Gui.Tests.ps1,tests/GuiPresentation.Tests.ps1 -Output Detailed"
  ```

  Expected: all handoff, mixed-selection, strict-result, localization, and existing execution lifecycle tests pass.

- [ ] Commit.

  ```powershell
  git add gui-cleaner.ps1 src/Gui/Presentation.ps1 src/Gui/MainWindow.xaml tests/Gui.Tests.ps1 tests/GuiPresentation.Tests.ps1
  git commit -m "feat: present protected Lenovo uninstall handoff"
  ```

## Task 8: Update security documentation and run the complete automated gate

**Files:**

- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/superpowers/specs/2026-08-28-protected-lenovo-uninstaller-design.md`
- Modify: any existing inventory schema documentation located by `rg -n "inventory.*v2|inventory_schema_version|stop_service_runtime" README.md SECURITY.md docs`

- [ ] Document inventory v3, the PPL boundary, the exact official-handoff contract, and the requirement to rescan old inventory/pending data.

- [ ] State clearly that `manual_required` means the uninstaller was opened, not that Lenovo software was removed.

- [ ] Run formatting and repository integrity checks.

  ```powershell
  git diff --check
  pwsh -NoProfile -File tests/run-unit.ps1
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Pester -Output Detailed"
  pwsh -NoProfile -Command "Invoke-Pester -Path tests/Gui.Tests.ps1,tests/GuiPresentation.Tests.ps1 -Output Detailed"
  powershell.exe -NoProfile -File tests/run-unit.ps1
  powershell.exe -NoProfile -Command "Invoke-Pester -Path tests/Pester -Output Detailed"
  ```

  Expected: zero failures on PS7 and Windows PowerShell 5.1. A Pester availability failure is an environment gate, not a passing test; install/use the repository's established Pester runtime before continuing.

- [ ] Run source-level safety assertions.

  ```powershell
  rg -n "open_official_uninstaller|ArgumentList|Verb RunAs|UninstallString|failure_stage" src gui-cleaner.ps1 tests
  rg -n "SERVICE_CONFIG_LAUNCH_PROTECTED|QueryServiceConfig2W|trusted_inventory_v3" src tests
  ```

  Manually verify that the production handoff launcher has no `ArgumentList`, no silent switch, no shell invocation, and no success result.

- [ ] Commit documentation.

  ```powershell
  git add README.md SECURITY.md docs
  git commit -m "docs: explain protected Lenovo uninstall handoff"
  ```

## Task 9: Perform user-approved real-machine acceptance without forcing uninstall

**Files:**

- Create: `diagnostics/acceptance-protected-lenovo-<timestamp>.json` (diagnostic artifact; do not commit)
- Modify only if a reproduced defect requires a separate TDD fix and commit.

- [ ] Confirm the branch is clean except existing untracked diagnostics and record the exact commit.

  ```powershell
  git status --short
  git rev-parse HEAD
  ```

- [ ] Launch the GUI normally and perform a fresh protected scan.

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\gui-cleaner.ps1
  ```

  Approve only the read-only inventory UAC. Verify the HRWS row displays `Windows 受保护服务`, is default-unselected, and offers `打开联想官方卸载程序`; it must not offer a runtime STOP.

- [ ] Select only the HRWS handoff, inspect the second confirmation, and continue.

  Verify the Lenovo-signed `uninst.exe` opens. Do not click the uninstaller's final remove/confirm controls unless the user separately requests actual uninstall at that moment.

- [ ] Capture process-launch evidence without exposing private paths in the user-facing result.

  Record process image path, command-line argument count, signer status/organization, reviewed pending hash, and terminal status in the local diagnostic JSON. Acceptance requires zero arguments supplied by Cleaner and terminal status `manual_required`.

- [ ] Verify negative claims.

  Confirm Cleaner did not auto-click the Lenovo UI, did not pass `/S`, `/quiet`, `/silent`, or any raw `UninstallString` arguments, did not report `success`, and did not claim HRWS was removed merely because the uninstaller opened.

- [ ] Re-scan after closing or cancelling the uninstaller.

  If the user did not uninstall, HRWS may remain and must be shown again truthfully. If the user independently completed uninstall, a fresh scan may show it absent; that result is evidence of the user's completed vendor flow, not Cleaner auto-uninstall.

- [ ] Final branch verification.

  ```powershell
  git status --short
  git log --oneline --decorate -12
  git diff --check HEAD~8..HEAD
  ```

  Do not commit `diagnostics/`. Do not merge or push until the user reviews the real GUI result and explicitly approves publication.

## Plan self-review checklist

- [ ] Every design-spec requirement maps to a task: native PPL collection (1/3), strict registry evidence (2), decision split (4), pending binding (5), launch revalidation (6), truthful GUI/status (7), full gates (8), and real acceptance (9).
- [ ] No placeholder text such as `TBD`, `TODO`, “add tests”, or an unspecified future decision remains.
- [ ] Inventory schema v3 and pending schema v3 are treated as separate contracts; this plan changes only inventory schema version.
- [ ] `LaunchProtectedLevel` remains an integer throughout inventory, scanner, pending, digest, and revalidation; no string coercion is allowed.
- [ ] Only `failed` handoff results may carry `failure_stage=launch`; `skipped` and `manual_required` carry an empty stage.
- [ ] Existing non-PPL `stop_service_runtime` identity, SCM same-handle control, and stable verification tests remain unchanged and passing.
- [ ] Real acceptance stops at opening the vendor UI unless the user separately authorizes actual uninstall.
