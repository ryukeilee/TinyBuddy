# TinyBuddy Repository Guidance

## Project Structure & Module Organization

TinyBuddy is a Swift 6.0 (swiftLanguageMode .v6) macOS 14 project with both Swift Package Manager and Xcode project entry points.

- `Sources/TinyBuddyCore/` contains shared domain logic: daily stats persistence, Git activity stores (commit count, focus block count, recent project, refresh status, refresh policy, trusted snapshot, command execution), focus session engine, project exclusion matching, data repair/validation, transaction log, time calibration, combined snapshot store, widget presentation models, widget lifecycle health check, timeline generation tracking, version upgrade tracking, project identity, HUD theme and display presentation, privacy redaction, storage cleanup, shared snapshot observation, debug logging and diagnostics, and release verification support.
- `Sources/TinyBuddy/` contains the macOS SwiftUI HUD app, Git scan-root authorization store and settings, Git refresh coordination, repository change monitoring, focus session UI and manual control, pet status display, app lifecycle wiring, login item management, instance and configuration coordination, HUD window positioning, environment change monitoring, onboarding, reset/repair coordination, diagnostics, focus notification management, history query, and project management.
- `Sources/TinyBuddyReleaseInstaller/` contains the narrow command-line helper that atomically installs a clean Release bundle with an exclusive destination or exchanges staged and installed bundles without removing the canonical app path.
- `Sources/TinyBuddyReleaseVerifier/` contains the read-only command-line verifier used by signed Release workflows to validate the shared snapshot artifact.
- `Widget/TinyBuddyWidget/` contains the WidgetKit extension implementation (single `TinyBuddyWidget.swift` entry point).
- `Tests/TinyBuddyCoreTests/` contains deterministic XCTest coverage for the shared core module (stores, engines, invariants, migration, query, transaction, project exclusion matching, widget lifecycle).
- `Tests/TinyBuddyAppTests/` contains app-target tests for refresh coordination, authorization, repository change monitoring, login item state, HUD window positioning, view model behavior, focus session presentation, widget rendering and timeline self-healing, release workflow hardening, concurrency safety, and fault simulation.
- `Tests/TinyBuddyAppTests/Helpers/` contains reusable test infrastructure: `DeterministicRandom.swift`, `DeterministicScheduler.swift`, `EventTimeline.swift`, `FaultScenario.swift`.
- `Resources/TinyBuddyApp/` and `Resources/TinyBuddyWidget/` contain Info.plist, entitlements, and app/widget resources (including `Assets.xcassets` for app icons).
- `script/build_and_run.sh` is the main local build, launch, install, and verification entry point.
- `script/update_git_completion_count.sh` performs the launch-time Git refresh and writes shared daily-activity data, including content-validated repository fingerprint caching for incremental scans; `script/benchmark_git_refresh.sh` exercises accuracy, incremental latency, resource use, and cancellation against disposable repositories; `script/verify_resource_stability.sh` is the opt-in macOS lifecycle/resource verifier; `script/regression_gate.sh` is the comprehensive performance, energy & stability regression gate (reuses benchmark and resource scripts, adds cold/warm start, Widget reload, and multi-cycle refresh measurements).
- `script/tb-install.sh` is the TinyBuddy-specific build-sign-install-launch script, streamlined for local development. Replaces the older multi-project `script/build-and-install.sh`. It regenerates `TinyBuddy.xcodeproj` from `project.yml` when the project is stale (a `project.yml` or source file is newer than the committed project), so newly added source files are picked up without a manual step.
- `script/local_build_env.sh` sets up isolated SwiftPM module cache and scratch paths for repository wrapper builds.
- `script/process_resource_probe.swift` is a lightweight CLI that samples `proc_pid_rusage(RUSAGE_INFO_V4)` for a given PID and outputs CSV — used by the regression gate.
- `project.yml` is the XcodeGen source of truth for `TinyBuddy.xcodeproj`; regenerate the project after target, bundle, entitlement, or signing changes, and whenever a new source file is added under a path-based `Sources`/`Widget` directory (an already-generated project does not auto-include new files). `script/tb-install.sh` does this automatically when the project is stale.
- `.gitignore` and `.gitleaks.toml` provide repository-level security and secret scanning configuration.
- `docs/superpowers/` contains feature development design docs: `plans/` for design plans and `specs/` for specifications.

## Build, Test, and Development Commands

- `swift build` builds the Swift package targets.
- `swift test` runs both `TinyBuddyCoreTests` and `TinyBuddyAppTests`.
- `./script/swiftpm.sh build` and `./script/swiftpm.sh test` are the repository wrappers when SwiftPM needs isolated module/cache/config paths; they use `.build/spm` and temporary cache roots.
- `swift test --filter 'GitActivity(RefreshScript|RealRepositoryFixture)Tests'` runs the Git script and real-repository regression suites.
- `swift test --filter GitActivityRefreshCoordinatorTests` runs the app-side refresh/outcome tests.
- `/bin/bash -n script/update_git_completion_count.sh` is the narrow syntax check for Git refresh script edits.
- `./script/benchmark_git_refresh.sh` is the repeatable large-repository accuracy, performance, resource, and cancellation gate for Git refresh changes; tune its workload only through the documented `TINYBUDDY_BENCHMARK_*` variables.
- `xcodegen generate` regenerates `TinyBuddy.xcodeproj` from `project.yml` when XcodeGen is installed. `script/tb-install.sh` runs this automatically when the project is older than `project.yml` or any source file, so a fresh source file does not fail the build with `cannot find ... in scope`.
- `./script/build_and_run.sh` builds the Debug app with unsigned local signing, refreshes Git-derived counters when possible, and launches the app.
- `./script/build_and_run.sh --verify` builds and launches the app, verifies startup, and compares the desktop Widget source/hash with the current build when an installed bundle is present.
- `./script/build_and_run.sh --logs` launches the app and streams process logs.
- `./script/build_and_run.sh --telemetry` launches the app and streams subsystem telemetry logs.
- `./script/tb-install.sh` regenerates `TinyBuddy.xcodeproj` from `project.yml` when stale, builds the Debug app, signs the app and Widget with a local Apple Development identity (`SIGN_IDENTITY` overrides selection), backs up and replaces the installed app at `INSTALL_APP` (default `/Applications/TinyBuddy.app`), registers the Widget, and launches the app.
- Release modes default to `TINYBUDDY_SIGNING_MODE=local`: build with signing disabled, select the sole valid Apple Development identity or require an exact `TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY` fingerprint when selection is ambiguous, sign Widget then App, and enforce the source entitlement allowlist plus real runtime verification. This profile-free path preserves the existing App Group only on macOS 14 and is not a distribution/notarization workflow. `TINYBUDDY_SIGNING_MODE=signed` remains an explicit profile-backed option.
- `script/build_and_run.sh` stores full Xcode output under `$TMPDIR/TinyBuddyBuildLogs` by default and returns a concise success or bounded failure summary; set `TINYBUDDY_BUILD_LOG_MODE=verbose` only when the full live build stream is required.
- `./script/build_and_run.sh release-install` builds a signed Release app, stages and verifies it on the installation filesystem, atomically installs it at an empty destination or exchanges it with an existing app while preserving the canonical bundle path and Widget registration, rolls back on failure, then verifies the relaunched app and widget processes use the installed executables. Replacement and rollback relaunches execute the verified installed binary directly so LaunchServices does not rebuild the embedded Widget record; a clean install uses the normal bundle launch after adding its first registration. Only a clean install may add a missing Widget registration; stale, duplicate, or missing registration state on an existing install fails closed without automatic mutation. The default destination is `/Applications/TinyBuddy.app`; `TINYBUDDY_INSTALL_DIR` overrides it. Reuse a successful run as the terminal install gate unless code/build inputs changed or its evidence was incomplete.
- `./script/build_and_run.sh release-verify` verifies the installed signed app matches the current Release build, checks WidgetKit registration, and proves the running app and widget executable paths and hashes come from the installed bundle. It uses the same install-directory override.
- `./script/build_and_run.sh release-acceptance` is the single terminal release gate. It holds a kernel-backed lock on the canonical install target, isolates default signed DerivedData by canonical repository/install target, runs `swift test`, builds and verifies the signed Release candidate, performs the transactional real install plus same-version reinstall, then runs a fresh installed-runtime verification. Parent HUP/INT/TERM waits for active-stage rollback before unlock. Per-stage logs and atomic status records are stored under `$TMPDIR/TinyBuddyReleaseEvidence` by default; only an `overall.status` with `state=passed` plus `release-complete` created after lock cleanup is terminal success evidence.
- `./script/verify_resource_stability.sh --help` documents the optional interactive lifecycle/resource verifier. Its default run is 600 seconds, so use it only when the change or task requires stability evidence.
- There is no separate lint command. Use the compiler, affected tests, shell syntax checks, and `git diff --check` as the relevant static gates.

## Architecture & Coding Conventions

Use the existing Swift style: 4-space indentation, concise types, explicit access control for public APIs, and small focused files. Name types in `UpperCamelCase` and functions, methods, and stored properties in `lowerCamelCase`. Keep shared state, persistence, and business rules in `TinyBuddyCore`; keep app and widget targets thin and presentation-oriented. Prefer extending existing stores and presentation models instead of duplicating state logic across targets.

Keep `project.yml` authoritative for Xcode targets, build settings, resources, entitlements, and signing. When any of those change, update `project.yml` first, regenerate `TinyBuddy.xcodeproj` (including after adding any new source file under a path-based `Sources`/`Widget` dir, which `script/tb-install.sh` now does automatically when stale), and keep the app/widget Info.plist and entitlement files synchronized.

### Focus Session Architecture

The focus session system is split across core and app:
- **Core (`TinyBuddyCore`)**: `FocusSession`, `FocusSessionEngine`, `FocusSessionStore`, `FocusSessionCoordinator`, `FocusSessionRule` (with versioning), `FocusSessionEvidence` / `FocusSessionEvidenceEngine`, `FocusSessionQuery` / `FocusSessionQueryService`, `FocusSessionRecalculation`, `FocusSessionUpgradeCoordinator`, `FocusSessionEditing`, `FocusSessionClock`, `FocusSessionConfiguration`, `FocusProjectExclusionMatcher`, `FocusGoalConfiguration`, `FocusHistoryAggregation`, `PetSession`, `PetStatus`, `TinyBuddyWidgetTimelinePolicy`.
- **App (`TinyBuddy`)**: `FocusSessionAppBridge`, `FocusSessionSnapshotPublicationJournal`, `FocusGoalCoordinator`, `FocusGoalSettingsView`, `FocusHistoryView`, `FocusHistoryListView`, `FocusSessionReviewView`, `ManualFocusMenuBarController`, `ManualFocusProjectPicker`, `FocusNotificationManager`, `ProjectManagementView`, `HistoryQueryController`, `TinyBuddyWidgetReloadCoordinator`, `PetView`, `PetViewModel`.
- Focus sessions use a rule pipeline with mutable evidence and upgrade lifecycle, managed by a transaction coordinator for crash-safe writes.

### Data Integrity & Repair

Core includes a layered data integrity subsystem: `TinyBuddyDataInvariant` (invariant definitions), `TinyBuddyDataValidator` (runtime validation), `TinyBuddyDataRepairEngine` (localized repair), and `TinyBuddyCorruptedRecordQuarantine` (isolation of unrecoverable records). The `TinyBuddyCombinedSnapshotStore` serves as the single source of truth for day state, with `TinyBuddyCombinedSnapshotMigrator` for schema evolution. `TinyBuddyStorageCleanupService` reclaims stale storage without violating invariants, and `TinyBuddyPrivacyRedactor` redacts diagnostics before they leave the process. The history archival flow (`TinyBuddyHistoryArchivalCoordinator`) archives the committed snapshot at launch, on day transition, and at termination; archival writes are atomic and idempotent, and storage cleanup never deletes the current day, active focus sessions, recovery backups, or referenced data.

### Time Model

Time handling is centralized through `TinyBuddyTimeCalibrator` (system time sanity, DST transition detection) and `TinyBuddyTimeContinuityRecord` (cross-process clock continuity). `TinyBuddyTimeEnvironment` provides the authoritative local-day boundary for all snapshot, focus, and Git activity attribution.

### Focus Session Invariants

- A focus session is identified by its stable `ProjectIdentity` and a time range. Sessions are non-overlapping per project; overlapping ranges are resolved by the coordinator during start/end transitions.
- Focus evidence is derived from session properties (start/end time, project, display representation) rather than hardcoded defaults. The evidence pipeline supports custom rules with versioned schemas.
- The `FocusSessionRecalculation` engine can re-derive all focus blocks for a given day when rules or evidence sources change, preserving idempotent results.
- Focus goals are configured per project/day via `FocusGoalConfiguration`; daily goal progress is aggregated through `FocusHistoryAggregation`.
- Manual focus control (menu bar) and automatic refresh coordination share the same session engine and store; the `ManualFocusMenuBarController` provides user-initiated start/end with project selection.
- A manual session can be paused without terminating; paused sessions stop time accumulation and surface their paused state in HUD and Widget presentation.
- The Widget self-schedules its own timeline refresh while a session is live (`TinyBuddyWidgetTimelinePolicy`); periodic live-minute re-emissions advance the authoritative snapshot for HUD and persistence but deliberately skip the WidgetKit reload, and reloads are funneled through `TinyBuddyWidgetReloadCoordinator` so committed transitions republish exactly once across surfaces.
- Focus reminder gating derives a single notification permission state (notDetermined/authorized/alertsDisabled/denied) from both the authorization status and alert setting; while undeliverable, the engine suppresses new reminders but keeps their gates open so still-valid reminders are recalculated once permission returns.
- Automatic focus attribution is suppressed when the final candidate project's surviving canonical repository paths are covered by an active exclusion rule (`FocusProjectExclusionMatcher`, case-insensitive path matching over the repo's canonical aliases). Evaluating the gate on the attribution candidate — not at discovery time — lets the latest rules take effect immediately and prevents a stale async scan result from reviving automatic focus for an excluded repository. Foreground-app (bundle-ID) contexts carry no canonical path and are never excluded; a repo whose excluded alias no longer exists on disk (moved) is not excluded at its current location.
- Pet status (`PetViewModel`, `PetSession`) derives focus state and completion activity from the combined snapshot for HUD display.

## Git Activity & Snapshot Invariants

- Identify a logical repository by its canonical common Git directory. A normal checkout, linked worktree, symlinked scan root, or repeated scan path must not duplicate repository or event counts.
- Derive completion activity from logical reflog events. Count commits, detached-HEAD commits, cherry-picks, reverts, and true merges (a "Merge made" commit); an amend replaces its prior event; rebase maps rewritten OIDs across worktrees without creating another completion; checkout, reset, branch deletion, and rewrite control records do not create completions. Identical logical commit events are deduplicated across scanned repositories so copied or backed-up checkouts of the same canonical common Git directory count once, and an amend still replaces the single surviving completion even when its prior commit was collapsed as a cross-repository duplicate.
- Use one local-day boundary for completion, focus, and recent-project attribution. Focus is the global set of occupied 30-minute blocks. Latest epoch wins for the recent project; equal epochs use canonical repository identity as the deterministic tie-break.
- Exclude dependency/build/cache components, automated author or committer identities, and bounded duplicate reflog events before publishing activity.
- Publish valid repositories when another repository or worktree fails. `partial` preserves successful results; `failed`, `skipped`, and unknown outcomes must not overwrite a previously committed snapshot with zero or stale data.
- Keep trusted/shared snapshot writes atomic and revision-monotonic. Cache hits (including repository fingerprint caches) must be content-validated, cache hits must not renew their own expiry, and malformed or stale cache data must trigger bounded recomputation.
- Treat the current-schema committed combined snapshot as the authoritative presentation input. HUD, Widget, telemetry, and Release verification must agree on its schema, revision, and local day; do not reintroduce independent legacy-key reads or parallel presentation derivation.
- Diagnostics must use stable redacted candidate identifiers. If the script gains an external command, update its documented runtime dependency boundary and tests for indirect dependencies.
- `GitCommandExecutor` enforces read-only at the invocation level, not just the subcommand name: nominally read-oriented Git commands with mutating forms (`config <name> <value>`, `symbolic-ref --delete`, `reflog expire`, `multi-pack-index write`, ...) are rejected when `readOnly` is set, and output capture enforces a real wall-clock timeout with a combined bounded stdout/stderr budget and a bounded cancellation escalation (SIGTERM then SIGKILL).

### Refresh Coordination

The `GitActivityRefreshCoordinator` serializes manual, timer, wake, repository-change, authorization, and configuration-triggered refreshes so the UI only ever shows the current valid task and its result:

- Repeated manual clicks during an in-flight refresh coalesce into a single queued follow-up request; after that follow-up completes no further refresh runs from the same click burst. A queued manual request carries explicit user intent, so it still runs after the in-flight refresh completes even if the app resigned active in the meantime; queued wake and repository-change requests are opportunistic and are dropped while the app is inactive.
- Authorization and configuration changes cancel the in-flight execution, clear queued manual/repository-change requests (the replacement refresh they start already fulfills that intent with current inputs), and immediately start a replacement scan; time-environment invalidation clears queued requests the same way.
- Sleep cancels an in-flight refresh and publishes a terminal status change without a new status object, so consumers clear their in-flight marker and fall back to the last trusted status instead of staying stuck on "refreshing"; the post-wake (or foreground-activation) refresh republishes real state. A cancelled execution must never publish a result, clear, or overwrite a newer task's state — execution identity plus lifecycle generation gate every completion.
- Failure keeps the last trusted snapshot intact and records an accurate retryable diagnostic (script lookup/authorization/execution/snapshot load/combined-snapshot commit reasons), with failure backoff bounded by the cadence; `success`/`partial`/`failed`/`skipped` are stable and `failed` must not overwrite committed data with zero or stale results.
- Each saved Git scan-root directory has its own availability status with reauthorize/remove actions: a moved or stale bookmark is refreshed in place when macOS can resolve it, and an unavailable, unmounted, revoked, or corrupt entry is paused without discarding activity from the other valid directories. Release verification of an install with saved authorizations requires a fresh successful or partial refresh from the installed app and reports only sanitized counts and status.
- The expected local-day identifier for an activity commit is captured on the main thread and passed down to the refresh queue work; the commit path must never read the coordinator's mutable `activeTimeContext` from the background queue. A successful refresh also cancels any recovery retries that were already scheduled by a prior failure, so a queued retry cannot consume the reset budget or mark directory recovery as permanently exhausted.

## Testing & Definition of Done

Tests use XCTest. Add core coverage under `Tests/TinyBuddyCoreTests/` and app-facing coverage under `Tests/TinyBuddyAppTests/`. Name files with the `Tests.swift` suffix and test methods with the `test` prefix. Prefer deterministic dependencies such as isolated `UserDefaults`, fixed calendars, fixed dates, and stubbed process/script inputs. Reusable test helpers (`DeterministicRandom`, `DeterministicScheduler`, `EventTimeline`, `FaultScenario`) live in `Tests/TinyBuddyAppTests/Helpers/`. Run `swift test` before submitting changes that affect shared logic, app behavior, Git refresh flow, focus session engine, data repair, or widget presentation. If you change build, signing, widget, or launch behavior, also run the smallest relevant `./script/build_and_run.sh` verification mode.

- Start with the narrowest affected test or syntax check, then run `swift test` once after the implementation is stable when shared logic, app behavior, Git refresh, focus session, data integrity, or widget presentation changed.
- Git, snapshot, bookmark, sandbox, or widget-data changes must cover atomic recovery, mixed valid/invalid repositories or worktrees, stable `success`/`partial`/`failed`/`skipped` behavior, redacted diagnostics, and permission boundaries when applicable.
- Git refresh performance, timeout, cache, enumeration, or cancellation changes should also run `./script/benchmark_git_refresh.sh`; report the configured workload when it differs from the script defaults.
- Focus session, transaction log, data repair, time calibration, or combined snapshot changes should run the relevant core and app tests, and also consider `script/regression_gate.sh --quick` for broader regression coverage.
- Use real Git fixtures for behavior that depends on reflog ordering, object rewriting, common-dir identity, worktrees, or filesystem aliases; do not replace those cases with only synthetic reflog text.
- Build/signing/widget/launch changes require the smallest relevant `build_and_run.sh` mode. `release-install` requires explicit authorization because it replaces an installed app bundle; after it succeeds, reuse it as terminal install evidence and rerun `release-verify` only after an invalidating change or when evidence was incomplete.
- A successful `release-acceptance` supersedes separate `swift test`, `release-install`, and `release-verify` runs for the same unchanged inputs. Do not report release acceptance from a lower-level stage, a run without `release-complete`, or a run whose evidence directory contains a failed or missing stage.
- Before completion, inspect the focused diff and `git status`, run `git diff --check`, and report only commands actually executed plus any unverified risk.

## Review guidelines

- Treat regressions in shared snapshot integrity, Git partial-success behavior, sandbox/bookmark access, signing/entitlements, installed Widget source verification, focus session consistency, or data repair safety as blocking findings.
- Check app and widget consumers against the same `TinyBuddyCore` state and day semantics; flag duplicated business rules or independent persistence paths.
- For Git activity changes, verify canonical common-dir identity, rewrite/amend replacement, cross-repository deduplication, deterministic recent-project ordering, global focus-block deduplication, noise filtering, fingerprint-cache content validation and invalidation, and preservation of valid repositories on partial failure.
- For focus session changes, verify session non-overlap, evidence attribution from session properties, rule versioning compatibility, recalculation idempotency, and coordinator crash safety.
- For data integrity changes, verify invariant definitions match actual store constraints, repair engine preserves valid records, and quarantine isolates unrecoverable state without data loss.
- Reject diagnostics that expose repository paths, user data, credentials, or unstable raw identifiers. Confirm new shell commands and their indirect dependencies are allowed by the signed runtime boundary.
- Require relevant regression coverage and exact validation evidence. Do not accept weakened assertions, hidden failures, or an unrelated refactor bundled with the fix.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, matching the existing history style, such as `Verify release signing and widget registration`, `Add daily stats widget state`, or `Fix session persistence reset`. Pull requests should describe the user-visible behavior change, list the exact validation performed, note any signing or widget-specific verification, link related issues when available, and include screenshots only when the change is meaningfully visual.

## Security & Configuration Tips

Do not commit local secrets, certificates, provisioning assets, `.env` files, private repository paths, or unredacted diagnostics. Keep bundle identifiers, app groups, entitlements, and Info.plist settings synchronized across `project.yml`, `Resources/`, and release verification logic. Signed release flows depend on local Apple signing configuration; do not change signing identifiers, app group names, installation paths, or `/Applications` state unless the task explicitly requires it and the external write is authorized.
