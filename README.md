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

### Local signed build and release verification

Signed Debug build:

```bash
TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh
```

Xcode build output is concise by default. The complete log is kept under
`$TMPDIR/TinyBuddyBuildLogs`; set `TINYBUDDY_BUILD_LOG_MODE=verbose` when the
full live build stream is needed.

Run the complete locally signed Release acceptance gate:

```bash
./script/build_and_run.sh release-acceptance
```

This is the authoritative release entry point. It runs the complete Swift test
suite, builds the Release app and the read-only shared-snapshot verifier, signs
the Widget and then the App with the one valid local Apple Development identity,
checks the candidate's Bundle IDs, versions, Team ID, effective entitlements,
and nested signatures, performs a transactional install, performs a real
same-version reinstall, and then repeats a fresh runtime verification. Every
release workflow holds a kernel-backed lock on the canonical physical install
directory from build through its final gate. A dead owner releases the lock
automatically without deleting or racing the successor lock inode. Release
DerivedData is namespaced by the canonical repository and install target so
independent release targets cannot mutate the same candidate. Parent
HUP/INT/TERM signals are forwarded to the active stage process group, and the
workflow waits for transactional rollback before recording failure and
releasing the lock.
Every stage writes a separate log and atomic `.status` record below
`$TMPDIR/TinyBuddyReleaseEvidence`; `overall.status` records the terminal result,
and `release-complete` exists only after every stage and lock cleanup succeeds.
A failure reports the exact stage, command, exit status, and log path before the
script stops.

Use the lower-level install mode only when the test gate has already passed and
its inputs have not changed:

```bash
./script/build_and_run.sh release-install
```

A successful `release-install` still verifies the current build, installed
bundle, fresh app/HUD process, unique Widget registration, App Group snapshot,
exact HUD and Widget snapshot-consumption telemetry, and repository
authorization recovery. It does not replace the test stage in
`release-acceptance`.

Verify the installed signed app from a fresh process state:

```bash
./script/build_and_run.sh release-verify
```

`release-verify` stops only current-user processes whose executable paths match
the TinyBuddy app or extension bundle contract, rejects stale transaction
residue and launch items (including custom filenames whose contents reference
TinyBuddy), removes stale PlugInKit records for the Widget Bundle ID, and
requires the only remaining record and both running executables to come from
the configured installed bundle. Exact paths and SHA-256/code-directory hashes
prevent LaunchServices or WidgetKit caches from producing a false pass.

## Git Activity Refresh

Authorize one or more repository parent directories from TinyBuddy's Settings window. TinyBuddy stores a read-only, app-scoped security-scoped bookmark for each directory and restores those grants after relaunches and upgrades. Each saved directory has its own availability status plus reauthorize and remove actions. A moved or stale bookmark is refreshed in place when macOS can resolve it; an unavailable, unmounted, revoked, or corrupt entry is paused without discarding activity from the other valid directories.

The launch script attempts to refresh Git-derived counters before starting the app. It first checks `TINYBUDDY_GIT_SCAN_ROOTS` or `TINYBUDDY_GIT_SCAN_ROOT`, then falls back to the app's saved authorization records (including one-time migration of the legacy bookmark list). If no valid roots are available, the app still launches and the script reports that the Git pre-refresh step was skipped.

When at least one authorization is already saved, all release modes require a
fresh launch-triggered successful or partial Git refresh produced by the
installed Sandbox app. With no saved authorization they instead require a fresh
`skipped`/`authorizationRequired` first-scan result. Both paths require a
successful Widget reload request, a valid current-schema combined snapshot, a
HUD state and Widget process that both log consumption of that exact committed
schema/revision/day, and an unchanged saved-authorization record count plus
stable V2 authorization record identifiers. Verification output reports only
sanitized counts, revisions, and status; it never prints saved repository paths
or project names.

The refresh keeps a content-validated per-reflog fingerprint cache. Unchanged repositories reuse their last parsed events; a temporarily slow or unreadable repository reuses its last valid same-day result while other repositories continue. Root enumeration and reflog fingerprint reads have bounded timeouts, refresh execution has a hard upper bound, and an authorization change cancels the superseded process before starting its replacement.

Run the repeatable Git stress benchmark with:

```bash
./script/benchmark_git_refresh.sh
```

It creates disposable repositories outside the worktree, verifies aggregate accuracy, compares first and incremental refresh latency, samples CPU and RSS, and checks cancellation convergence. Repository/event counts and gates can be adjusted with the `TINYBUDDY_BENCHMARK_*` environment variables declared at the top of the script.

## Signing Notes

Unsigned Debug builds use `CODE_SIGNING_ALLOWED=NO` output under `.build/xcode`.
Release workflows default to `TINYBUDDY_SIGNING_MODE=local`: Xcode builds an
unsigned Release candidate, then the script selects exactly one valid Apple
Development identity by SHA-1 fingerprint and signs the Widget before the App.
If more than one valid Apple Development identity is installed, set
`TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY` to the exact 40-character fingerprint.
The candidate must use Team ID `JYL9G28DP3`, contain exactly the checked-in
Sandbox, App Group, and bookmark entitlements, contain no embedded provisioning
profile, and pass strict nested-signature verification before installation.
Profile-free preservation of the existing `group.com.ryukeili.TinyBuddy`
container is limited to macOS 14; local mode fails closed on macOS 15 or later.

`TINYBUDDY_SIGNING_MODE=signed ./script/build_and_run.sh release-acceptance`
remains available when Xcode has an active Apple account and separate matching
App and Widget development profiles. A provisioning failure emits a stable
`TINYBUDDY_RELEASE_SIGNING_ERROR` record before installation. Neither local nor
profile-backed Apple Development acceptance is a Developer ID distribution,
notarization, or public release workflow.

The release script's macOS runtime dependency boundary is Bash 3.2 plus Xcode,
SwiftPM, `codesign`, `security`, `sw_vers`, `pluginkit`, `launchctl`, `log`, `xcrun`, `plutil`,
`PlistBuddy`, `ditto`, `open`, `pgrep`/`pkill`, `ps`, `find`, `stat`, `shasum`,
`perl` with the system `Fcntl` module, `awk`, `grep`, and `tail` from the
system toolchain. HUD and Widget success
telemetry contains only schema, revision, and local day identifiers.

## Verification Guidance

Use the smallest check that proves your change:

- `swift test` for shared logic, stores, view models, and script-facing behavior covered by XCTest
- `./script/benchmark_git_refresh.sh` for repeatable large-repository Git refresh performance and cancellation gates
- `./script/build_and_run.sh --verify` for app startup and widget/runtime consistency
- `./script/build_and_run.sh release-verify` for installed signed app and widget registration
- `./script/build_and_run.sh release-acceptance` for the terminal test, build, install, reinstall, and runtime release gate

## Development Notes

- Keep shared logic in `TinyBuddyCore` and avoid duplicating state across app and widget targets.
- When target structure, entitlements, or signing settings change, update `project.yml` first and regenerate the Xcode project.
- Keep app group, bundle identifiers, entitlements, and Info.plist values aligned across app, widget, and verification scripts.
