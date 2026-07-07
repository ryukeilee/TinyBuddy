# TinyBuddy

TinyBuddy is a macOS 14 companion HUD built with SwiftUI, Swift Package Manager, and WidgetKit. It combines a floating desktop companion, shared daily stats, and Git activity refresh logic so the app and widget can present the same lightweight productivity state.

## What It Includes

- A floating macOS HUD app in `Sources/TinyBuddy/`
- Shared domain and persistence logic in `Sources/TinyBuddyCore/`
- A WidgetKit extension in `Widget/TinyBuddyWidget/`
- Local scripts for build, launch, install, and verification in `script/`

## Requirements

- macOS 14 or later
- Xcode with Swift 5.9 toolchain
- Optional: `xcodegen` to regenerate `TinyBuddy.xcodeproj` from `project.yml`
- Apple signing configured locally if you need signed Release install and widget registration flows

## Project Layout

```text
Sources/
  TinyBuddy/             macOS app target
  TinyBuddyCore/         shared logic, persistence, widget presentation data
Widget/
  TinyBuddyWidget/       WidgetKit extension
Tests/
  TinyBuddyCoreTests/    core module tests
  TinyBuddyAppTests/     app-target tests
Resources/
  TinyBuddyApp/          app Info.plist and entitlements
  TinyBuddyWidget/       widget Info.plist and entitlements
script/
  build_and_run.sh       primary build and verification entry point
project.yml              XcodeGen source of truth
```

## Common Commands

### Build and test

```bash
swift build
swift test
```

### Regenerate the Xcode project

```bash
xcodegen generate
```

### Run the app locally

Unsigned Debug build:

```bash
./script/build_and_run.sh
```

Build and verify app startup plus widget/runtime consistency:

```bash
./script/build_and_run.sh --verify
```

Launch with logs or telemetry stream:

```bash
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

### Signed build and release verification

Signed Debug build:

```bash
TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh
```

Install a signed Release build into `/Applications` and register the widget:

```bash
./script/build_and_run.sh release-install
```

Verify the installed signed app and widget registration:

```bash
./script/build_and_run.sh release-verify
```

## Git Activity Refresh

The launch script attempts to refresh Git-derived counters before starting the app. It first checks `TINYBUDDY_GIT_SCAN_ROOTS` or `TINYBUDDY_GIT_SCAN_ROOT`, then falls back to previously authorized scan roots saved by the app. If no valid roots are available, the app still launches and the script reports that the Git pre-refresh step was skipped.

## Signing Notes

Unsigned Debug builds use local `CODE_SIGNING_ALLOWED=NO` output under `.build/xcode`. Signed builds use automatic provisioning updates and write derived data to a temporary system location by default. Release install and release verify modes require `TINYBUDDY_SIGNING_MODE=signed`.

## Verification Guidance

Use the smallest check that proves your change:

- `swift test` for shared logic, stores, view models, and script-facing behavior covered by XCTest
- `./script/build_and_run.sh --verify` for app startup and widget/runtime consistency
- `./script/build_and_run.sh release-verify` for installed signed app and widget registration

## Development Notes

- Keep shared logic in `TinyBuddyCore` and avoid duplicating state across app and widget targets.
- When target structure, entitlements, or signing settings change, update `project.yml` first and regenerate the Xcode project.
- Keep app group, bundle identifiers, entitlements, and Info.plist values aligned across app, widget, and verification scripts.
