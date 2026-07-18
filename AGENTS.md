# TinyBuddy Repository Guidance

## Project Structure & Module Organization

TinyBuddy is a Swift 5.9 macOS 14 project with both Swift Package Manager and Xcode project entry points.

- `Sources/TinyBuddyCore/` contains shared domain logic, daily stats persistence, Git activity stores, and widget presentation models.
- `Sources/TinyBuddy/` contains the macOS SwiftUI HUD app, authorization flow, refresh coordination, and app lifecycle wiring.
- `Sources/TinyBuddyReleaseVerifier/` contains the read-only command-line verifier used by signed Release workflows to validate the shared snapshot artifact.
- `Widget/TinyBuddyWidget/` contains the WidgetKit extension implementation.
- `Tests/TinyBuddyCoreTests/` contains deterministic XCTest coverage for the shared core module.
- `Tests/TinyBuddyAppTests/` contains app-target tests for refresh coordination, authorization, scripts, and view model behavior.
- `Tests/TinyBuddyAppTests/GitActivityRealRepositoryFixtureTests.swift` owns real Git regression coverage for worktrees, rewrites, duplicate roots, day boundaries, filtering, and partial failures.
- `Resources/TinyBuddyApp/` and `Resources/TinyBuddyWidget/` contain Info.plist, entitlements, and app/widget resources.
- `script/build_and_run.sh` is the main local build, launch, install, and verification entry point.
- `script/update_git_completion_count.sh` performs the launch-time Git refresh and writes shared daily-activity data; `script/benchmark_git_refresh.sh` exercises accuracy, incremental latency, resource use, and cancellation against disposable repositories; `script/verify_resource_stability.sh` is the opt-in macOS lifecycle/resource verifier.
- `project.yml` is the XcodeGen source of truth for `TinyBuddy.xcodeproj`; regenerate the project after target, bundle, entitlement, or signing changes.

## Build, Test, and Development Commands

- `swift build` builds the Swift package targets.
- `swift test` runs both `TinyBuddyCoreTests` and `TinyBuddyAppTests`.
- `./script/swiftpm.sh build` and `./script/swiftpm.sh test` are the repository wrappers when SwiftPM needs isolated module/cache/config paths; they use `.build/spm` and temporary cache roots.
- `swift test --filter 'GitActivity(RefreshScript|RealRepositoryFixture)Tests'` runs the Git script and real-repository regression suites.
- `swift test --filter GitActivityRefreshCoordinatorTests` runs the app-side refresh/outcome tests.
- `/bin/bash -n script/update_git_completion_count.sh` is the narrow syntax check for Git refresh script edits.
- `./script/benchmark_git_refresh.sh` is the repeatable large-repository accuracy, performance, resource, and cancellation gate for Git refresh changes; tune its workload only through the documented `TINYBUDDY_BENCHMARK_*` variables.
- `xcodegen generate` regenerates `TinyBuddy.xcodeproj` from `project.yml` when XcodeGen is installed.
- `./script/build_and_run.sh` builds the Debug app with unsigned local signing, refreshes Git-derived counters when possible, and launches the app.
- `./script/build_and_run.sh --verify` builds and launches the app, verifies startup, and compares the desktop Widget source/hash with the current build when an installed bundle is present.
- `./script/build_and_run.sh --logs` launches the app and streams process logs.
- `./script/build_and_run.sh --telemetry` launches the app and streams subsystem telemetry logs.
- Release modes default to `TINYBUDDY_SIGNING_MODE=local`: build with signing disabled, select the sole valid Apple Development identity or require an exact `TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY` fingerprint when selection is ambiguous, sign Widget then App, and enforce the source entitlement allowlist plus real runtime verification. This profile-free path preserves the existing App Group only on macOS 14 and is not a distribution/notarization workflow. `TINYBUDDY_SIGNING_MODE=signed` remains an explicit profile-backed option.
- `script/build_and_run.sh` stores full Xcode output under `$TMPDIR/TinyBuddyBuildLogs` by default and returns a concise success or bounded failure summary; set `TINYBUDDY_BUILD_LOG_MODE=verbose` only when the full live build stream is required.
- `./script/build_and_run.sh release-install` builds a signed Release app, stages and verifies it on the installation filesystem, atomically replaces the installed app with rollback on failure, then verifies the relaunched app and widget processes use the installed executables. The default destination is `/Applications/TinyBuddy.app`; `TINYBUDDY_INSTALL_DIR` overrides it. Reuse a successful run as the terminal install gate unless code/build inputs changed or its evidence was incomplete.
- `./script/build_and_run.sh release-verify` verifies the installed signed app matches the current Release build, checks WidgetKit registration, and proves the running app and widget executable paths and hashes come from the installed bundle. It uses the same install-directory override.
- `./script/build_and_run.sh release-acceptance` is the single terminal release gate. It holds a kernel-backed lock on the canonical install target, isolates default signed DerivedData by canonical repository/install target, runs `swift test`, builds and verifies the signed Release candidate, performs the transactional real install plus same-version reinstall, then runs a fresh installed-runtime verification. Parent HUP/INT/TERM waits for active-stage rollback before unlock. Per-stage logs and atomic status records are stored under `$TMPDIR/TinyBuddyReleaseEvidence` by default; only an `overall.status` with `state=passed` plus `release-complete` created after lock cleanup is terminal success evidence.
- `./script/verify_resource_stability.sh --help` documents the optional interactive lifecycle/resource verifier. Its default run is 600 seconds, so use it only when the change or task requires stability evidence.
- There is no separate lint command. Use the compiler, affected tests, shell syntax checks, and `git diff --check` as the relevant static gates.

## Architecture & Coding Conventions

Use the existing Swift style: 4-space indentation, concise types, explicit access control for public APIs, and small focused files. Name types in `UpperCamelCase` and functions, methods, and stored properties in `lowerCamelCase`. Keep shared state, persistence, and business rules in `TinyBuddyCore`; keep app and widget targets thin and presentation-oriented. Prefer extending existing stores and presentation models instead of duplicating state logic across targets.

Keep `project.yml` authoritative for Xcode targets, build settings, resources, entitlements, and signing. When any of those change, update `project.yml` first, regenerate `TinyBuddy.xcodeproj`, and keep the app/widget Info.plist and entitlement files synchronized.

## Git Activity & Snapshot Invariants

- Identify a logical repository by its canonical common Git directory. A normal checkout, linked worktree, symlinked scan root, or repeated scan path must not duplicate repository or event counts.
- Derive completion activity from logical reflog events. Count commits, detached-HEAD commits, and merges; an amend replaces its prior event; rebase maps rewritten OIDs across worktrees without creating another completion; checkout, reset, branch deletion, and rewrite control records do not create completions.
- Use one local-day boundary for completion, focus, and recent-project attribution. Focus is the global set of occupied 30-minute blocks. Latest epoch wins for the recent project; equal epochs use canonical repository identity as the deterministic tie-break.
- Exclude dependency/build/cache components, automated author or committer identities, and bounded duplicate reflog events before publishing activity.
- Publish valid repositories when another repository or worktree fails. `partial` preserves successful results; `failed`, `skipped`, and unknown outcomes must not overwrite a previously committed snapshot with zero or stale data.
- Keep trusted/shared snapshot writes atomic and revision-monotonic. Cache hits must be content-validated, repository-list cache hits must not renew their own expiry, and malformed or stale cache data must trigger bounded recomputation.
- Treat the current-schema committed combined snapshot as the authoritative presentation input. HUD, Widget, telemetry, and Release verification must agree on its schema, revision, and local day; do not reintroduce independent legacy-key reads or parallel presentation derivation.
- Diagnostics must use stable redacted candidate identifiers. If the script gains an external command, update its documented runtime dependency boundary and tests for indirect dependencies.

## Testing & Definition of Done

Tests use XCTest. Add core coverage under `Tests/TinyBuddyCoreTests/` and app-facing coverage under `Tests/TinyBuddyAppTests/`. Name files with the `Tests.swift` suffix and test methods with the `test` prefix. Prefer deterministic dependencies such as isolated `UserDefaults`, fixed calendars, fixed dates, and stubbed process/script inputs. Run `swift test` before submitting changes that affect shared logic, app behavior, Git refresh flow, or widget presentation. If you change build, signing, widget, or launch behavior, also run the smallest relevant `./script/build_and_run.sh` verification mode.

- Start with the narrowest affected test or syntax check, then run `swift test` once after the implementation is stable when shared logic, app behavior, Git refresh, or widget presentation changed.
- Git, snapshot, bookmark, sandbox, or widget-data changes must cover atomic recovery, mixed valid/invalid repositories or worktrees, stable `success`/`partial`/`failed`/`skipped` behavior, redacted diagnostics, and permission boundaries when applicable.
- Git refresh performance, timeout, cache, enumeration, or cancellation changes should also run `./script/benchmark_git_refresh.sh`; report the configured workload when it differs from the script defaults.
- Use real Git fixtures for behavior that depends on reflog ordering, object rewriting, common-dir identity, worktrees, or filesystem aliases; do not replace those cases with only synthetic reflog text.
- Build/signing/widget/launch changes require the smallest relevant `build_and_run.sh` mode. `release-install` requires explicit authorization because it replaces an installed app bundle; after it succeeds, reuse it as terminal install evidence and rerun `release-verify` only after an invalidating change or when evidence was incomplete.
- A successful `release-acceptance` supersedes separate `swift test`, `release-install`, and `release-verify` runs for the same unchanged inputs. Do not report release acceptance from a lower-level stage, a run without `release-complete`, or a run whose evidence directory contains a failed or missing stage.
- Before completion, inspect the focused diff and `git status`, run `git diff --check`, and report only commands actually executed plus any unverified risk.

## Review guidelines

- Treat regressions in shared snapshot integrity, Git partial-success behavior, sandbox/bookmark access, signing/entitlements, or installed Widget source verification as blocking findings.
- Check app and widget consumers against the same `TinyBuddyCore` state and day semantics; flag duplicated business rules or independent persistence paths.
- For Git activity changes, verify canonical common-dir identity, rewrite/amend replacement, deterministic recent-project ordering, global focus-block deduplication, noise filtering, cache invalidation, and preservation of valid repositories on partial failure.
- Reject diagnostics that expose repository paths, user data, credentials, or unstable raw identifiers. Confirm new shell commands and their indirect dependencies are allowed by the signed runtime boundary.
- Require relevant regression coverage and exact validation evidence. Do not accept weakened assertions, hidden failures, or an unrelated refactor bundled with the fix.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, matching the existing history style, such as `Verify release signing and widget registration`, `Add daily stats widget state`, or `Fix session persistence reset`. Pull requests should describe the user-visible behavior change, list the exact validation performed, note any signing or widget-specific verification, link related issues when available, and include screenshots only when the change is meaningfully visual.

## Security & Configuration Tips

Do not commit local secrets, certificates, provisioning assets, `.env` files, private repository paths, or unredacted diagnostics. Keep bundle identifiers, app groups, entitlements, and Info.plist settings synchronized across `project.yml`, `Resources/`, and release verification logic. Signed release flows depend on local Apple signing configuration; do not change signing identifiers, app group names, installation paths, or `/Applications` state unless the task explicitly requires it and the external write is authorized.
