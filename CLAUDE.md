# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

TinyBuddy is a macOS 14 companion HUD (SwiftUI + WidgetKit) that combines a floating desktop pet, shared daily Git-activity stats, and a focus-session engine so the app and a desktop Widget present the same lightweight productivity state. It is built with SwiftPM (`swift-tools-version: 6.0`, `swiftLanguageMode(.v6)`), an XcodeGen source of truth (`project.yml` → `TinyBuddy.xcodeproj`), and Bash release/refresh scripts.

`AGENTS.md` in the repo root is the exhaustive reference for conventions, review guidelines, and definitions of done. Read it before submitting changes; this file is the fast operating summary.

## Commands

```bash
swift build                          # build the Swift package targets
swift test                           # run TinyBuddyCoreTests + TinyBuddyAppTests
swift test --filter <TestClass>      # run one test class
swift test --filter <TestClass>/<testMethod>   # run one test method
./script/swiftpm.sh build|test       # wrappers with isolated module/cache/scratch paths (.build/spm)
xcodegen generate                    # regenerate TinyBuddy.xcodeproj from project.yml
```

There is no lint command. Static gates are the compiler, affected tests, `/bin/bash -n script/update_git_completion_count.sh` for Git-refresh script edits, and `git diff --check`.

### App / verification entry points

- `./script/tb-install.sh` — regenerates the Xcode project automatically when `project.yml` or a source file is newer, then builds, signs, installs to `/Applications/TinyBuddy.app`, registers the Widget, and launches. Prefer this for day-to-day local runs.
- `./script/build_and_run.sh` — Debug build + launch (unsigned); flags: `--verify` (app startup + Widget source/hash consistency), `--logs`, `--telemetry`.
- `./script/build_and_run.sh release-install` — signed Release build, transactional install/swap preserving the canonical app path and Widget registration.
- `./script/build_and_run.sh release-verify` — verifies the installed signed app and Widget registration from a fresh process state.
- `./script/build_and_run.sh release-acceptance` — the single terminal release gate: full `swift test`, signed Release build, real install + same-version reinstall, then fresh runtime verification. A passing run supersedes lower-level test/install/verify evidence.
- `./script/benchmark_git_refresh.sh` — repeatable Git-refresh accuracy/perf/resource/cancellation gate.
- `./script/regression_gate.sh --quick` — broader performance/energy/stability regression sweep.

Release modes default to `TINYBUDDY_SIGNING_MODE=local` (profile-free Apple Development signing of the checked-in entitlements, macOS 14 only). Full signing workflow details are in `README.md`.

## Architecture

Three processes cooperate through the App Group `group.com.ryukeili.TinyBuddy`:

- **`script/update_git_completion_count.sh`** — a Bash scanner (the app's only Git reader) that parses reflogs across authorized scan roots and writes raw per-day counters into the app-group preferences plist.
- **`TinyBuddy` (app)** — owns all state. `GitActivityRefreshCoordinator` validates the script's output and commits it; `TinyBuddyCombinedSnapshotStore` is the single source of truth for what HUD, Widget, telemetry, and release verification all consume.
- **`TinyBuddyWidgetExtension`** — read-only WidgetKit consumer of the combined snapshot (`repairOnLoad: false`); it never writes.

### The combined snapshot is the heart

`TinyBuddyCombinedSnapshotStore` (`Sources/TinyBuddyCore/TinyBuddyCombinedSnapshotStore.swift`) merges the pet slice (`DailyStatsStore`), the Git-activity slice, and the focus-history slice into one revision-monotonic, schema-versioned payload:

- Schema v1 = legacy tab-separated text; v2 = checksummed envelope; v3 = checksummed binary-plist envelope. New writers emit V3 and keep V2/V1 mirrors for older readers. Unknown/future envelope versions fail closed as `.versionIncompatible`.
- Writes are transactional: a two-slot A/B arrangement stages the payload, then commits an independently checksummed `committedRevision` marker. Readers never accept a revision newer than the committed marker, so a crash between writes cannot expose torn state.
- `TinyBuddyInstanceCoordinator` (flock in the App Group container) enforces a single primary instance; only the primary may write.
- HUD and Widget derive presentation from the same committed snapshot — never reintroduce independent legacy-key reads or parallel derivation.

### Time model

`TinyBuddyTimeEnvironment` is the authoritative local-day boundary for all snapshot, focus, and Git-activity attribution. `TinyBuddyTimeCalibrator` detects clock/DST/day changes and advances `TinyBuddyTimeContinuityRecord`, which cross-process readers (including the Widget) use to notice recalibration.

### Module responsibilities

- **`Sources/TinyBuddyCore/`** — all shared logic: stores, focus-session engine/coordinator/rules/evidence/editing, Git activity stores, project identity registry, combined snapshot store + migrator, data integrity (invariants/validator/repair/quarantine), storage cleanup, time model, widget presentation models, privacy redactor, diagnostics.
- **`Sources/TinyBuddy/`** — thin SwiftUI HUD + lifecycle wiring: `AppDelegate` coordinates Git refresh, focus session bridge, history archival, login item, reset, HUD window positioning. No business rules live here.
- **`Sources/TinyBuddyReleaseInstaller/`** / **`Sources/TinyBuddyReleaseVerifier/`** — narrow CLI helpers for the signed release workflow.
- **`Widget/TinyBuddyWidget/TinyBuddyWidget.swift`** — the single widget entry point.

### Focus sessions

`FocusSessionEngine` (core) is the lifecycle authority; sessions are non-overlapping per project, identified by `ProjectIdentity` + time range. The app's `FocusSessionAppBridge` publishes derived aggregates (`FocusHistoryPublication`) into the combined snapshot so HUD, Widget, and history views read one authoritative payload. Manual menu-bar control and automatic Git-activity attribution share the same engine/store.

## Conventions

- Swift 6 language mode is enforced per-target; app code is `@MainActor`-centric. Use 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` functions/properties, explicit access control.
- Keep shared state, persistence, and business rules in `TinyBuddyCore`; keep app and Widget targets thin and presentation-oriented. Extend existing stores instead of duplicating state logic.
- `project.yml` is authoritative for targets, entitlements, signing, and Info.plist properties. Update it first (then `xcodegen generate`) after target/entitlement/signing changes or when adding a new source file under a path-based `Sources`/`Widget` directory — an already-generated project does not auto-include new files. `script/tb-install.sh` does this automatically when stale.
- Keep bundle identifiers, App Group, entitlements, and Info.plist values aligned across `project.yml`, `Resources/`, and the verification scripts.
- Diagnostics must be redacted: never emit repository paths, project names, credentials, or unstable raw identifiers.
- Tests use XCTest under `Tests/TinyBuddyCoreTests/` (deterministic core) and `Tests/TinyBuddyAppTests/` (app behavior, using `Helpers/` `DeterministicRandom`, `DeterministicScheduler`, `EventTimeline`, `FaultScenario`). Use real Git fixtures for reflog-order/worktree/common-dir behavior.
