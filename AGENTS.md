# Repository Guidelines

## Project Structure & Module Organization

TinyBuddy is a Swift 5.9 macOS 14 project with both Swift Package Manager and Xcode project entry points.

- `Sources/TinyBuddyCore/` contains shared domain logic, persistence, stats, status, and widget presentation data.
- `Sources/TinyBuddy/` contains the macOS SwiftUI app and view model.
- `Widget/TinyBuddyWidget/` contains the WidgetKit extension.
- `Tests/TinyBuddyCoreTests/` contains XCTest coverage for the core module.
- `Resources/TinyBuddyApp/` and `Resources/TinyBuddyWidget/` hold Info.plist and entitlement files.
- `project.yml` is the XcodeGen source of truth for the `.xcodeproj`; regenerate the project after target or signing changes.

## Build, Test, and Development Commands

- `swift build` builds the Swift package targets.
- `swift test` runs the core XCTest suite.
- `xcodegen generate` regenerates `TinyBuddy.xcodeproj` from `project.yml` when XcodeGen is installed.
- `./script/build_and_run.sh` builds the macOS app with unsigned local signing and launches it.
- `./script/build_and_run.sh --verify` builds, launches, and verifies the app process starts.
- `./script/build_and_run.sh release-install` builds a signed Release app, installs it to `/Applications`, and registers the widget extension.
- `./script/build_and_run.sh release-verify` verifies the installed app, code signature, and WidgetKit extension registration.
- `TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh` builds with automatic provisioning updates when signing is required.

## Coding Style & Naming Conventions

Use the existing Swift style: 4-space indentation, concise types, explicit access control for public APIs, and small focused files. Name types in `UpperCamelCase` (`PetSession`, `DailyStatsStore`) and functions/properties in `lowerCamelCase` (`recordCompletion`, `focusCount`). Keep shared business logic in `TinyBuddyCore`; avoid duplicating state logic in the app or widget targets.

## Testing Guidelines

Tests use XCTest and currently focus on `TinyBuddyCore`. Add tests under `Tests/TinyBuddyCoreTests/` with file names ending in `Tests.swift` and test methods starting with `test`. Prefer deterministic dependencies, as existing tests do with isolated `UserDefaults`, fixed calendars, and fixed dates. Run `swift test` before submitting changes that touch core behavior.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, matching the current history style, such as `Verify release signing and widget registration`, `Add daily stats widget state`, or `Fix session persistence reset`. Pull requests should describe the user-visible change, list validation performed, link related issues when available, and include screenshots or screen recordings for app or widget UI changes.

## Security & Configuration Tips

Do not commit local secrets, certificates, provisioning assets, or `.env` files. Keep app group and bundle identifier changes synchronized across `project.yml`, entitlements, and Info.plist resources.
