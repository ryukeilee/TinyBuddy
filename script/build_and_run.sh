#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TinyBuddy"
WIDGET_EXTENSION_NAME="TinyBuddyWidgetExtension"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
WIDGET_EXTENSION_POINT="com.apple.widgetkit-extension"
APP_RUNTIME_TIMEOUT="${TINYBUDDY_APP_RUNTIME_TIMEOUT:-15}"
WIDGET_RUNTIME_TIMEOUT="${TINYBUDDY_WIDGET_RUNTIME_TIMEOUT:-30}"
SANDBOX_RECOVERY_TIMEOUT="${TINYBUDDY_SANDBOX_RECOVERY_TIMEOUT:-30}"
BUILD_LOG_MODE="${TINYBUDDY_BUILD_LOG_MODE:-summary}"
BUILD_FAILURE_TAIL_LINES="${TINYBUDDY_BUILD_FAILURE_TAIL_LINES:-120}"
XCODEBUILD_BIN="${TINYBUDDY_XCODEBUILD_BIN:-/usr/bin/xcodebuild}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_LOG_DIR="${TINYBUDDY_BUILD_LOG_DIR:-${TMPDIR:-/tmp}/TinyBuddyBuildLogs}"
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
  local temp_root="${TMPDIR:-/tmp}"

  case "$SIGNING_MODE" in
    signed)
      printf '%s\n' "${temp_root%/}/TinyBuddyDerivedData"
      ;;
    local)
      printf '%s\n' "${temp_root%/}/TinyBuddyLocalDerivedData"
      ;;
    *)
      printf '%s\n' "$ROOT_DIR/.build/xcode"
      ;;
  esac
}

DERIVED_DATA_DIR="${TINYBUDDY_DERIVED_DATA_DIR:-$(default_derived_data_dir)}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
APP_GROUP_ID="group.com.ryukeili.TinyBuddy"
INSTALL_DIR="${TINYBUDDY_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
APP_PREFERENCES_PLIST="${TINYBUDDY_APP_PREFERENCES_PLIST:-$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist}"
APP_GROUP_PREFERENCES_PLIST="${TINYBUDDY_APP_GROUP_PREFERENCES_PLIST:-$HOME/Library/Group Containers/$APP_GROUP_ID/Library/Preferences/$APP_GROUP_ID.plist}"
GIT_SCAN_ROOT_BOOKMARK_KEY="tinybuddy.gitScanRoots.bookmarkData"
GIT_SCAN_ROOT_RECORDS_KEY="tinybuddy.gitScanRoots.records.v2"
GIT_REFRESH_STATUS_DATE_KEY="tinybuddy.gitRefreshStatus.refreshedAt"
GIT_REFRESH_STATUS_OUTCOME_KEY="tinybuddy.gitRefreshStatus.outcome"
GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.authorizedRootCount"
GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.repositoryCount"
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
    /usr/bin/xcrun swift - "$APP_PREFERENCES_PLIST" "$GIT_SCAN_ROOT_RECORDS_KEY" "$GIT_SCAN_ROOT_BOOKMARK_KEY" <<'SWIFT'
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    exit(0)
}

let plistURL = URL(fileURLWithPath: arguments[1])
let recordsKey = arguments[2]
let legacyBookmarkKey = arguments[3]

guard
    let plistData = try? Data(contentsOf: plistURL),
    let propertyList = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
    let plistDictionary = propertyList as? [String: Any]
else {
    exit(0)
}

let bookmarkDataList: [Data]
if let recordsValue = plistDictionary[recordsKey] {
    guard let records = recordsValue as? [[String: Any]] else {
        exit(0)
    }

    bookmarkDataList = records.compactMap { record in
        guard
            record["id"] as? String != nil,
            let bookmarkData = record["bookmarkData"] as? Data,
            record["displayName"] as? String != nil,
            record["lastKnownPath"] as? String != nil
        else {
            return nil
        }
        return bookmarkData
    }
} else {
    bookmarkDataList = plistDictionary[legacyBookmarkKey] as? [Data] ?? []
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
        )
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

saved_git_scan_root_count() {
  resolve_saved_git_scan_roots | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
}

saved_git_scan_root_record_count() {
  if [ ! -f "$APP_PREFERENCES_PLIST" ]; then
    echo 0
    return 0
  fi

  /usr/bin/xcrun swift - "$APP_PREFERENCES_PLIST" "$GIT_SCAN_ROOT_RECORDS_KEY" "$GIT_SCAN_ROOT_BOOKMARK_KEY" <<'SWIFT'
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print(0)
    exit(0)
}

let plistURL = URL(fileURLWithPath: arguments[1])
let recordsKey = arguments[2]
let legacyBookmarkKey = arguments[3]
guard
    let plistData = try? Data(contentsOf: plistURL),
    let propertyList = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
    let plistDictionary = propertyList as? [String: Any]
else {
    print(0)
    exit(0)
}

if let recordsValue = plistDictionary[recordsKey] {
    print((recordsValue as? [Any])?.count ?? 1)
} else if let legacyValue = plistDictionary[legacyBookmarkKey] {
    print((legacyValue as? [Any])?.count ?? 1)
} else {
    print(0)
}
SWIFT
}

git_refresh_status_value() {
  local key="$1"

  if [ ! -f "$APP_GROUP_PREFERENCES_PLIST" ]; then
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Print :$key" "$APP_GROUP_PREFERENCES_PLIST" 2>/dev/null
}

git_refresh_status_epoch() {
  local date_value
  date_value="$(git_refresh_status_value "$GIT_REFRESH_STATUS_DATE_KEY")" || return $?
  LC_ALL=C /bin/date -j -f '%a %b %d %T %Z %Y' "$date_value" '+%s' 2>/dev/null
}

verify_installed_sandbox_bookmark_recovery() {
  local app_executable="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
  local saved_record_count="${1:-}"
  local baseline_refresh_epoch="${2:--1}"
  local minimum_refresh_epoch="${3:-}"
  local deadline
  local refreshed_epoch
  local authorized_root_count
  local repository_count
  local outcome

  if [ -z "$saved_record_count" ]; then
    saved_record_count="$(saved_git_scan_root_record_count)" || return $?
  fi
  case "$saved_record_count" in
    ''|*[!0-9]*) echo "invalid saved authorization record count" >&2; return 2 ;;
  esac
  case "$baseline_refresh_epoch" in
    -1) ;;
    ''|*[!0-9]*) echo "invalid sandbox recovery verification baseline" >&2; return 2 ;;
  esac
  if [ "$saved_record_count" -eq 0 ]; then
    echo "sandbox bookmark recovery check skipped: no saved authorized Git roots"
    return 0
  fi

  case "$SANDBOX_RECOVERY_TIMEOUT" in
    ''|*[!0-9]*)
      echo "TINYBUDDY_SANDBOX_RECOVERY_TIMEOUT must be a non-negative integer" >&2
      return 2
      ;;
  esac

  if [ -z "$minimum_refresh_epoch" ]; then
    minimum_refresh_epoch="$(/usr/bin/stat -f '%m' "$app_executable")" || return $?
  fi
  case "$minimum_refresh_epoch" in
    ''|*[!0-9]*) echo "invalid sandbox recovery minimum refresh epoch" >&2; return 2 ;;
  esac
  deadline=$((SECONDS + SANDBOX_RECOVERY_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    refreshed_epoch="$(git_refresh_status_epoch 2>/dev/null || true)"
    authorized_root_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY" 2>/dev/null || true)"
    repository_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY" 2>/dev/null || true)"
    outcome="$(git_refresh_status_value "$GIT_REFRESH_STATUS_OUTCOME_KEY" 2>/dev/null || true)"

    case "$refreshed_epoch:$authorized_root_count" in
      *[!0-9:]*|:*|*:)
        ;;
      *)
        if [ "$refreshed_epoch" -ge "$minimum_refresh_epoch" ] \
          && [ "$refreshed_epoch" -gt "$baseline_refresh_epoch" ] \
          && [ "$authorized_root_count" -gt 0 ] \
          && { [ "$outcome" = "succeeded" ] || [ "$outcome" = "partial" ]; }
        then
          case "$repository_count" in
            ''|*[!0-9]*) repository_count="unknown" ;;
          esac
          echo "verified sandbox bookmark recovery: authorized_roots=$authorized_root_count repositories=$repository_count outcome=$outcome refreshed_epoch=$refreshed_epoch"
          return 0
        fi
        ;;
    esac

    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  echo "installed app did not publish a fresh successful or partial Git refresh from saved sandbox bookmarks" >&2
  echo "saved_authorization_records=$saved_record_count minimum_refresh_epoch=$minimum_refresh_epoch" >&2
  return 1
}

SIGNING_ARGS=()
case "$SIGNING_MODE" in
  signed)
    SIGNING_ARGS=(-allowProvisioningUpdates)
    ;;
  local)
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
    ;;
  unsigned)
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
    ;;
  *)
    echo "unsupported TINYBUDDY_SIGNING_MODE: $SIGNING_MODE" >&2
    echo "use 'unsigned', 'local', or 'signed'" >&2
    exit 2
    ;;
esac

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify)
    if [ "$SIGNING_MODE" != "signed" ] && [ "$SIGNING_MODE" != "local" ]; then
      echo "$MODE requires TINYBUDDY_SIGNING_MODE=signed or local" >&2
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

run_xcode_build() {
  local status
  local timestamp
  local log_file
  local -a command=(
    "$XCODEBUILD_BIN"
    -project TinyBuddy.xcodeproj
    -scheme TinyBuddy
    -configuration "$BUILD_CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA_DIR"
    -destination 'platform=macOS'
    "${SIGNING_ARGS[@]}"
    build
  )

  case "$BUILD_LOG_MODE" in
    verbose)
      "${command[@]}"
      ;;
    summary)
      case "$BUILD_FAILURE_TAIL_LINES" in
        ''|*[!0-9]*)
          echo "TINYBUDDY_BUILD_FAILURE_TAIL_LINES must be a non-negative integer" >&2
          return 2
          ;;
      esac

      /bin/mkdir -p "$BUILD_LOG_DIR"
      timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
      log_file="$BUILD_LOG_DIR/${APP_NAME}-${BUILD_CONFIGURATION}-${timestamp}-$$.log"
      if "${command[@]}" >"$log_file" 2>&1; then
        echo "xcodebuild succeeded: configuration=$BUILD_CONFIGURATION; full log: $log_file"
        return 0
      else
        status="$?"
      fi

      echo "xcodebuild failed with exit code $status; full log: $log_file" >&2
      echo "key diagnostics:" >&2
      /usr/bin/grep -E '(^|[[:space:]])(fatal )?error:|\*\* BUILD FAILED \*\*|The following build commands failed:' "$log_file" \
        | /usr/bin/tail -n 80 >&2 || true
      echo "last $BUILD_FAILURE_TAIL_LINES log lines:" >&2
      /usr/bin/tail -n "$BUILD_FAILURE_TAIL_LINES" "$log_file" >&2
      return "$status"
      ;;
    *)
      echo "unsupported TINYBUDDY_BUILD_LOG_MODE: $BUILD_LOG_MODE" >&2
      echo "use 'summary' or 'verbose'" >&2
      return 2
      ;;
  esac
}

run_xcode_build

sign_local_release_bundle() {
  local identity="${TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY:-}"
  local appex="$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex"

  if [ "$SIGNING_MODE" != "local" ]; then
    return 0
  fi

  if [ -z "$identity" ]; then
    echo "TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY is required for local signing" >&2
    return 2
  fi

  if [ ! -d "$appex" ]; then
    appex="$APP_BUNDLE/Contents/Extensions/$WIDGET_EXTENSION_NAME.appex"
  fi
  if [ ! -d "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $APP_BUNDLE" >&2
    return 1
  fi

  /usr/bin/codesign \
    --force \
    --sign "$identity" \
    --timestamp=none \
    --entitlements "$ROOT_DIR/Resources/TinyBuddyWidget/TinyBuddyWidget.entitlements" \
    "$appex"
  /usr/bin/codesign \
    --force \
    --sign "$identity" \
    --timestamp=none \
    --entitlements "$ROOT_DIR/Resources/TinyBuddyApp/TinyBuddy.entitlements" \
    "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  echo "locally signed release bundle: $APP_BUNDLE"
}

sign_local_release_bundle

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

terminate_release_process() {
  local process_name="$1"
  local timeout="$2"
  local graceful_deadline=$((SECONDS + 3))

  pkill -x "$process_name" >/dev/null 2>&1 || true
  while [ "$SECONDS" -lt "$graceful_deadline" ]; do
    if [ -z "$(process_ids "$process_name")" ]; then
      return 0
    fi
    sleep 1
  done

  pkill -KILL -x "$process_name" >/dev/null 2>&1 || true
  wait_for_process_exit "$process_name" "$timeout"
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
  terminate_release_process "$APP_NAME" "$APP_RUNTIME_TIMEOUT" || return $?
  terminate_release_process "$WIDGET_EXTENSION_NAME" "$WIDGET_RUNTIME_TIMEOUT" || return $?
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
  local saved_record_count
  local baseline_refresh_epoch="-1"
  local minimum_refresh_epoch
  local current_epoch

  verify_release_bundle "$INSTALLED_APP" || return $?
  verify_installed_matches_build || return $?
  register_widget_extension "$INSTALLED_APP" || return $?
  installed_appex="$(find_widget_extension "$INSTALLED_APP")"
  widget_executable="$installed_appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  saved_record_count="$(saved_git_scan_root_record_count)" || return $?
  case "$saved_record_count" in
    ''|*[!0-9]*) echo "could not determine saved Git authorization record count" >&2; return 2 ;;
  esac
  minimum_refresh_epoch="$(/usr/bin/stat -f '%m' "$app_executable")" || return $?
  if [ "$saved_record_count" -gt 0 ]; then
    baseline_refresh_epoch="$(git_refresh_status_epoch 2>/dev/null || true)"
    case "$baseline_refresh_epoch" in
      ''|*[!0-9]*) baseline_refresh_epoch="-1" ;;
    esac

    current_epoch="$(/bin/date '+%s')" || return $?
    if [ "$baseline_refresh_epoch" -ge "$current_epoch" ]; then
      sleep 1
      current_epoch="$(/bin/date '+%s')" || return $?
    fi
    if [ "$current_epoch" -gt "$minimum_refresh_epoch" ]; then
      minimum_refresh_epoch="$current_epoch"
    fi
    if [ "$baseline_refresh_epoch" -ge "$minimum_refresh_epoch" ]; then
      minimum_refresh_epoch=$((baseline_refresh_epoch + 1))
    fi
  fi

  /usr/bin/open -n "$INSTALLED_APP" || return $?
  wait_for_running_bundle_process "$APP_NAME" "$app_executable" "$rejected_app_pids" "$APP_RUNTIME_TIMEOUT" || return $?
  wait_for_running_bundle_process "$WIDGET_EXTENSION_NAME" "$widget_executable" "$rejected_widget_pids" "$WIDGET_RUNTIME_TIMEOUT" || return $?
  verify_installed_sandbox_bookmark_recovery \
    "$saved_record_count" \
    "$baseline_refresh_epoch" \
    "$minimum_refresh_epoch" || return $?
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
    install_release_app
    ;;
  release-verify|--release-verify)
    verify_release_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|release-install|release-verify]" >&2
    exit 2
    ;;
esac
