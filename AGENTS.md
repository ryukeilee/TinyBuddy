# Repository Guidelines

## Project Structure & Module Organization

TinyBuddy is a Swift 5.9 macOS 14 project with both Swift Package Manager and Xcode project entry points.

- `Sources/TinyBuddyCore/` contains shared domain logic, daily stats persistence, Git activity stores, and widget presentation models.
- `Sources/TinyBuddy/` contains the macOS SwiftUI HUD app, authorization flow, refresh coordination, and app lifecycle wiring.
- `Widget/TinyBuddyWidget/` contains the WidgetKit extension implementation.
- `Tests/TinyBuddyCoreTests/` contains deterministic XCTest coverage for the shared core module.
- `Tests/TinyBuddyAppTests/` contains app-target tests for refresh coordination, authorization, scripts, and view model behavior.
- `Resources/TinyBuddyApp/` and `Resources/TinyBuddyWidget/` contain Info.plist, entitlements, and app/widget resources.
- `script/build_and_run.sh` is the main local build, launch, install, and verification entry point.
- `script/update_git_completion_count.sh` performs the launch-time Git refresh and writes shared daily-activity data; `script/verify_resource_stability.sh` is the opt-in macOS lifecycle/resource verifier.
- `project.yml` is the XcodeGen source of truth for `TinyBuddy.xcodeproj`; regenerate the project after target, bundle, entitlement, or signing changes.

## Build, Test, and Development Commands

- `swift build` builds the Swift package targets.
- `swift test` runs both `TinyBuddyCoreTests` and `TinyBuddyAppTests`.
- `xcodegen generate` regenerates `TinyBuddy.xcodeproj` from `project.yml` when XcodeGen is installed.
- `./script/build_and_run.sh` builds the Debug app with unsigned local signing, refreshes Git-derived counters when possible, and launches the app.
- `./script/build_and_run.sh --verify` builds and launches the app, then verifies the process starts and the widget runtime matches the current build.
- `./script/build_and_run.sh --logs` launches the app and streams process logs.
- `./script/build_and_run.sh --telemetry` launches the app and streams subsystem telemetry logs.
- `TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh` builds with automatic provisioning updates when signed builds are required.
- `script/build_and_run.sh` stores full Xcode output under `$TMPDIR/TinyBuddyBuildLogs` by default and returns a concise success or bounded failure summary; set `TINYBUDDY_BUILD_LOG_MODE=verbose` only when the full live build stream is required.
- `./script/build_and_run.sh release-install` builds a signed Release app, stages and verifies it on the installation filesystem, atomically replaces `/Applications/TinyBuddy.app` with rollback on failure, then verifies the relaunched app and widget processes use the installed executables. A successful run is the terminal install gate; do not immediately repeat `release-verify` unless code or build inputs changed or its evidence was incomplete.
- `./script/build_and_run.sh release-verify` verifies the installed signed app matches the current Release build, checks WidgetKit registration, and proves the running app and widget executable paths and hashes come from the installed bundle.
- `./script/verify_resource_stability.sh --help` documents the optional resource-stability check and its local environment overrides.

## Coding Style & Naming Conventions

Use the existing Swift style: 4-space indentation, concise types, explicit access control for public APIs, and small focused files. Name types in `UpperCamelCase` and functions, methods, and stored properties in `lowerCamelCase`. Keep shared state, persistence, and business rules in `TinyBuddyCore`; keep app and widget targets thin and presentation-oriented. Prefer extending existing stores and presentation models instead of duplicating state logic across targets.

## Testing Guidelines

Tests use XCTest. Add core coverage under `Tests/TinyBuddyCoreTests/` and app-facing coverage under `Tests/TinyBuddyAppTests/`. Name files with the `Tests.swift` suffix and test methods with the `test` prefix. Prefer deterministic dependencies such as isolated `UserDefaults`, fixed calendars, fixed dates, and stubbed process/script inputs. Run `swift test` before submitting changes that affect shared logic, app behavior, Git refresh flow, or widget presentation. If you change build, signing, widget, or launch behavior, also run the smallest relevant `./script/build_and_run.sh` verification mode.

### Stability Acceptance Contract

For changes to Git, snapshots, bookmarks, sandbox access, or widget data flow, the initial worker task packet must include every applicable item below rather than expanding the contract during review:

- atomic snapshot writes and recovery; partial-success behavior when valid repositories are mixed with invalid repositories or worktrees; stable contracts for successful, `failed`, and `skipped` states
- stable, redacted identifiers for diagnostic candidates; external commands and their indirect runtime dependencies, not only the visible executable; a final verification matrix covering installed and Release builds, the widget, and permission boundaries

Treat these as durable semantics and verification entry points. Select the smallest project command that proves each applicable item, then run the final matrix only after the implementation is stable. Do not encode current bug details, temporary test names, or one-off commands in this contract.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, matching the existing history style, such as `Verify release signing and widget registration`, `Add daily stats widget state`, or `Fix session persistence reset`. Pull requests should describe the user-visible behavior change, list the exact validation performed, note any signing or widget-specific verification, link related issues when available, and include screenshots only when the change is meaningfully visual.

## Security & Configuration Tips

Do not commit local secrets, certificates, provisioning assets, or `.env` files. Keep bundle identifiers, app groups, entitlements, and Info.plist settings synchronized across `project.yml`, `Resources/`, and release verification logic. Signed release flows depend on local Apple signing configuration; do not change signing identifiers, app group names, or installation paths unless the task explicitly requires it.
