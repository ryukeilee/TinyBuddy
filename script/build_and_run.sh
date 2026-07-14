#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TinyBuddy"
WIDGET_EXTENSION_NAME="TinyBuddyWidgetExtension"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
WIDGET_EXTENSION_POINT="com.apple.widgetkit-extension"
APP_RUNTIME_TIMEOUT="${TINYBUDDY_APP_RUNTIME_TIMEOUT:-15}"
WIDGET_RUNTIME_TIMEOUT="${TINYBUDDY_WIDGET_RUNTIME_TIMEOUT:-30}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$MODE" in
  release-install|--release-install|release-verify|--release-verify)
    BUILD_CONFIGURATION="${TINYBUDDY_BUILD_CONFIGURATION:-Release}"
    SIGNING_MODE="${TINYBUDDY_SIGNING_MODE:-signed}"
    ;;
  *)
    BUILD_CONFIGURATION="${TINYBUDDY_BUILD_CONFIGURATION:-Debug}"
    SIGNING_MODE="${TINYBUDDY_SIGNING_MODE:-unsigned}"
    ;;
esac

default_derived_data_dir() {
  if [ "$SIGNING_MODE" = "signed" ]; then
    local temp_root="${TMPDIR:-/tmp}"
    printf '%s\n' "${temp_root%/}/TinyBuddyDerivedData"
  else
    printf '%s\n' "$ROOT_DIR/.build/xcode"
  fi
}

DERIVED_DATA_DIR="${TINYBUDDY_DERIVED_DATA_DIR:-$(default_derived_data_dir)}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
INSTALL_DIR="${TINYBUDDY_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
APP_PREFERENCES_PLIST="${TINYBUDDY_APP_PREFERENCES_PLIST:-$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist}"
GIT_SCAN_ROOT_BOOKMARK_KEY="tinybuddy.gitScanRoots.bookmarkData"
RELEASE_TRANSACTION_DIR=""
RELEASE_STAGED_APP=""
RELEASE_BACKUP_APP=""
RELEASE_HAD_PREVIOUS=0
RELEASE_SWITCHED=0
RELEASE_PREVIOUS_APP_PIDS=""
RELEASE_PREVIOUS_WIDGET_PIDS=""
RELEASE_PREVIOUS_APP_WAS_RUNNING=0

cd "$ROOT_DIR"

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify)
    ;;
  *)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
esac

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

update_git_completion_count() {
  local git_scan_roots="${TINYBUDDY_GIT_SCAN_ROOTS:-${TINYBUDDY_GIT_SCAN_ROOT:-}}"

  if [ -z "$git_scan_roots" ]; then
    git_scan_roots="$(resolve_saved_git_scan_roots)"
  fi

  if [ -z "$git_scan_roots" ]; then
    if [ -f "$APP_PREFERENCES_PLIST" ]; then
      echo "skipping git pre-refresh: no valid saved authorized Git scan roots could be restored from $APP_PREFERENCES_PLIST" >&2
    else
      echo "skipping git pre-refresh: no saved Git scan root authorizations found at $APP_PREFERENCES_PLIST" >&2
    fi
    return 0
  fi

  TINYBUDDY_GIT_SCAN_ROOTS="$git_scan_roots" /bin/bash "$ROOT_DIR/script/update_git_completion_count.sh"
}

run_optional_git_pre_refresh() {
  local exit_code

  if update_git_completion_count; then
    return 0
  else
    exit_code="$?"
  fi

  echo "warning: git pre-refresh failed with exit code $exit_code; continuing with the last valid Git data" >&2
}

resolve_saved_git_scan_roots() {
  if [ ! -f "$APP_PREFERENCES_PLIST" ]; then
    return 0
  fi

  if ! command -v /usr/bin/xcrun >/dev/null 2>&1; then
    return 0
  fi

  local resolved_roots=""
  if ! resolved_roots="$(
    /usr/bin/xcrun swift - "$APP_PREFERENCES_PLIST" "$GIT_SCAN_ROOT_BOOKMARK_KEY" <<'SWIFT'
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    exit(0)
}

let plistURL = URL(fileURLWithPath: arguments[1])
let bookmarkKey = arguments[2]

guard
    let plistData = try? Data(contentsOf: plistURL),
    let propertyList = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
    let plistDictionary = propertyList as? [String: Any],
    let bookmarkDataList = plistDictionary[bookmarkKey] as? [Data]
else {
    exit(0)
}

var emittedPaths = Set<String>()
for bookmarkData in bookmarkDataList {
    var isStale = false
    guard
        let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ),
        !isStale
    else {
        continue
    }

    let normalizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard emittedPaths.insert(normalizedPath).inserted else {
        continue
    }

    print(normalizedPath)
}
SWIFT
  )"; then
    return 0
  fi

  printf '%s' "$resolved_roots"
}

SIGNING_ARGS=()
case "$SIGNING_MODE" in
  signed)
    SIGNING_ARGS=(-allowProvisioningUpdates)
    ;;
  unsigned)
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
    ;;
  *)
    echo "unsupported TINYBUDDY_SIGNING_MODE: $SIGNING_MODE" >&2
    echo "use 'unsigned' or 'signed'" >&2
    exit 2
    ;;
esac

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify)
    if [ "$SIGNING_MODE" != "signed" ]; then
      echo "$MODE requires TINYBUDDY_SIGNING_MODE=signed" >&2
      exit 2
    fi
    ;;
esac

clear_release_metadata() {
  local products_dir="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION"

  if [ -d "$products_dir" ]; then
    /usr/bin/xattr -cr "$products_dir"
  fi
}

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify)
    clear_release_metadata
    ;;
esac

xcodebuild \
  -project TinyBuddy.xcodeproj \
  -scheme TinyBuddy \
  -configuration "$BUILD_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'platform=macOS' \
  "${SIGNING_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

find_widget_extension() {
  local app_bundle="$1"
  local path

  for path in \
    "$app_bundle/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex" \
    "$app_bundle/Contents/Extensions/$WIDGET_EXTENSION_NAME.appex"
  do
    if [ -d "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  /usr/bin/find "$app_bundle/Contents" -maxdepth 3 -type d -name "$WIDGET_EXTENSION_NAME.appex" -print -quit
}

verify_widget_extension_bundle() {
  local app_bundle="$1"
  local appex
  local plist
  local bundle_id
  local extension_point

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  plist="$appex/Contents/Info.plist"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist")"

  if [ "$bundle_id" != "$WIDGET_BUNDLE_ID" ]; then
    echo "unexpected widget bundle id: $bundle_id" >&2
    return 1
  fi

  if [ "$extension_point" != "$WIDGET_EXTENSION_POINT" ]; then
    echo "unexpected widget extension point: $extension_point" >&2
    return 1
  fi

  /usr/bin/codesign --verify --strict --verbose=2 "$appex" || return $?
}

register_widget_extension() {
  local app_bundle="$1"
  local appex

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  /usr/bin/pluginkit -r "$appex" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -a "$appex" || return $?

  if ! /usr/bin/pluginkit -m -A -p "$WIDGET_EXTENSION_POINT" | /usr/bin/grep -F "$WIDGET_BUNDLE_ID" >/dev/null; then
    echo "$WIDGET_BUNDLE_ID is not registered with PlugInKit" >&2
    return 1
  fi

  echo "registered widget extension: $appex"
}

widget_executable_hash() {
  local appex="$1"
  local executable="$appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  if [ ! -f "$executable" ]; then
    echo "missing widget executable: $executable" >&2
    return 1
  fi

  LC_ALL=C /usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}'
}

check_widget_runtime_source_match() {
  local severity="$1"
  local current_appex
  local installed_appex
  local current_hash
  local installed_hash
  local message

  current_appex="$(find_widget_extension "$APP_BUNDLE")"
  if [ -z "$current_appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in current build: $APP_BUNDLE" >&2
    exit 1
  fi

  if [ ! -d "$INSTALLED_APP" ]; then
    return 0
  fi

  installed_appex="$(find_widget_extension "$INSTALLED_APP")"
  if [ -z "$installed_appex" ]; then
    return 0
  fi

  current_hash="$(widget_executable_hash "$current_appex")"
  installed_hash="$(widget_executable_hash "$installed_appex")"

  if [ "$current_hash" = "$installed_hash" ]; then
    return 0
  fi

  message=$(
    cat <<EOF
desktop widget source mismatch:
- desktop Widget is expected to load the installed extension: $installed_appex
- current build produced a different extension: $current_appex
- installed widget executable sha256: $installed_hash
- current build widget executable sha256: $current_hash
The app process can start, but the desktop Widget is still not coming from the current build.
Install a matching app bundle before treating Widget verification as passed.
EOF
  )

  if [ "$severity" = "fail" ]; then
    echo "$message" >&2
    exit 1
  fi

  echo "warning: $message" >&2
}

app_executable_hash() {
  local app_bundle="$1"
  local executable="$app_bundle/Contents/MacOS/$APP_NAME"

  if [ ! -f "$executable" ]; then
    echo "missing app executable: $executable" >&2
    return 1
  fi

  LC_ALL=C /usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}'
}

release_bundle_fingerprint() {
  local app_bundle="$1"
  local app_plist="$app_bundle/Contents/Info.plist"
  local appex
  local version
  local build
  local app_hash
  local widget_hash

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")" || return $?
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")" || return $?
  app_hash="$(app_executable_hash "$app_bundle")" || return $?
  widget_hash="$(widget_executable_hash "$appex")" || return $?
  printf '%s\n' "$version+$build app=$app_hash widget=$widget_hash"
}

verify_release_bundle() {
  local app_bundle="$1"
  local app_plist="$app_bundle/Contents/Info.plist"
  local app_bundle_id
  local app_version
  local app_build
  local appex
  local widget_plist
  local widget_version
  local widget_build

  if [ ! -d "$app_bundle" ]; then
    echo "missing release app bundle: $app_bundle" >&2
    return 1
  fi

  app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_plist")" || return $?
  if [ "$app_bundle_id" != "$BUNDLE_ID" ]; then
    echo "unexpected app bundle id: $app_bundle_id" >&2
    return 1
  fi

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")" || return $?
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")" || return $?
  widget_plist="$appex/Contents/Info.plist"
  widget_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget_plist")" || return $?
  widget_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$widget_plist")" || return $?
  if [ "$app_version" != "$widget_version" ] || [ "$app_build" != "$widget_build" ]; then
    echo "app/widget version mismatch: app=$app_version+$app_build widget=$widget_version+$widget_build" >&2
    return 1
  fi

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle" || return $?
  verify_widget_extension_bundle "$app_bundle" || return $?
  release_bundle_fingerprint "$app_bundle" >/dev/null || return $?
}

verify_installed_matches_build() {
  local build_fingerprint
  local installed_fingerprint

  build_fingerprint="$(release_bundle_fingerprint "$APP_BUNDLE")" || return $?
  installed_fingerprint="$(release_bundle_fingerprint "$INSTALLED_APP")" || return $?
  if [ "$build_fingerprint" != "$installed_fingerprint" ]; then
    echo "installed release does not match the current Release build" >&2
    echo "build:     $build_fingerprint" >&2
    echo "installed: $installed_fingerprint" >&2
    return 1
  fi
}

process_ids() {
  local process_name="$1"
  /usr/bin/pgrep -x "$process_name" 2>/dev/null | /usr/bin/tr '\n' ' ' || true
}

wait_for_process_exit() {
  local process_name="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -z "$(process_ids "$process_name")" ]; then
      return 0
    fi
    sleep 1
  done

  echo "timed out waiting for $process_name to exit" >&2
  return 1
}

wait_for_running_bundle_process() {
  local process_name="$1"
  local expected_executable="$2"
  local rejected_pids="$3"
  local timeout="$4"
  local expected_hash
  local deadline=$((SECONDS + timeout))
  local pid
  local executable_path
  local executable_hash

  expected_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$expected_executable" | /usr/bin/awk '{print $1}')" || return $?
  while [ "$SECONDS" -lt "$deadline" ]; do
    for pid in $(process_ids "$process_name"); do
      case " $rejected_pids " in
        *" $pid "*)
          continue
          ;;
      esac

      executable_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
      executable_path="${executable_path#"${executable_path%%[![:space:]]*}"}"
      if [ "$executable_path" != "$expected_executable" ] || [ ! -f "$executable_path" ]; then
        continue
      fi

      executable_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$executable_path" | /usr/bin/awk '{print $1}')"
      if [ "$executable_hash" = "$expected_hash" ]; then
        echo "verified running $process_name pid=$pid executable=$executable_path sha256=$executable_hash"
        return 0
      fi
    done
    sleep 1
  done

  echo "timed out waiting for running $process_name from $expected_executable with sha256=$expected_hash" >&2
  for pid in $(process_ids "$process_name"); do
    executable_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    echo "observed $process_name pid=$pid executable=$executable_path" >&2
  done
  return 1
}

capture_release_runtime() {
  RELEASE_PREVIOUS_APP_PIDS="$(process_ids "$APP_NAME")"
  RELEASE_PREVIOUS_WIDGET_PIDS="$(process_ids "$WIDGET_EXTENSION_NAME")"
  if [ -n "$RELEASE_PREVIOUS_APP_PIDS" ]; then
    RELEASE_PREVIOUS_APP_WAS_RUNNING=1
  else
    RELEASE_PREVIOUS_APP_WAS_RUNNING=0
  fi
}

stop_release_runtime() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$WIDGET_EXTENSION_NAME" >/dev/null 2>&1 || true
  wait_for_process_exit "$APP_NAME" "$APP_RUNTIME_TIMEOUT" || return $?
  wait_for_process_exit "$WIDGET_EXTENSION_NAME" "$WIDGET_RUNTIME_TIMEOUT" || return $?
}

restore_release_runtime() {
  local installed_appex
  local app_executable="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
  local widget_executable

  verify_release_bundle "$INSTALLED_APP" || return $?
  register_widget_extension "$INSTALLED_APP" || return $?
  installed_appex="$(find_widget_extension "$INSTALLED_APP")"
  widget_executable="$installed_appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  if [ "$RELEASE_PREVIOUS_APP_WAS_RUNNING" -eq 1 ]; then
    /usr/bin/open -n "$INSTALLED_APP" || return $?
    wait_for_running_bundle_process "$APP_NAME" "$app_executable" "" "$APP_RUNTIME_TIMEOUT" || return $?
  fi
  if [ -n "$RELEASE_PREVIOUS_WIDGET_PIDS" ]; then
    wait_for_running_bundle_process "$WIDGET_EXTENSION_NAME" "$widget_executable" "" "$WIDGET_RUNTIME_TIMEOUT" || return $?
  fi
}

rollback_release_install() {
  local rollback_status=0
  local restored_previous=0

  trap - EXIT INT TERM
  if [ -z "$RELEASE_TRANSACTION_DIR" ]; then
    return 0
  fi

  if [ "$RELEASE_SWITCHED" -eq 1 ]; then
    stop_release_runtime || rollback_status=1
    /bin/rm -rf "$INSTALLED_APP" || rollback_status=1
  fi

  if [ "$RELEASE_HAD_PREVIOUS" -eq 1 ] && [ -d "$RELEASE_BACKUP_APP" ]; then
    if /bin/mv "$RELEASE_BACKUP_APP" "$INSTALLED_APP"; then
      restored_previous=1
    else
      rollback_status=1
    fi
  fi

  if [ "$restored_previous" -eq 1 ]; then
    restore_release_runtime || rollback_status=1
  fi

  /bin/rm -rf "$RELEASE_TRANSACTION_DIR" || rollback_status=1
  RELEASE_TRANSACTION_DIR=""
  RELEASE_STAGED_APP=""
  RELEASE_BACKUP_APP=""
  RELEASE_HAD_PREVIOUS=0
  RELEASE_SWITCHED=0

  if [ "$rollback_status" -eq 0 ]; then
    echo "release install failed; rolled back to the previous installed app" >&2
  else
    echo "release install failed and rollback was incomplete" >&2
  fi
  return "$rollback_status"
}

verify_release_app() {
  local rejected_app_pids="${1:-}"
  local rejected_widget_pids="${2:-}"
  local installed_appex
  local app_executable="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
  local widget_executable
  local fingerprint

  verify_release_bundle "$INSTALLED_APP" || return $?
  verify_installed_matches_build || return $?
  register_widget_extension "$INSTALLED_APP" || return $?
  installed_appex="$(find_widget_extension "$INSTALLED_APP")"
  widget_executable="$installed_appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  /usr/bin/open -n "$INSTALLED_APP" || return $?
  wait_for_running_bundle_process "$APP_NAME" "$app_executable" "$rejected_app_pids" "$APP_RUNTIME_TIMEOUT" || return $?
  wait_for_running_bundle_process "$WIDGET_EXTENSION_NAME" "$widget_executable" "$rejected_widget_pids" "$WIDGET_RUNTIME_TIMEOUT" || return $?
  fingerprint="$(release_bundle_fingerprint "$INSTALLED_APP")" || return $?
  echo "verified installed and running release: $INSTALLED_APP ($fingerprint)"
}

activate_and_verify_release_app() {
  verify_release_app "$RELEASE_PREVIOUS_APP_PIDS" "$RELEASE_PREVIOUS_WIDGET_PIDS"
}

install_release_app() {
  local activation_status

  RELEASE_TRANSACTION_DIR="$INSTALL_DIR/.TinyBuddy.install.$$"
  RELEASE_STAGED_APP="$RELEASE_TRANSACTION_DIR/$APP_NAME.app"
  RELEASE_BACKUP_APP="$RELEASE_TRANSACTION_DIR/$APP_NAME.backup.app"
  /bin/mkdir -m 700 "$RELEASE_TRANSACTION_DIR"
  trap 'rollback_release_install' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if /usr/bin/ditto "$APP_BUNDLE" "$RELEASE_STAGED_APP"; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi
  if verify_release_bundle "$RELEASE_STAGED_APP"; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi

  capture_release_runtime
  if stop_release_runtime; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi

  if [ -d "$INSTALLED_APP" ]; then
    /bin/mv "$INSTALLED_APP" "$RELEASE_BACKUP_APP"
    RELEASE_HAD_PREVIOUS=1
  fi
  /bin/mv "$RELEASE_STAGED_APP" "$INSTALLED_APP"
  RELEASE_SWITCHED=1

  if activate_and_verify_release_app; then
    RELEASE_SWITCHED=0
    RELEASE_HAD_PREVIOUS=0
    trap - EXIT INT TERM
    /bin/rm -rf "$RELEASE_TRANSACTION_DIR"
    RELEASE_TRANSACTION_DIR=""
    RELEASE_STAGED_APP=""
    RELEASE_BACKUP_APP=""
    echo "transactionally installed $INSTALLED_APP"
    return 0
  else
    activation_status="$?"
  fi

  rollback_release_install || true
  return "$activation_status"
}

case "$MODE" in
  run)
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    ;;
  --debug|debug)
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    run_optional_git_pre_refresh
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    check_widget_runtime_source_match fail
    ;;
  release-install|--release-install)
    run_optional_git_pre_refresh
    install_release_app
    ;;
  release-verify|--release-verify)
    run_optional_git_pre_refresh
    verify_release_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|release-install|release-verify]" >&2
    exit 2
    ;;
esac
