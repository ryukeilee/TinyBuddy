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
PS_BIN="${TINYBUDDY_PS_BIN:-/bin/ps}"
LOG_BIN="${TINYBUDDY_LOG_BIN:-/usr/bin/log}"
PLUGINKIT_BIN="${TINYBUDDY_PLUGINKIT_BIN:-/usr/bin/pluginkit}"
CODESIGN_BIN="${TINYBUDDY_CODESIGN_BIN:-/usr/bin/codesign}"
SECURITY_BIN="${TINYBUDDY_SECURITY_BIN:-/usr/bin/security}"
SW_VERS_BIN="${TINYBUDDY_SW_VERS_BIN:-/usr/bin/sw_vers}"
LAUNCHCTL_BIN="${TINYBUDDY_LAUNCHCTL_BIN:-/bin/launchctl}"
RELEASE_LOCK_PERL_BIN="${TINYBUDDY_RELEASE_LOCK_PERL_BIN:-/usr/bin/perl}"
EXPECTED_TEAM_ID="${TINYBUDDY_EXPECTED_TEAM_ID:-JYL9G28DP3}"
EXPECTED_GET_TASK_ALLOW="${TINYBUDDY_EXPECTED_GET_TASK_ALLOW:-true}"
CURRENT_USER_UID="${TINYBUDDY_CURRENT_USER_UID:-$(/usr/bin/id -u)}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_LOG_DIR="${TINYBUDDY_BUILD_LOG_DIR:-${TMPDIR:-/tmp}/TinyBuddyBuildLogs}"
case "$MODE" in
  release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
    BUILD_CONFIGURATION="${TINYBUDDY_BUILD_CONFIGURATION:-Release}"
    SIGNING_MODE="${TINYBUDDY_SIGNING_MODE:-local}"
    ;;
  *)
    BUILD_CONFIGURATION="${TINYBUDDY_BUILD_CONFIGURATION:-Debug}"
    SIGNING_MODE="${TINYBUDDY_SIGNING_MODE:-unsigned}"
    ;;
esac

default_derived_data_dir() {
  local temp_root="${TMPDIR:-/tmp}"
  local release_scope_hash
  local scoped_install_dir="${RELEASE_CANONICAL_INSTALL_DIR:-${TINYBUDDY_INSTALL_DIR:-/Applications}}"

  release_scope_hash="$(
    printf '%s\n%s\n' "$ROOT_DIR" "$scoped_install_dir" \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{ print substr($1, 1, 16) }'
  )" || return $?

  case "$SIGNING_MODE" in
    signed)
      printf '%s\n' "${temp_root%/}/TinyBuddyDerivedData-$release_scope_hash"
      ;;
    local)
      printf '%s\n' "${temp_root%/}/TinyBuddyLocalDerivedData-$release_scope_hash"
      ;;
    *)
      printf '%s\n' "$ROOT_DIR/.build/xcode"
      ;;
  esac
}

DERIVED_DATA_DIR="${TINYBUDDY_DERIVED_DATA_DIR:-}"
APP_BUNDLE=""
APP_BINARY=""
BUNDLE_ID="com.ryukeili.TinyBuddy"
APP_GROUP_ID="group.com.ryukeili.TinyBuddy"
INSTALL_DIR="${TINYBUDDY_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
APP_PREFERENCES_PLIST="${TINYBUDDY_APP_PREFERENCES_PLIST:-$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist}"
APP_GROUP_PREFERENCES_PLIST="${TINYBUDDY_APP_GROUP_PREFERENCES_PLIST:-$HOME/Library/Group Containers/$APP_GROUP_ID/Library/Preferences/$APP_GROUP_ID.plist}"
USER_LAUNCH_AGENTS_DIR="${TINYBUDDY_USER_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SYSTEM_LAUNCH_AGENTS_DIR="${TINYBUDDY_SYSTEM_LAUNCH_AGENTS_DIR:-/Library/LaunchAgents}"
SYSTEM_LAUNCH_DAEMONS_DIR="${TINYBUDDY_SYSTEM_LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
GIT_SCAN_ROOT_BOOKMARK_KEY="tinybuddy.gitScanRoots.bookmarkData"
GIT_SCAN_ROOT_RECORDS_KEY="tinybuddy.gitScanRoots.records.v2"
GIT_REFRESH_STATUS_DATE_KEY="tinybuddy.gitRefreshStatus.refreshedAt"
GIT_REFRESH_STATUS_TRIGGER_KEY="tinybuddy.gitRefreshStatus.trigger"
GIT_REFRESH_STATUS_OUTCOME_KEY="tinybuddy.gitRefreshStatus.outcome"
GIT_REFRESH_STATUS_DIAGNOSTIC_REASON_KEY="tinybuddy.gitRefreshStatus.diagnostic.reason"
GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.authorizedRootCount"
GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.repositoryCount"
GIT_REFRESH_STATUS_CACHE_HIT_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.cacheHitCount"
GIT_REFRESH_STATUS_RECOMPUTED_REPOSITORY_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.recomputedRepositoryCount"
GIT_REFRESH_STATUS_INVALID_REPOSITORY_COUNT_KEY="tinybuddy.gitRefreshStatus.metrics.invalidRepositoryCount"
GIT_REFRESH_STATUS_SHARED_DATA_WRITTEN_KEY="tinybuddy.gitRefreshStatus.metrics.sharedDataWritten"
GIT_REFRESH_STATUS_WIDGET_CONTENT_CHANGED_KEY="tinybuddy.gitRefreshStatus.metrics.widgetContentChanged"
GIT_REFRESH_STATUS_WIDGET_RELOADED_KEY="tinybuddy.gitRefreshStatus.metrics.widgetReloaded"
RELEASE_TRANSACTION_DIR=""
RELEASE_STAGED_APP=""
RELEASE_BACKUP_APP=""
RELEASE_HAD_PREVIOUS=0
RELEASE_SWITCHED=0
RELEASE_COMMITTED=0
RELEASE_PREVIOUS_APP_PIDS=""
RELEASE_PREVIOUS_WIDGET_PIDS=""
RELEASE_PREVIOUS_APP_WAS_RUNNING=0
RELEASE_VERIFIED_APP_PID=""
RELEASE_VERIFIED_WIDGET_PID=""
RELEASE_SNAPSHOT_SCHEMA=""
RELEASE_SNAPSHOT_REVISION=""
RELEASE_SNAPSHOT_DAY=""
RELEASE_REFRESH_WIDGET_CONTENT_CHANGED=""
RELEASE_REFRESH_WIDGET_RELOADED=""
RELEASE_WIDGET_REGISTRATION_PRESERVED=0
RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
RELEASE_AUTHORIZATION_RECORD_COUNT_BEFORE=""
RELEASE_AUTHORIZATION_RECORD_IDENTITY_BEFORE=""
RELEASE_EVIDENCE_DIR=""
RELEASE_STAGE_INDEX=0
RELEASE_COMPLETION_MARKER=""
RELEASE_EXCHANGE_STATUS_FILE=""
RELEASE_EXCHANGE_IN_PROGRESS=0
RELEASE_STAGED_APP_IDENTITY=""
RELEASE_VERIFIER_BINARY="${TINYBUDDY_RELEASE_VERIFIER_BINARY:-}"
RELEASE_INSTALLER_BINARY="${TINYBUDDY_RELEASE_INSTALLER_BINARY:-}"
RELEASE_CANONICAL_INSTALL_DIR=""
RELEASE_LOCK_DIR=""
RELEASE_LOCK_FILE=""
RELEASE_LOCK_HELD=0
RELEASE_ACTIVE_STAGE_PID=""
RELEASE_SIGNAL_NAME=""
RELEASE_SIGNAL_STATUS=0
RELEASE_SIGNAL_FORWARDED=0

initialize_build_artifact_paths() {
  if [ -z "$DERIVED_DATA_DIR" ]; then
    DERIVED_DATA_DIR="$(default_derived_data_dir)" || return $?
  fi
  APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
  APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
}

cd "$ROOT_DIR"

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
    ;;
  *)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
esac

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

saved_git_scan_root_record_identity() {
  if [ ! -f "$APP_PREFERENCES_PLIST" ]; then
    echo "none:0"
    return 0
  fi

  /usr/bin/xcrun swift - "$APP_PREFERENCES_PLIST" "$GIT_SCAN_ROOT_RECORDS_KEY" "$GIT_SCAN_ROOT_BOOKMARK_KEY" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("unreadable")
    exit(0)
}

let plistURL = URL(fileURLWithPath: arguments[1])
let recordsKey = arguments[2]
let legacyBookmarkKey = arguments[3]
guard
    let plistData = try? Data(contentsOf: plistURL),
    let propertyList = try? PropertyListSerialization.propertyList(
        from: plistData,
        options: [],
        format: nil
    ),
    let plistDictionary = propertyList as? [String: Any]
else {
    print("unreadable")
    exit(0)
}

func valueCount(_ value: Any) -> Int {
    (value as? [Any])?.count ?? 1
}

if let recordsValue = plistDictionary[recordsKey] {
    let values = recordsValue as? [Any] ?? [recordsValue]
    let identifiers = values.compactMap { value -> String? in
        guard let dictionary = value as? [String: Any],
              let identifier = dictionary["id"] as? String,
              !identifier.isEmpty,
              dictionary["bookmarkData"] is Data,
              dictionary["displayName"] is String,
              dictionary["lastKnownPath"] is String else {
            return nil
        }
        return identifier
    }
    guard identifiers.count == values.count,
          Set(identifiers).count == identifiers.count else {
        print("v2-unverified:\(values.count)")
        exit(0)
    }
    let canonical = identifiers.sorted().joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    print("v2:\(digest)")
} else if let legacyValue = plistDictionary[legacyBookmarkKey] {
    print("legacy:\(valueCount(legacyValue))")
} else {
    print("none:0")
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
  local trigger
  local outcome
  local diagnostic_reason
  local cache_hit_count
  local recomputed_repository_count
  local invalid_repository_count
  local shared_data_written
  local widget_content_changed
  local widget_reloaded

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
    trigger="$(git_refresh_status_value "$GIT_REFRESH_STATUS_TRIGGER_KEY" 2>/dev/null || true)"
    authorized_root_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_AUTHORIZED_ROOT_COUNT_KEY" 2>/dev/null || true)"
    repository_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_REPOSITORY_COUNT_KEY" 2>/dev/null || true)"
    outcome="$(git_refresh_status_value "$GIT_REFRESH_STATUS_OUTCOME_KEY" 2>/dev/null || true)"
    diagnostic_reason="$(git_refresh_status_value "$GIT_REFRESH_STATUS_DIAGNOSTIC_REASON_KEY" 2>/dev/null || true)"
    cache_hit_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_CACHE_HIT_COUNT_KEY" 2>/dev/null || true)"
    recomputed_repository_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_RECOMPUTED_REPOSITORY_COUNT_KEY" 2>/dev/null || true)"
    invalid_repository_count="$(git_refresh_status_value "$GIT_REFRESH_STATUS_INVALID_REPOSITORY_COUNT_KEY" 2>/dev/null || true)"
    shared_data_written="$(git_refresh_status_value "$GIT_REFRESH_STATUS_SHARED_DATA_WRITTEN_KEY" 2>/dev/null || true)"
    widget_content_changed="$(git_refresh_status_value "$GIT_REFRESH_STATUS_WIDGET_CONTENT_CHANGED_KEY" 2>/dev/null || true)"
    widget_reloaded="$(git_refresh_status_value "$GIT_REFRESH_STATUS_WIDGET_RELOADED_KEY" 2>/dev/null || true)"

    case "$refreshed_epoch:$authorized_root_count" in
      *[!0-9:]*|:*|*:)
        ;;
      *)
        if [ "$refreshed_epoch" -ge "$minimum_refresh_epoch" ] \
          && [ "$refreshed_epoch" -gt "$baseline_refresh_epoch" ] \
          && { [ "$trigger" = "launch" ] || [ "$trigger" = "reopen" ]; } \
          && { [ "$widget_content_changed" = "true" ] || [ "$widget_content_changed" = "false" ]; } \
          && { [ "$widget_reloaded" = "true" ] || [ "$widget_reloaded" = "false" ]; }
        then
          case "$repository_count" in ''|*[!0-9]*) repository_count="unknown" ;; esac
          case "$cache_hit_count" in ''|*[!0-9]*) cache_hit_count="unknown" ;; esac
          case "$recomputed_repository_count" in ''|*[!0-9]*) recomputed_repository_count="unknown" ;; esac
          case "$invalid_repository_count" in ''|*[!0-9]*) invalid_repository_count="unknown" ;; esac
          case "$shared_data_written" in true|false) ;; *) shared_data_written="unknown" ;; esac

          if [ "$saved_record_count" -gt 0 ] \
            && [ "$authorized_root_count" -gt 0 ] \
            && { [ "$outcome" = "succeeded" ] || [ "$outcome" = "partial" ]; } \
            && { [ "$widget_content_changed" = "false" ] || [ "$widget_reloaded" = "true" ]; }
          then
            RELEASE_REFRESH_WIDGET_CONTENT_CHANGED="$widget_content_changed"
            RELEASE_REFRESH_WIDGET_RELOADED="$widget_reloaded"
            echo "verified sandbox bookmark recovery: trigger=$trigger authorized_roots=$authorized_root_count repositories=$repository_count outcome=$outcome cache_hits=$cache_hit_count recomputed=$recomputed_repository_count invalid=$invalid_repository_count shared_data_written=$shared_data_written widget_content_changed=$widget_content_changed widget_reloaded=$widget_reloaded refreshed_epoch=$refreshed_epoch"
            return 0
          fi

          if [ "$saved_record_count" -eq 0 ] \
            && [ "$authorized_root_count" -eq 0 ] \
            && [ "$outcome" = "skipped" ] \
            && [ "$diagnostic_reason" = "authorizationRequired" ] \
            && { [ "$widget_content_changed" = "false" ] || [ "$widget_reloaded" = "true" ]; }
          then
            RELEASE_REFRESH_WIDGET_CONTENT_CHANGED="$widget_content_changed"
            RELEASE_REFRESH_WIDGET_RELOADED="$widget_reloaded"
            echo "verified first-launch authorization state: trigger=$trigger authorized_roots=0 outcome=$outcome reason=$diagnostic_reason widget_content_changed=$widget_content_changed widget_reloaded=$widget_reloaded refreshed_epoch=$refreshed_epoch"
            return 0
          fi
        fi
        ;;
    esac

    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  if [ "$saved_record_count" -gt 0 ]; then
    echo "installed app did not publish a fresh post-install successful or partial Git refresh from saved sandbox bookmarks" >&2
  else
    echo "installed app did not publish a fresh post-install authorization-required first-scan status" >&2
  fi
  echo "saved_authorization_records=$saved_record_count minimum_refresh_epoch=$minimum_refresh_epoch observed_trigger=${trigger:-unknown} observed_outcome=${outcome:-unknown} observed_widget_content_changed=${widget_content_changed:-unknown} observed_widget_reloaded=${widget_reloaded:-unknown}" >&2
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
  release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
    case "$SIGNING_MODE" in
      local|signed)
        ;;
      *)
        echo "$MODE requires TINYBUDDY_SIGNING_MODE=local or signed" >&2
        exit 2
        ;;
    esac
    ;;
esac

clear_release_metadata() {
  local products_dir="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION"

  if [ -d "$products_dir" ]; then
    /usr/bin/xattr -cr "$products_dir"
  fi
}

report_release_signing_failure() {
  local log_file="$1"
  local account_state=unknown
  local app_profile_state=unknown
  local widget_profile_state=unknown

  if [ "$SIGNING_MODE" != "signed" ]; then
    return 0
  fi
  if /usr/bin/grep -F "No Accounts: Add a new account in Accounts settings." "$log_file" >/dev/null; then
    account_state=missing
  fi
  if /usr/bin/grep -F "No profiles for '$BUNDLE_ID' were found" "$log_file" >/dev/null; then
    app_profile_state=missing
  fi
  if /usr/bin/grep -F "No profiles for '$WIDGET_BUNDLE_ID' were found" "$log_file" >/dev/null; then
    widget_profile_state=missing
  fi
  if [ "$account_state" = unknown ] \
    && [ "$app_profile_state" = unknown ] \
    && [ "$widget_profile_state" = unknown ]
  then
    return 0
  fi

  echo "TINYBUDDY_RELEASE_SIGNING_ERROR code=missing-development-provisioning team=$EXPECTED_TEAM_ID account=$account_state app_profile=$app_profile_state widget_profile=$widget_profile_state" >&2
  echo "configure an Xcode Apple account for Team $EXPECTED_TEAM_ID and automatic macOS Development profiles for $BUNDLE_ID and $WIDGET_BUNDLE_ID; no install was attempted" >&2
}

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
      report_release_signing_failure "$log_file"
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

resolve_local_code_sign_identity() {
  local requested_identity="${TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY:-}"
  local identities
  local candidates
  local candidate_count
  local normalized_identity

  identities="$("$SECURITY_BIN" find-identity -v -p codesigning)" || return $?
  candidates="$(
    printf '%s\n' "$identities" \
      | /usr/bin/awk '
          /^[[:space:]]*[0-9]+\)/ {
            fingerprint = $2
            label = $0
            sub(/^[^"]*"/, "", label)
            sub(/"[[:space:]]*$/, "", label)
            if (length(fingerprint) == 40 && fingerprint ~ /^[[:xdigit:]]+$/ \
                && label ~ /^Apple Development:/) {
              print toupper(fingerprint) "\t" label
            }
          }
        '
  )" || return $?

  if [ -n "$requested_identity" ]; then
    if ! [[ "$requested_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      echo "TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY must be an exact 40-character SHA-1 fingerprint" >&2
      return 2
    fi
    normalized_identity="$(printf '%s' "$requested_identity" | /usr/bin/tr '[:lower:]' '[:upper:]')"
    if ! printf '%s\n' "$candidates" \
      | /usr/bin/awk -F '\t' -v expected="$normalized_identity" \
          '$1 == expected { found = 1 } END { exit(found ? 0 : 1) }'
    then
      echo "requested local Apple Development signing identity is not valid: $normalized_identity" >&2
      return 1
    fi
    printf '%s\n' "$normalized_identity"
    return 0
  fi

  candidate_count="$(printf '%s\n' "$candidates" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$candidate_count" -ne 1 ]; then
    echo "local signing requires exactly one valid Apple Development identity; found=$candidate_count" >&2
    echo "set TINYBUDDY_LOCAL_CODE_SIGN_IDENTITY to an exact fingerprint when more than one is installed" >&2
    return 1
  fi
  printf '%s\n' "$candidates" | /usr/bin/awk -F '\t' 'NF { print $1; exit }'
}

require_local_signing_host_compatibility() {
  local product_version
  local major_version

  if [ "$SIGNING_MODE" != "local" ]; then
    return 0
  fi
  product_version="$("$SW_VERS_BIN" -productVersion)" || return $?
  major_version="${product_version%%.*}"
  case "$major_version" in
    ''|*[!0-9]*)
      echo "could not determine the macOS major version for local signing: $product_version" >&2
      return 1
      ;;
  esac
  if [ "$major_version" -ge 15 ]; then
    echo "profile-free local signing cannot preserve the group.com App Group contract on macOS $product_version" >&2
    echo "use TINYBUDDY_SIGNING_MODE=signed with matching App and Widget provisioning profiles" >&2
    return 1
  fi
  echo "verified profile-free local signing host: macOS=$product_version"
}

sign_local_release_bundle() {
  local identity
  local appex="$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex"

  if [ "$SIGNING_MODE" != "local" ]; then
    return 0
  fi

  require_local_signing_host_compatibility || return $?

  if [ ! -d "$appex" ]; then
    appex="$APP_BUNDLE/Contents/Extensions/$WIDGET_EXTENSION_NAME.appex"
  fi
  if [ ! -d "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $APP_BUNDLE" >&2
    return 1
  fi

  identity="$(resolve_local_code_sign_identity)" || return $?
  if [ -e "$APP_BUNDLE/Contents/embedded.provisionprofile" ] \
    || [ -e "$appex/Contents/embedded.provisionprofile" ]
  then
    echo "local signing candidate unexpectedly contains an embedded provisioning profile" >&2
    return 1
  fi

  "$CODESIGN_BIN" \
    --force \
    --sign "$identity" \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ROOT_DIR/Resources/TinyBuddyWidget/TinyBuddyWidget.entitlements" \
    "$appex"
  "$CODESIGN_BIN" \
    --force \
    --sign "$identity" \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ROOT_DIR/Resources/TinyBuddyApp/TinyBuddy.entitlements" \
    "$APP_BUNDLE"
  "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  echo "locally signed release bundle: identity=$identity bundle=$APP_BUNDLE"
}

generate_xcode_project() {
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
  fi
}

build_current_app() {
  generate_xcode_project || return $?
  case "$MODE" in
    release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
      clear_release_metadata || return $?
      ;;
  esac
  run_xcode_build || return $?
  sign_local_release_bundle || return $?

  case "$MODE" in
    release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
      build_release_verifier || return $?
      build_release_installer || return $?
      ;;
  esac
}

build_release_verifier() {
  local binary_directory

  "$ROOT_DIR/script/swiftpm.sh" build --product TinyBuddyReleaseVerifier || return $?
  binary_directory="$("$ROOT_DIR/script/swiftpm.sh" build --show-bin-path)" || return $?
  RELEASE_VERIFIER_BINARY="$binary_directory/TinyBuddyReleaseVerifier"
  if [ ! -x "$RELEASE_VERIFIER_BINARY" ]; then
    echo "missing TinyBuddyReleaseVerifier executable after SwiftPM build" >&2
    return 1
  fi
}

build_release_installer() {
  local binary_directory

  "$ROOT_DIR/script/swiftpm.sh" build --product TinyBuddyReleaseInstaller || return $?
  binary_directory="$("$ROOT_DIR/script/swiftpm.sh" build --show-bin-path)" || return $?
  RELEASE_INSTALLER_BINARY="$binary_directory/TinyBuddyReleaseInstaller"
  if [ ! -x "$RELEASE_INSTALLER_BINARY" ]; then
    echo "missing TinyBuddyReleaseInstaller executable after SwiftPM build" >&2
    return 1
  fi
}

resolve_release_verifier_binary() {
  local binary_directory

  if [ -n "$RELEASE_VERIFIER_BINARY" ] && [ -x "$RELEASE_VERIFIER_BINARY" ]; then
    return 0
  fi
  binary_directory="$("$ROOT_DIR/script/swiftpm.sh" build --show-bin-path)" || return $?
  RELEASE_VERIFIER_BINARY="$binary_directory/TinyBuddyReleaseVerifier"
  if [ ! -x "$RELEASE_VERIFIER_BINARY" ]; then
    echo "missing TinyBuddyReleaseVerifier executable after Release build stage" >&2
    return 1
  fi
}

resolve_release_installer_binary() {
  local binary_directory

  if [ -n "$RELEASE_INSTALLER_BINARY" ] && [ -x "$RELEASE_INSTALLER_BINARY" ]; then
    return 0
  fi
  binary_directory="$("$ROOT_DIR/script/swiftpm.sh" build --show-bin-path)" || return $?
  RELEASE_INSTALLER_BINARY="$binary_directory/TinyBuddyReleaseInstaller"
  if [ ! -x "$RELEASE_INSTALLER_BINARY" ]; then
    echo "missing TinyBuddyReleaseInstaller executable after Release build stage" >&2
    return 1
  fi
}

atomic_exchange_release_apps() {
  local first_path="$1"
  local second_path="$2"
  local installer_status

  resolve_release_installer_binary || return 69
  if "$RELEASE_INSTALLER_BINARY" \
    exchange \
    --path-a "$first_path" \
    --path-b "$second_path"
  then
    return 0
  else
    installer_status="$?"
  fi
  # Exit 69 is reserved by this wrapper for a pre-exchange resolver failure.
  # Remap the same status from an overridden helper to the unknown-state path.
  if [ "$installer_status" -eq 69 ]; then
    return 76
  fi
  return "$installer_status"
}

atomic_place_release_candidate() {
  local source_path="$1"
  local destination_path="$2"
  local installer_status

  resolve_release_installer_binary || return 69
  if "$RELEASE_INSTALLER_BINARY" \
    install \
    --source "$source_path" \
    --destination "$destination_path"
  then
    return 0
  else
    installer_status="$?"
  fi
  if [ "$installer_status" -eq 69 ]; then
    return 76
  fi
  return "$installer_status"
}

release_path_identity() {
  /usr/bin/stat -f '%d:%i' "$1"
}

run_release_regression_tests() {
  "$ROOT_DIR/script/swiftpm.sh" test
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

launch_installed_release_app() {
  if [ "$RELEASE_WIDGET_REGISTRATION_PRESERVED" -eq 1 ]; then
    local app_executable="$INSTALLED_APP/Contents/MacOS/$APP_NAME"

    if [ ! -x "$app_executable" ]; then
      echo "missing installed app executable: $app_executable" >&2
      return 1
    fi

    (
      trap - INT TERM
      trap '' HUP
      exec 9>&-
      exec "$app_executable"
    ) </dev/null >/dev/null 2>&1 &
  else
    /usr/bin/open -n "$INSTALLED_APP"
  fi
}

find_widget_extension() {
  local app_bundle="$1"
  local matches
  local count

  if [ ! -d "$app_bundle/Contents" ]; then
    echo "missing app Contents directory: $app_bundle" >&2
    return 1
  fi

  matches="$(/usr/bin/find "$app_bundle/Contents" -maxdepth 3 -type d -name "$WIDGET_EXTENSION_NAME.appex" -print)"
  count="$(printf '%s\n' "$matches" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$count" -ne 1 ]; then
    echo "expected exactly one $WIDGET_EXTENSION_NAME.appex in $app_bundle; found $count" >&2
    return 1
  fi

  printf '%s\n' "$matches"
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

  "$CODESIGN_BIN" --verify --strict --verbose=2 "$appex" || return $?
}

register_widget_extension() {
  local app_bundle="$1"
  local allow_registration_add="${2:-0}"
  local appex
  local registered_paths
  local registered_count
  local deadline

  RELEASE_WIDGET_REGISTRATION_PRESERVED=0
  RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  registered_paths="$(registered_widget_paths)" || return $?
  registered_count="$(printf '%s\n' "$registered_paths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$registered_count" -eq 1 ] && [ "$registered_paths" = "$appex" ]; then
    RELEASE_WIDGET_REGISTRATION_PRESERVED=1
    echo "preserved existing widget extension registration: $appex"
    return 0
  fi
  if [ "$registered_count" -ne 0 ]; then
    echo "refusing to replace existing Widget registrations automatically" >&2
    echo "expected_widget_path=$appex registered_count=$registered_count" >&2
    return 1
  fi
  if [ "$allow_registration_add" -ne 1 ]; then
    echo "missing Widget registration; automatic registration is allowed only during a clean install" >&2
    return 1
  fi

  RELEASE_WIDGET_REGISTRATION_ATTEMPTED=1
  "$PLUGINKIT_BIN" -a "$appex" || return $?

  deadline=$((SECONDS + WIDGET_RUNTIME_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    registered_paths="$(registered_widget_paths)" || return $?
    registered_count="$(printf '%s\n' "$registered_paths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$registered_count" -eq 1 ] && [ "$registered_paths" = "$appex" ]; then
      echo "registered unique widget extension: $appex"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  echo "$WIDGET_BUNDLE_ID registration is not unique or does not point to the installed extension" >&2
  echo "expected_widget_path=$appex registered_count=${registered_count:-0}" >&2
  return 1
}

unregister_widget_extensions() {
  local registered_path
  local registered_paths
  local registered_count
  local deadline

  registered_paths="$(registered_widget_paths)" || return $?
  while IFS= read -r registered_path; do
    if [ -z "$registered_path" ]; then
      continue
    fi
    if ! "$PLUGINKIT_BIN" -r "$registered_path" >/dev/null 2>&1; then
      echo "failed to unregister Widget record during clean-install rollback: $registered_path" >&2
      return 1
    fi
  done <<EOF
$(printf '%s\n' "$registered_paths" | /usr/bin/awk 'NF && !seen[$0]++')
EOF

  deadline=$((SECONDS + WIDGET_RUNTIME_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    registered_paths="$(registered_widget_paths)" || return $?
    registered_count="$(printf '%s\n' "$registered_paths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    if [ "$registered_count" -eq 0 ]; then
      echo "removed Widget registrations after clean-install rollback"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  echo "Widget registrations remained after clean-install rollback: count=${registered_count:-0}" >&2
  return 1
}

registered_widget_paths() {
  "$PLUGINKIT_BIN" -m -A -D -v -i "$WIDGET_BUNDLE_ID" \
    | /usr/bin/awk -F '\t' '
        NF >= 2 {
          path = $NF
          sub(/^[[:space:]]+/, "", path)
          sub(/[[:space:]]+$/, "", path)
          if (path ~ /\.appex$/) print path
        }
      '
}

verify_widget_registration_preflight() {
  local expected_appex="$INSTALLED_APP/Contents/PlugIns/$WIDGET_EXTENSION_NAME.appex"
  local registered_paths
  local registered_count

  registered_paths="$(registered_widget_paths)" || return $?
  registered_count="$(printf '%s\n' "$registered_paths" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$registered_count" -eq 0 ]; then
    if [ ! -e "$INSTALLED_APP" ] && [ ! -L "$INSTALLED_APP" ]; then
      return 0
    fi
    echo "existing installation is missing its Widget registration; refusing automatic repair" >&2
    return 1
  fi
  if [ -d "$INSTALLED_APP" ] \
    && [ "$registered_count" -eq 1 ] \
    && [ "$registered_paths" = "$expected_appex" ]
  then
    return 0
  fi

  echo "existing Widget registrations cannot be preserved safely" >&2
  echo "expected_widget_path=$expected_appex registered_count=$registered_count" >&2
  return 1
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

code_directory_hash() {
  local signed_path="$1"
  local details
  local cdhash

  details="$("$CODESIGN_BIN" --display --verbose=4 "$signed_path" 2>&1)" || return $?
  cdhash="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^CDHash=/ { print $2; exit }')"
  if [ -z "$cdhash" ]; then
    echo "missing code directory hash: $signed_path" >&2
    return 1
  fi
  printf '%s\n' "$cdhash"
}

signing_team_identifier() {
  local signed_path="$1"
  local details
  local team_identifier

  details="$("$CODESIGN_BIN" --display --verbose=4 "$signed_path" 2>&1)" || return $?
  team_identifier="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
  if [ -z "$team_identifier" ]; then
    echo "missing TeamIdentifier in signature: $signed_path" >&2
    return 1
  fi
  printf '%s\n' "$team_identifier"
}

signing_leaf_authority() {
  local signed_path="$1"
  local details
  local authority

  details="$("$CODESIGN_BIN" --display --verbose=4 "$signed_path" 2>&1)" || return $?
  authority="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^Authority=/ { print $2; exit }')"
  if [ -z "$authority" ]; then
    echo "missing signing Authority in signature: $signed_path" >&2
    return 1
  fi
  printf '%s\n' "$authority"
}

extract_signed_entitlements() {
  local signed_path="$1"
  local output_plist="$2"
  local diagnostic_file="$3"

  if ! "$CODESIGN_BIN" --display --entitlements :- "$signed_path" >"$output_plist" 2>"$diagnostic_file"; then
    echo "failed to read signed entitlements: $signed_path" >&2
    /bin/cat "$diagnostic_file" >&2
    return 1
  fi
  if ! /usr/bin/plutil -lint "$output_plist" >/dev/null; then
    echo "signed entitlements are not a valid property list: $signed_path" >&2
    return 1
  fi
}

require_boolean_entitlement() {
  local entitlements_plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_plist" 2>/dev/null || true)"
  if [ "$actual" != "$expected" ]; then
    echo "unexpected signed entitlement $key: expected=$expected actual=${actual:-missing}" >&2
    return 1
  fi
}

require_string_entitlement() {
  local entitlements_plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_plist" 2>/dev/null || true)"
  if [ "$actual" != "$expected" ]; then
    echo "unexpected signed entitlement $key: expected=$expected actual=${actual:-missing}" >&2
    return 1
  fi
}

require_app_group_entitlement() {
  local entitlements_plist="$1"
  local groups
  local match_count
  local group_count

  groups="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlements_plist" 2>/dev/null || true)"
  match_count="$(
    printf '%s\n' "$groups" \
      | /usr/bin/awk -v expected="$APP_GROUP_ID" '
          {
            value = $0
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (value == expected) count += 1
          }
          END { print count + 0 }
        '
  )"
  group_count="$(
    printf '%s\n' "$groups" \
      | /usr/bin/awk '
          {
            value = $0
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (value != "" && value != "Array {" && value != "}") count += 1
          }
          END { print count + 0 }
        '
  )"
  if [ "$match_count" -ne 1 ] || [ "$group_count" -ne 1 ]; then
    echo "signed entitlements must contain only the expected App Group; matches=$match_count groups=$group_count" >&2
    return 1
  fi
}

require_entitlement_key_count() {
  local entitlements_plist="$1"
  local expected_count="$2"
  local actual_count

  actual_count="$(
    /usr/libexec/PlistBuddy -c Print "$entitlements_plist" 2>/dev/null \
      | /usr/bin/awk '/^    [^[:space:]].* = / { count += 1 } END { print count + 0 }'
  )"
  if [ "$actual_count" -ne "$expected_count" ]; then
    echo "signed entitlements contain unexpected top-level keys: expected=$expected_count actual=$actual_count" >&2
    return 1
  fi
}

verify_code_signing_contract() {
  local app_bundle="$1"
  local appex="$2"
  local app_team
  local widget_team
  local app_authority
  local widget_authority
  local temp_dir
  local app_entitlements
  local widget_entitlements
  local diagnostic_file
  local status=0

  app_team="$(signing_team_identifier "$app_bundle")" || return $?
  widget_team="$(signing_team_identifier "$appex")" || return $?
  if [ "$app_team" != "$EXPECTED_TEAM_ID" ] || [ "$widget_team" != "$EXPECTED_TEAM_ID" ]; then
    echo "unexpected signing team: expected=$EXPECTED_TEAM_ID app=$app_team widget=$widget_team" >&2
    return 1
  fi
  app_authority="$(signing_leaf_authority "$app_bundle")" || return $?
  widget_authority="$(signing_leaf_authority "$appex")" || return $?
  case "$app_authority" in
    "Apple Development:"*) ;;
    *) echo "unexpected App signing authority: $app_authority" >&2; return 1 ;;
  esac
  case "$widget_authority" in
    "Apple Development:"*) ;;
    *) echo "unexpected Widget signing authority: $widget_authority" >&2; return 1 ;;
  esac

  if [ "$SIGNING_MODE" = "local" ]; then
    if [ -e "$app_bundle/Contents/embedded.provisionprofile" ] \
      || [ -e "$appex/Contents/embedded.provisionprofile" ]
    then
      echo "profile-free local signing contract rejects embedded provisioning profiles" >&2
      return 1
    fi
  fi

  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/TinyBuddyEntitlements.XXXXXX")" || return $?
  app_entitlements="$temp_dir/app.plist"
  widget_entitlements="$temp_dir/widget.plist"
  diagnostic_file="$temp_dir/codesign.log"

  extract_signed_entitlements "$app_bundle" "$app_entitlements" "$diagnostic_file" || status=1
  if [ "$status" -eq 0 ]; then
    extract_signed_entitlements "$appex" "$widget_entitlements" "$diagnostic_file" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    require_boolean_entitlement "$app_entitlements" "com.apple.security.app-sandbox" true || status=1
    require_boolean_entitlement "$app_entitlements" "com.apple.security.files.bookmarks.app-scope" true || status=1
    require_boolean_entitlement "$app_entitlements" "com.apple.security.files.user-selected.read-only" true || status=1
    require_app_group_entitlement "$app_entitlements" || status=1
    require_boolean_entitlement "$widget_entitlements" "com.apple.security.app-sandbox" true || status=1
    require_app_group_entitlement "$widget_entitlements" || status=1
    case "$SIGNING_MODE" in
      local)
        require_entitlement_key_count "$app_entitlements" 4 || status=1
        require_entitlement_key_count "$widget_entitlements" 2 || status=1
        ;;
      signed)
        require_string_entitlement "$app_entitlements" "com.apple.application-identifier" "$EXPECTED_TEAM_ID.$BUNDLE_ID" || status=1
        require_string_entitlement "$app_entitlements" "com.apple.developer.team-identifier" "$EXPECTED_TEAM_ID" || status=1
        require_boolean_entitlement "$app_entitlements" "com.apple.security.get-task-allow" "$EXPECTED_GET_TASK_ALLOW" || status=1
        require_entitlement_key_count "$app_entitlements" 7 || status=1
        require_string_entitlement "$widget_entitlements" "com.apple.application-identifier" "$EXPECTED_TEAM_ID.$WIDGET_BUNDLE_ID" || status=1
        require_string_entitlement "$widget_entitlements" "com.apple.developer.team-identifier" "$EXPECTED_TEAM_ID" || status=1
        require_boolean_entitlement "$widget_entitlements" "com.apple.security.get-task-allow" "$EXPECTED_GET_TASK_ALLOW" || status=1
        require_entitlement_key_count "$widget_entitlements" 5 || status=1
        ;;
      *)
        echo "unsupported signing contract mode: $SIGNING_MODE" >&2
        status=2
        ;;
    esac
  fi

  if /bin/rm -rf "$temp_dir"; then
    :
  else
    status=1
    echo "failed to clean temporary signing evidence" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  echo "verified signing identity and entitlements: mode=$SIGNING_MODE team=$EXPECTED_TEAM_ID app_group=$APP_GROUP_ID"
}

release_bundle_fingerprint() {
  local app_bundle="$1"
  local app_plist="$app_bundle/Contents/Info.plist"
  local appex
  local version
  local build
  local app_hash
  local widget_hash
  local app_cdhash
  local widget_cdhash

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    return 1
  fi

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")" || return $?
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_plist")" || return $?
  app_hash="$(app_executable_hash "$app_bundle")" || return $?
  widget_hash="$(widget_executable_hash "$appex")" || return $?
  app_cdhash="$(code_directory_hash "$app_bundle")" || return $?
  widget_cdhash="$(code_directory_hash "$appex")" || return $?
  printf '%s\n' "$version+$build app=$app_hash widget=$widget_hash app_cdhash=$app_cdhash widget_cdhash=$widget_cdhash"
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

  "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$app_bundle" || return $?
  verify_widget_extension_bundle "$app_bundle" || return $?
  verify_code_signing_contract "$app_bundle" "$appex" || return $?
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
  local expected_suffix

  case "$process_name" in
    "$APP_NAME")
      expected_suffix="/$APP_NAME.app/Contents/MacOS/$APP_NAME"
      ;;
    "$WIDGET_EXTENSION_NAME")
      expected_suffix="/$WIDGET_EXTENSION_NAME.appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"
      ;;
    *)
      echo "unsupported TinyBuddy release process name: $process_name" >&2
      return 2
      ;;
  esac

  "$PS_BIN" -axo pid=,uid=,comm= 2>/dev/null \
    | /usr/bin/awk -v expectedSuffix="$expected_suffix" -v expectedUID="$CURRENT_USER_UID" '
        {
          pid = $1
          uid = $2
          $1 = ""
          $2 = ""
          sub(/^[[:space:]]+/, "", $0)
          if (length($0) >= length(expectedSuffix) &&
              substr($0, length($0) - length(expectedSuffix) + 1) == expectedSuffix &&
              uid == expectedUID &&
              pid ~ /^[0-9]+$/) {
            printf "%s ", pid
          }
        }
      '
}

process_matches_release_contract() {
  local pid="$1"
  local process_name="$2"
  local expected_suffix

  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$process_name" in
    "$APP_NAME")
      expected_suffix="/$APP_NAME.app/Contents/MacOS/$APP_NAME"
      ;;
    "$WIDGET_EXTENSION_NAME")
      expected_suffix="/$WIDGET_EXTENSION_NAME.appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"
      ;;
    *)
      return 1
      ;;
  esac

  "$PS_BIN" -p "$pid" -o uid=,comm= 2>/dev/null \
    | /usr/bin/awk -v expectedSuffix="$expected_suffix" -v expectedUID="$CURRENT_USER_UID" '
        {
          uid = $1
          $1 = ""
          sub(/^[[:space:]]+/, "", $0)
          if (uid == expectedUID &&
              length($0) >= length(expectedSuffix) &&
              substr($0, length($0) - length(expectedSuffix) + 1) == expectedSuffix) {
            matched = 1
          }
        }
        END { exit matched ? 0 : 1 }
      '
}

verify_running_bundle_process() {
  local pid="$1"
  local process_name="$2"
  local expected_executable="$3"
  local executable_path
  local expected_hash
  local executable_hash

  if ! process_matches_release_contract "$pid" "$process_name"; then
    echo "$process_name process is no longer alive under the expected user and bundle path: pid=$pid" >&2
    return 1
  fi
  executable_path="$("$PS_BIN" -p "$pid" -o comm= 2>/dev/null || true)"
  executable_path="${executable_path#"${executable_path%%[![:space:]]*}"}"
  if [ "$executable_path" != "$expected_executable" ] || [ ! -f "$executable_path" ]; then
    echo "$process_name process executable changed before final verification: pid=$pid executable=${executable_path:-missing}" >&2
    return 1
  fi
  expected_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$expected_executable" | /usr/bin/awk '{print $1}')" || return $?
  executable_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$executable_path" | /usr/bin/awk '{print $1}')" || return $?
  if [ "$executable_hash" != "$expected_hash" ]; then
    echo "$process_name process executable hash changed before final verification: pid=$pid" >&2
    return 1
  fi
  echo "verified final running $process_name process: pid=$pid executable=$executable_path sha256=$executable_hash"
}

wait_for_process_exit() {
  local process_name="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))
  local pids

  while [ "$SECONDS" -lt "$deadline" ]; do
    pids="$(process_ids "$process_name")" || return $?
    if [ -z "$pids" ]; then
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
  local pid
  local pids

  pids="$(process_ids "$process_name")" || return $?
  for pid in $pids; do
    if process_matches_release_contract "$pid" "$process_name"; then
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
  done
  while [ "$SECONDS" -lt "$graceful_deadline" ]; do
    pids="$(process_ids "$process_name")" || return $?
    if [ -z "$pids" ]; then
      return 0
    fi
    sleep 1
  done

  pids="$(process_ids "$process_name")" || return $?
  for pid in $pids; do
    if process_matches_release_contract "$pid" "$process_name"; then
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
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
  local pids

  expected_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$expected_executable" | /usr/bin/awk '{print $1}')" || return $?
  while [ "$SECONDS" -lt "$deadline" ]; do
    pids="$(process_ids "$process_name")" || return $?
    for pid in $pids; do
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
        if [ "$process_name" = "$APP_NAME" ]; then
          RELEASE_VERIFIED_APP_PID="$pid"
        elif [ "$process_name" = "$WIDGET_EXTENSION_NAME" ]; then
          RELEASE_VERIFIED_WIDGET_PID="$pid"
        fi
        echo "verified running $process_name pid=$pid executable=$executable_path sha256=$executable_hash"
        return 0
      fi
    done
    sleep 1
  done

  echo "timed out waiting for running $process_name from $expected_executable with sha256=$expected_hash" >&2
  pids="$(process_ids "$process_name")" || return $?
  for pid in $pids; do
    executable_path="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
    echo "observed $process_name pid=$pid executable=$executable_path" >&2
  done
  return 1
}

verify_hud_window() {
  local app_pid="$1"
  local deadline
  local message="HUD ready identifier=TinyBuddy.HUDWindow width=284 height=520"
  local predicate

  case "$app_pid" in ''|*[!0-9]*) echo "invalid HUD process identity" >&2; return 2 ;; esac
  predicate="processIdentifier == $app_pid AND subsystem == \"local.tinybuddy\" AND category == \"HUD\" AND eventMessage CONTAINS \"$message\""
  deadline=$((SECONDS + APP_RUNTIME_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    if "$LOG_BIN" show \
      --last "${APP_RUNTIME_TIMEOUT}s" \
      --style compact \
      --predicate "$predicate" 2>/dev/null \
      | /usr/bin/grep -F "$message" >/dev/null
    then
      echo "verified HUD window telemetry: pid=$app_pid width=284 height=520"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  echo "installed app did not publish exact HUD-ready telemetry: pid=$app_pid" >&2
  return 1
}

verify_shared_snapshot_contract() {
  local expected_day
  local output
  local schema
  local revision
  local snapshot_day

  resolve_release_verifier_binary || return $?
  if [ ! -f "$APP_GROUP_PREFERENCES_PLIST" ]; then
    echo "App Group preferences were not published by the installed app" >&2
    return 1
  fi

  expected_day="$(/bin/date '+%Y-%m-%d')" || return $?
  output="$(
    "$RELEASE_VERIFIER_BINARY" \
      shared-snapshot \
      --plist "$APP_GROUP_PREFERENCES_PLIST" \
      --expected-day "$expected_day"
  )" || return $?
  schema="$(
    printf '%s\n' "$output" \
      | /usr/bin/awk '{ for (fieldIndex = 1; fieldIndex <= NF; fieldIndex += 1) if ($fieldIndex ~ /^schema=/) { sub(/^schema=/, "", $fieldIndex); print $fieldIndex; exit } }'
  )"
  revision="$(
    printf '%s\n' "$output" \
      | /usr/bin/awk '{ for (fieldIndex = 1; fieldIndex <= NF; fieldIndex += 1) if ($fieldIndex ~ /^revision=/) { sub(/^revision=/, "", $fieldIndex); print $fieldIndex; exit } }'
  )"
  snapshot_day="$(
    printf '%s\n' "$output" \
      | /usr/bin/awk '{ for (fieldIndex = 1; fieldIndex <= NF; fieldIndex += 1) if ($fieldIndex ~ /^day=/) { sub(/^day=/, "", $fieldIndex); print $fieldIndex; exit } }'
  )"
  case "$schema" in ''|*[!0-9]*) echo "release snapshot verifier did not return a valid schema" >&2; return 1 ;; esac
  case "$revision" in ''|*[!0-9]*) echo "release snapshot verifier did not return a valid revision" >&2; return 1 ;; esac
  case "$snapshot_day" in
    ????-??-??) ;;
    *) echo "release snapshot verifier did not return a valid day" >&2; return 1 ;;
  esac
  if [ "$snapshot_day" != "$expected_day" ]; then
    echo "release snapshot verifier returned an unexpected local day" >&2
    return 1
  fi

  RELEASE_SNAPSHOT_SCHEMA="$schema"
  RELEASE_SNAPSHOT_REVISION="$revision"
  RELEASE_SNAPSHOT_DAY="$snapshot_day"
  printf '%s\n' "$output"
}

verify_widget_snapshot_consumption() {
  local widget_pid="$1"
  local schema="$2"
  local revision="$3"
  local snapshot_day="$4"
  local content_changed="${5:-true}"
  local deadline
  local log_output
  local message
  local observed_revision
  local predicate

  case "$widget_pid" in ''|*[!0-9]*) echo "invalid Widget process identity" >&2; return 2 ;; esac
  case "$schema" in ''|*[!0-9]*) echo "invalid Widget snapshot schema" >&2; return 2 ;; esac
  case "$revision" in ''|*[!0-9]*) echo "invalid Widget snapshot revision" >&2; return 2 ;; esac
  case "$snapshot_day" in
    ????-??-??) ;;
    *) echo "invalid Widget snapshot verification day" >&2; return 2 ;;
  esac
  case "$content_changed" in
    true|false) ;;
    *) echo "invalid Widget content-change state" >&2; return 2 ;;
  esac

  message="snapshot consumed schema=$schema revision=$revision day=$snapshot_day"
  if [ "$content_changed" = "true" ]; then
    predicate="processIdentifier == $widget_pid AND subsystem == \"local.tinybuddy\" AND category == \"SharedSnapshot\" AND eventMessage CONTAINS \"$message\""
  else
    predicate="processIdentifier == $widget_pid AND subsystem == \"local.tinybuddy\" AND category == \"SharedSnapshot\" AND eventMessage CONTAINS \"snapshot consumed schema=$schema revision=\" AND eventMessage CONTAINS \"day=$snapshot_day\""
  fi
  deadline=$((SECONDS + WIDGET_RUNTIME_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    log_output="$("$LOG_BIN" show \
      --last "${WIDGET_RUNTIME_TIMEOUT}s" \
      --info \
      --style compact \
      --predicate "$predicate" 2>/dev/null || true)"
    if printf '%s\n' "$log_output" | /usr/bin/grep -F "$message" >/dev/null; then
      echo "verified Widget shared snapshot consumption: pid=$widget_pid schema=$schema revision=$revision day=$snapshot_day"
      return 0
    fi
    if [ "$content_changed" = "false" ]; then
      observed_revision="$(
        printf '%s\n' "$log_output" \
          | /usr/bin/sed -nE "s/.*snapshot consumed schema=$schema revision=([0-9]+) day=$snapshot_day.*/\\1/p" \
          | /usr/bin/sort -n \
          | /usr/bin/awk -v current="$revision" '$1 <= current { observed = $1 } END { if (observed != "") print observed }'
      )"
      case "$observed_revision" in
        ''|*[!0-9]*) ;;
        *)
          echo "verified Widget stable shared snapshot consumption: pid=$widget_pid schema=$schema consumed_revision=$observed_revision current_revision=$revision day=$snapshot_day"
          return 0
          ;;
      esac
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  if [ "$content_changed" = "true" ]; then
    echo "Widget did not log consumption of the committed shared snapshot: pid=$widget_pid schema=$schema revision=$revision day=$snapshot_day" >&2
  else
    echo "Widget did not log consumption of a compatible stable shared snapshot: pid=$widget_pid schema=$schema maximum_revision=$revision day=$snapshot_day" >&2
  fi
  return 1
}

verify_hud_snapshot_consumption() {
  local app_pid="$1"
  local schema="$2"
  local revision="$3"
  local snapshot_day="$4"
  local deadline
  local message
  local predicate

  case "$app_pid" in ''|*[!0-9]*) echo "invalid HUD process identity" >&2; return 2 ;; esac
  case "$schema" in ''|*[!0-9]*) echo "invalid HUD snapshot schema" >&2; return 2 ;; esac
  case "$revision" in ''|*[!0-9]*) echo "invalid HUD snapshot revision" >&2; return 2 ;; esac
  case "$snapshot_day" in
    ????-??-??) ;;
    *) echo "invalid HUD snapshot verification day" >&2; return 2 ;;
  esac

  message="HUD consumed schema=$schema revision=$revision day=$snapshot_day"
  predicate="processIdentifier == $app_pid AND subsystem == \"local.tinybuddy\" AND category == \"SharedSnapshot\" AND eventMessage CONTAINS \"$message\""
  deadline=$((SECONDS + APP_RUNTIME_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    if "$LOG_BIN" show \
      --last "$((APP_RUNTIME_TIMEOUT + SANDBOX_RECOVERY_TIMEOUT))s" \
      --info \
      --style compact \
      --predicate "$predicate" 2>/dev/null \
      | /usr/bin/grep -F "$message" >/dev/null
    then
      echo "verified HUD shared snapshot consumption: pid=$app_pid schema=$schema revision=$revision day=$snapshot_day"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    sleep 1
  done

  echo "HUD did not log consumption of the committed shared snapshot: pid=$app_pid schema=$schema revision=$revision day=$snapshot_day" >&2
  return 1
}

verify_authorization_record_preservation() {
  local before_count="$1"
  local before_identity="$2"
  local after_count
  local after_identity

  after_count="$(saved_git_scan_root_record_count)" || return $?
  after_identity="$(saved_git_scan_root_record_identity)" || return $?
  case "$before_count:$after_count" in
    *[!0-9:]*|:*|*:)
      echo "invalid authorization record preservation counts" >&2
      return 2
      ;;
  esac
  if [ "$before_count" -ne "$after_count" ]; then
    echo "saved Git authorization record count changed during installation: before=$before_count after=$after_count" >&2
    return 1
  fi

  case "$before_identity" in
    v2:*)
      if [ "$before_count" -gt 0 ] && [ "$after_identity" != "$before_identity" ]; then
        echo "saved Git authorization identities changed during installation" >&2
        return 1
      fi
      echo "verified saved authorization preservation: records=$after_count identities=stable"
      ;;
    *)
      echo "verified saved authorization preservation: records=$after_count identities=count-only"
      ;;
  esac
}

capture_release_runtime() {
  RELEASE_PREVIOUS_APP_PIDS="$(process_ids "$APP_NAME")" || return $?
  RELEASE_PREVIOUS_WIDGET_PIDS="$(process_ids "$WIDGET_EXTENSION_NAME")" || return $?
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
    launch_installed_release_app || return $?
    wait_for_running_bundle_process "$APP_NAME" "$app_executable" "" "$APP_RUNTIME_TIMEOUT" || return $?
  fi
  if [ -n "$RELEASE_PREVIOUS_WIDGET_PIDS" ]; then
    wait_for_running_bundle_process "$WIDGET_EXTENSION_NAME" "$widget_executable" "" "$WIDGET_RUNTIME_TIMEOUT" || return $?
  fi
}

validate_release_install_paths() {
  local canonical_install_dir

  case "$INSTALL_DIR" in
    ''|/|.)
      echo "unsafe TinyBuddy install directory: ${INSTALL_DIR:-empty}" >&2
      return 2
      ;;
    /*)
      ;;
    *)
      echo "TinyBuddy install directory must be an absolute path: $INSTALL_DIR" >&2
      return 2
      ;;
  esac
  if [ "$INSTALLED_APP" != "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "installed app path is outside the configured TinyBuddy install contract" >&2
    return 2
  fi
  if [ ! -d "$INSTALL_DIR" ]; then
    echo "TinyBuddy install directory does not exist: $INSTALL_DIR" >&2
    return 1
  fi
  if [ -n "$RELEASE_CANONICAL_INSTALL_DIR" ]; then
    if [ "$INSTALL_DIR" != "$RELEASE_CANONICAL_INSTALL_DIR" ] \
      || [ "$INSTALLED_APP" != "$RELEASE_CANONICAL_INSTALL_DIR/$APP_NAME.app" ]
    then
      echo "TinyBuddy release install paths changed after canonicalization" >&2
      return 2
    fi
    canonical_install_dir="$RELEASE_CANONICAL_INSTALL_DIR"
  else
    canonical_install_dir="$(cd "$INSTALL_DIR" && pwd -P)" || return $?
  fi
  if [ -z "$canonical_install_dir" ] || [ "$canonical_install_dir" = "/" ]; then
    echo "TinyBuddy install directory resolves to an unsafe location" >&2
    return 2
  fi
  RELEASE_CANONICAL_INSTALL_DIR="$canonical_install_dir"
  INSTALL_DIR="$canonical_install_dir"
  INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
  if { [ -e "$INSTALLED_APP" ] || [ -L "$INSTALLED_APP" ]; } \
    && { [ ! -d "$INSTALLED_APP" ] || [ -L "$INSTALLED_APP" ]; }
  then
    echo "refusing to replace a non-directory or symlink TinyBuddy install object: $INSTALLED_APP" >&2
    return 2
  fi
}

acquire_release_lock() {
  local owner_pid
  local lock_status

  validate_release_install_paths || return $?
  RELEASE_LOCK_DIR="$RELEASE_CANONICAL_INSTALL_DIR/.TinyBuddy.release.lock"
  RELEASE_LOCK_FILE="$RELEASE_LOCK_DIR/owner"
  if [ -L "$RELEASE_LOCK_DIR" ] \
    || { [ -e "$RELEASE_LOCK_DIR" ] && [ ! -d "$RELEASE_LOCK_DIR" ]; }
  then
    echo "invalid TinyBuddy release lock directory: $RELEASE_LOCK_DIR" >&2
    return 1
  fi
  if [ ! -d "$RELEASE_LOCK_DIR" ]; then
    if /bin/mkdir -m 700 "$RELEASE_LOCK_DIR" 2>/dev/null; then
      :
    elif [ ! -d "$RELEASE_LOCK_DIR" ] || [ -L "$RELEASE_LOCK_DIR" ]; then
      echo "failed to initialize TinyBuddy release lock directory: $RELEASE_LOCK_DIR" >&2
      return 1
    fi
  fi
  /bin/chmod 700 "$RELEASE_LOCK_DIR" || return $?
  if [ -L "$RELEASE_LOCK_FILE" ] \
    || { [ -e "$RELEASE_LOCK_FILE" ] && [ ! -f "$RELEASE_LOCK_FILE" ]; }
  then
    echo "invalid TinyBuddy release lock owner file: $RELEASE_LOCK_FILE" >&2
    return 1
  fi
  if [ ! -e "$RELEASE_LOCK_FILE" ]; then
    (umask 077; set -C; : >"$RELEASE_LOCK_FILE") 2>/dev/null || true
  fi
  if [ -L "$RELEASE_LOCK_FILE" ] || [ ! -f "$RELEASE_LOCK_FILE" ]; then
    echo "failed to create a regular TinyBuddy release lock owner file" >&2
    return 1
  fi
  /bin/chmod 600 "$RELEASE_LOCK_FILE" || return $?
  if ! exec 9<>"$RELEASE_LOCK_FILE"; then
    echo "failed to open TinyBuddy release lock owner file" >&2
    return 1
  fi
  if LC_ALL=C LANG=C "$RELEASE_LOCK_PERL_BIN" -MFcntl=:flock,:mode,SEEK_SET -e '
      my ($path, $pid, $mode) = @ARGV;
      open(my $owner, "+<&=9") or exit 77;
      flock($owner, LOCK_EX | LOCK_NB) or exit 75;
      my @descriptor = stat($owner);
      my @path = lstat($path);
      exit 76 unless @descriptor && @path && S_ISREG($path[2])
          && $descriptor[0] == $path[0] && $descriptor[1] == $path[1];
      seek($owner, 0, SEEK_SET) or exit 77;
      local $/;
      my $existing = <$owner> // "";
      if ($existing =~ /\A([0-9]+)\t[^\t\n]+\n?\z/ && kill(0, $1)) {
          exit 78;
      }
      seek($owner, 0, SEEK_SET) or exit 77;
      truncate($owner, 0) or exit 77;
      my $metadata = "$pid\t$mode\tflock-v1\n";
      my $written = syswrite($owner, $metadata);
      exit 77 unless defined($written) && $written == length($metadata);
      @path = lstat($path);
      exit 76 unless @path && S_ISREG($path[2])
          && $descriptor[0] == $path[0] && $descriptor[1] == $path[1];
    ' "$RELEASE_LOCK_FILE" "$$" "$MODE"
  then
    RELEASE_LOCK_HELD=1
    echo "acquired TinyBuddy release lock: $RELEASE_LOCK_FILE protocol=flock-v1"
    return 0
  else
    lock_status="$?"
  fi
  exec 9>&-
  owner_pid="$(/usr/bin/awk 'NR == 1 { print $1; exit }' "$RELEASE_LOCK_FILE" 2>/dev/null || true)"
  case "$lock_status" in
    75|78)
      echo "another TinyBuddy release workflow is active: pid=${owner_pid:-unknown}" >&2
      ;;
    76)
      echo "TinyBuddy release lock path changed while acquiring it" >&2
      ;;
    *)
      echo "failed to acquire TinyBuddy release lock: status=$lock_status" >&2
      ;;
  esac
  RELEASE_LOCK_DIR=""
  RELEASE_LOCK_FILE=""
  return "$lock_status"
}

release_release_lock() {
  if [ "$RELEASE_LOCK_HELD" -ne 1 ]; then
    return 0
  fi
  case "$RELEASE_LOCK_DIR:$RELEASE_LOCK_FILE" in
    "$RELEASE_CANONICAL_INSTALL_DIR/.TinyBuddy.release.lock:$RELEASE_CANONICAL_INSTALL_DIR/.TinyBuddy.release.lock/owner")
      ;;
    *)
      echo "refusing to release an invalid TinyBuddy release lock path" >&2
      return 1
      ;;
  esac
  if ! LC_ALL=C LANG=C "$RELEASE_LOCK_PERL_BIN" -MFcntl=:flock,:mode,SEEK_SET -e '
      my ($path, $pid, $mode) = @ARGV;
      open(my $owner, "+<&=9") or exit 77;
      flock($owner, LOCK_EX | LOCK_NB) or exit 75;
      my @descriptor = stat($owner);
      my @path = lstat($path);
      exit 76 unless @descriptor && @path && S_ISREG($path[2])
          && $descriptor[0] == $path[0] && $descriptor[1] == $path[1];
      seek($owner, 0, SEEK_SET) or exit 77;
      local $/;
      my $actual = <$owner> // "";
      my $expected = "$pid\t$mode\tflock-v1\n";
      exit 78 unless $actual eq $expected;
    ' "$RELEASE_LOCK_FILE" "$$" "$MODE"
  then
    echo "refusing to release a changed or unowned TinyBuddy lock" >&2
    return 1
  fi
  exec 9>&-
  RELEASE_LOCK_HELD=0
  RELEASE_LOCK_DIR=""
  RELEASE_LOCK_FILE=""
}

compare_numeric_versions() {
  local left="$1"
  local right="$2"

  /usr/bin/awk -v left="$left" -v right="$right" 'BEGIN {
    if (left !~ /^[0-9]+([.][0-9]+)*$/ || right !~ /^[0-9]+([.][0-9]+)*$/) {
      exit 2
    }
    leftCount = split(left, leftParts, ".")
    rightCount = split(right, rightParts, ".")
    count = leftCount > rightCount ? leftCount : rightCount
    for (partIndex = 1; partIndex <= count; partIndex += 1) {
      leftValue = partIndex <= leftCount ? leftParts[partIndex] + 0 : 0
      rightValue = partIndex <= rightCount ? rightParts[partIndex] + 0 : 0
      if (leftValue < rightValue) { print -1; exit }
      if (leftValue > rightValue) { print 1; exit }
    }
    print 0
  }'
}

release_install_scenario() {
  local candidate_plist="$APP_BUNDLE/Contents/Info.plist"
  local installed_plist="$INSTALLED_APP/Contents/Info.plist"
  local candidate_version
  local candidate_build
  local installed_version
  local installed_build
  local version_order

  if [ ! -d "$INSTALLED_APP" ]; then
    echo "clean-install"
    return 0
  fi
  if [ ! -f "$installed_plist" ]; then
    echo "legacy-bundle-replacement"
    return 0
  fi

  candidate_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate_plist")" || return $?
  candidate_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$candidate_plist")" || return $?
  installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed_plist" 2>/dev/null || true)"
  installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_plist" 2>/dev/null || true)"

  if [ "$candidate_version" = "$installed_version" ] && [ "$candidate_build" = "$installed_build" ]; then
    echo "same-version-reinstall"
    return 0
  fi
  case "$candidate_build:$installed_build" in
    *[!0-9:]*|:*|*:)
      echo "version-replacement"
      ;;
    *)
      if [ "$candidate_build" -gt "$installed_build" ]; then
        echo "older-version-upgrade"
      elif [ "$candidate_build" -lt "$installed_build" ]; then
        echo "version-downgrade"
      else
        version_order="$(compare_numeric_versions "$candidate_version" "$installed_version" 2>/dev/null || true)"
        if [ "$version_order" = "1" ]; then
          echo "older-version-upgrade"
        elif [ "$version_order" = "-1" ]; then
          echo "version-downgrade"
        else
          echo "version-replacement"
        fi
      fi
      ;;
  esac
}

launch_item_references_tinybuddy() {
  local launch_item="$1"
  local launch_program
  local launch_arguments

  launch_program="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$launch_item" 2>/dev/null || true)"
  launch_arguments="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$launch_item" 2>/dev/null || true)"
  printf '%s\n%s\n' "$launch_program" "$launch_arguments" \
    | /usr/bin/grep -E \
      "($BUNDLE_ID|$WIDGET_BUNDLE_ID|/$APP_NAME[.]app/Contents/|/$WIDGET_EXTENSION_NAME[.]appex/Contents/)" \
      >/dev/null
}

find_tinybuddy_launch_item() {
  local launch_directory
  local launch_item

  for launch_directory in \
    "$USER_LAUNCH_AGENTS_DIR" \
    "$SYSTEM_LAUNCH_AGENTS_DIR" \
    "$SYSTEM_LAUNCH_DAEMONS_DIR"
  do
    if [ ! -d "$launch_directory" ]; then
      continue
    fi
    while IFS= read -r launch_item; do
      if launch_item_references_tinybuddy "$launch_item"; then
        printf '%s\n' "$launch_item"
        return 0
      fi
    done < <(/usr/bin/find "$launch_directory" -maxdepth 1 -type f -name '*.plist' -print)
  done
  return 1
}

verify_release_environment_preflight() {
  local residue
  local scenario
  local launch_item
  local user_domain

  validate_release_install_paths || return $?
  residue="$(
    /usr/bin/find "$INSTALL_DIR" \
      -maxdepth 1 \
      -type d \
      -name ".TinyBuddy.install.*" \
      -print \
      -quit
  )" || return $?
  if [ -n "$residue" ]; then
    echo "stale TinyBuddy install transaction requires recovery before release acceptance: $residue" >&2
    return 1
  fi

  for launch_item in \
    "$USER_LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist" \
    "$SYSTEM_LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist" \
    "$SYSTEM_LAUNCH_DAEMONS_DIR/$BUNDLE_ID.plist"
  do
    if [ -e "$launch_item" ]; then
      echo "unexpected TinyBuddy launch item would contaminate release acceptance: $launch_item" >&2
      return 1
    fi
  done

  launch_item="$(find_tinybuddy_launch_item 2>/dev/null || true)"
  if [ -n "$launch_item" ]; then
    echo "unexpected launch item references TinyBuddy and would contaminate release acceptance: $launch_item" >&2
    return 1
  fi

  user_domain="gui/$(/usr/bin/id -u)/$BUNDLE_ID"
  if "$LAUNCHCTL_BIN" print "$user_domain" >/dev/null 2>&1 \
    || "$LAUNCHCTL_BIN" print "system/$BUNDLE_ID" >/dev/null 2>&1
  then
    echo "unexpected loaded TinyBuddy launch service would contaminate release acceptance" >&2
    return 1
  fi

  scenario="$(release_install_scenario)" || return $?
  if [ "$scenario" = "version-downgrade" ] && [ "${TINYBUDDY_ALLOW_DOWNGRADE:-0}" != "1" ]; then
    echo "refusing release downgrade without TINYBUDDY_ALLOW_DOWNGRADE=1" >&2
    return 1
  fi
  echo "release install scenario: $scenario"
}

install_same_version_release_app() {
  local scenario

  scenario="$(release_install_scenario)" || return $?
  if [ "$scenario" != "same-version-reinstall" ]; then
    echo "expected same-version-reinstall after the first accepted install; observed $scenario" >&2
    return 1
  fi
  echo "release install scenario: $scenario"
  install_release_app
}

initialize_release_evidence() {
  local evidence_root="${TINYBUDDY_RELEASE_EVIDENCE_DIR:-${TMPDIR:-/tmp}/TinyBuddyReleaseEvidence}"
  local timestamp

  timestamp="$(/bin/date '+%Y%m%d-%H%M%S')" || return $?
  RELEASE_EVIDENCE_DIR="${evidence_root%/}/$timestamp-$$"
  RELEASE_STAGE_INDEX=0
  RELEASE_COMPLETION_MARKER="$RELEASE_EVIDENCE_DIR/release-complete"
  /bin/mkdir -m 700 -p "$evidence_root" || return $?
  /bin/mkdir -m 700 "$RELEASE_EVIDENCE_DIR" || return $?
  write_release_overall_status running - || return $?
  echo "release evidence directory: $RELEASE_EVIDENCE_DIR"
}

write_release_status_file() {
  local status_file="$1"
  shift
  local temporary_status_file="$status_file.tmp.$$"

  if [ -z "$RELEASE_EVIDENCE_DIR" ]; then
    echo "release evidence directory has not been initialized" >&2
    return 2
  fi
  case "$status_file" in
    "$RELEASE_EVIDENCE_DIR/"*)
      ;;
    *)
      echo "refusing to write release status outside the evidence directory" >&2
      return 2
      ;;
  esac
  if ! printf '%s\n' "$@" >"$temporary_status_file"; then
    /bin/rm -f "$temporary_status_file" >/dev/null 2>&1 || true
    return 1
  fi
  if ! /bin/mv -f "$temporary_status_file" "$status_file"; then
    /bin/rm -f "$temporary_status_file" >/dev/null 2>&1 || true
    return 1
  fi
}

write_release_overall_status() {
  local state="$1"
  local exit_status="$2"
  local recorded_epoch

  recorded_epoch="$(/bin/date '+%s')" || return $?
  write_release_status_file \
    "$RELEASE_EVIDENCE_DIR/overall.status" \
    "workflow=$MODE" \
    "state=$state" \
    "exit_status=$exit_status" \
    "stage_count=$RELEASE_STAGE_INDEX" \
    "recorded_epoch=$recorded_epoch" \
    "installed_app=$INSTALLED_APP" \
    "evidence_directory=$RELEASE_EVIDENCE_DIR"
}

write_release_stage_status() {
  local status_file="$1"
  local stage="$2"
  local command_text="$3"
  local state="$4"
  local exit_status="$5"
  local stage_log="$6"
  local started_epoch="$7"
  local completed_epoch="$8"

  write_release_status_file \
    "$status_file" \
    "stage=$stage" \
    "command=$command_text" \
    "state=$state" \
    "exit_status=$exit_status" \
    "started_epoch=$started_epoch" \
    "completed_epoch=$completed_epoch" \
    "log=$stage_log"
}

finish_release_evidence() {
  local state="$1"
  local exit_status="$2"

  if [ "$state" != "passed" ]; then
    /bin/rm -f "$RELEASE_COMPLETION_MARKER" >/dev/null 2>&1 || true
    write_release_overall_status "$state" "$exit_status"
    return $?
  fi

  write_release_overall_status passed 0 || return $?
  write_release_status_file \
    "$RELEASE_COMPLETION_MARKER" \
    "workflow=$MODE" \
    "state=passed" \
    "stage_count=$RELEASE_STAGE_INDEX" \
    "overall_status=$RELEASE_EVIDENCE_DIR/overall.status"
}

forward_pending_release_signal_to_stage() {
  if [ "$RELEASE_SIGNAL_STATUS" -eq 0 ] \
    || [ -z "$RELEASE_ACTIVE_STAGE_PID" ] \
    || [ "$RELEASE_SIGNAL_FORWARDED" -eq 1 ]
  then
    return 0
  fi
  RELEASE_SIGNAL_FORWARDED=1
  if ! /bin/kill "-$RELEASE_SIGNAL_NAME" "-$RELEASE_ACTIVE_STAGE_PID" 2>/dev/null; then
    /bin/kill "-$RELEASE_SIGNAL_NAME" "$RELEASE_ACTIVE_STAGE_PID" 2>/dev/null || true
  fi
}

record_release_signal() {
  local signal_name="$1"
  local signal_status="$2"

  if [ "$RELEASE_SIGNAL_STATUS" -eq 0 ]; then
    RELEASE_SIGNAL_NAME="$signal_name"
    RELEASE_SIGNAL_STATUS="$signal_status"
  fi
  forward_pending_release_signal_to_stage
}

run_release_stage() {
  local stage="$1"
  shift
  local status
  local stage_key
  local stage_log
  local command_text=""
  local argument
  local stage_status
  local started_epoch
  local completed_epoch

  if [ "$RELEASE_SIGNAL_STATUS" -ne 0 ]; then
    return "$RELEASE_SIGNAL_STATUS"
  fi
  RELEASE_STAGE_INDEX=$((RELEASE_STAGE_INDEX + 1))
  stage_key="$(printf '%s' "$stage" | /usr/bin/tr -cs 'A-Za-z0-9._-' '-')"
  stage_log="$(printf '%s/%02d-%s.log' "$RELEASE_EVIDENCE_DIR" "$RELEASE_STAGE_INDEX" "$stage_key")"
  stage_status="${stage_log%.log}.status"
  for argument in "$@"; do
    command_text="$command_text$(printf '%q' "$argument") "
  done
  command_text="${command_text% }"
  started_epoch="$(/bin/date '+%s')" || return $?
  write_release_stage_status \
    "$stage_status" "$stage" "$command_text" running - "$stage_log" "$started_epoch" - || return $?

  echo "release stage start: stage=$stage command=$command_text log=$stage_log"
  set -m
  (
    "$@"
  ) >"$stage_log" 2>&1 &
  RELEASE_SIGNAL_FORWARDED=0
  RELEASE_ACTIVE_STAGE_PID="$!"
  set +m
  forward_pending_release_signal_to_stage
  while :; do
    if wait "$RELEASE_ACTIVE_STAGE_PID"; then
      status=0
    else
      status="$?"
    fi
    if /bin/kill -0 "$RELEASE_ACTIVE_STAGE_PID" >/dev/null 2>&1; then
      continue
    fi
    break
  done
  RELEASE_ACTIVE_STAGE_PID=""
  if [ "$RELEASE_SIGNAL_STATUS" -ne 0 ]; then
    status="$RELEASE_SIGNAL_STATUS"
  fi

  if [ "$status" -eq 0 ]; then
    completed_epoch="$(/bin/date '+%s')" || return $?
    write_release_stage_status \
      "$stage_status" "$stage" "$command_text" passed 0 "$stage_log" "$started_epoch" "$completed_epoch" || return $?
    echo "release stage passed: stage=$stage log=$stage_log"
    /usr/bin/grep -E '^(verified|transactionally|release install scenario:|TINYBUDDY_RELEASE_SNAPSHOT|xcodebuild succeeded:)' "$stage_log" \
      | /usr/bin/tail -n 40 || true
    return 0
  fi

  completed_epoch="$(/bin/date '+%s')" || return $?
  if ! write_release_stage_status \
    "$stage_status" "$stage" "$command_text" failed "$status" "$stage_log" "$started_epoch" "$completed_epoch"
  then
    echo "failed to persist status for release stage: $stage" >&2
  fi

  echo "release stage failed: stage=$stage exit=$status" >&2
  echo "failed command: $command_text" >&2
  echo "stage log: $stage_log" >&2
  echo "bounded failure evidence:" >&2
  /usr/bin/grep -E '(^|[[:space:]])(fatal )?error:|failed|timed out|unexpected|refusing|TINYBUDDY_RELEASE_SNAPSHOT_ERROR' "$stage_log" \
    | /usr/bin/tail -n 40 >&2 || true
  /usr/bin/tail -n 80 "$stage_log" >&2
  return "$status"
}

rollback_release_install() {
  local rollback_status=0
  local restored_previous=0
  local installed_identity=""
  local switched_before_rollback="$RELEASE_SWITCHED"
  local registration_attempted_before_rollback="${RELEASE_WIDGET_REGISTRATION_ATTEMPTED:-0}"

  trap - EXIT
  trap '' HUP INT TERM
  if [ -z "$RELEASE_TRANSACTION_DIR" ]; then
    return 0
  fi
  case "$RELEASE_TRANSACTION_DIR" in
    "$INSTALL_DIR/.TinyBuddy.install."*)
      ;;
    *)
      echo "refusing rollback with an invalid TinyBuddy transaction path" >&2
      return 1
      ;;
  esac
  if [ "$INSTALLED_APP" != "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "refusing rollback with an invalid TinyBuddy installed app path" >&2
    return 1
  fi
  if [ "${RELEASE_COMMITTED:-0}" -eq 1 ]; then
    echo "post-commit cleanup was interrupted; the verified installed release remains active and transaction recovery is required: $RELEASE_TRANSACTION_DIR" >&2
    return 1
  fi

  if [ "$RELEASE_SWITCHED" -eq 0 ] \
    && [ "$RELEASE_HAD_PREVIOUS" -eq 1 ] \
    && [ -n "${RELEASE_EXCHANGE_STATUS_FILE:-}" ] \
    && [ -f "$RELEASE_EXCHANGE_STATUS_FILE" ] \
    && /usr/bin/grep -Fqx \
      'TINYBUDDY_RELEASE_INSTALLER_EXCHANGED' \
      "$RELEASE_EXCHANGE_STATUS_FILE"
  then
    RELEASE_SWITCHED=1
  fi

  if [ "$RELEASE_SWITCHED" -eq 0 ] \
    && [ "$RELEASE_HAD_PREVIOUS" -eq 0 ] \
    && [ -n "${RELEASE_EXCHANGE_STATUS_FILE:-}" ] \
    && [ -f "$RELEASE_EXCHANGE_STATUS_FILE" ] \
    && /usr/bin/grep -Fqx \
      'TINYBUDDY_RELEASE_INSTALLER_INSTALLED' \
      "$RELEASE_EXCHANGE_STATUS_FILE"
  then
    RELEASE_SWITCHED=1
  fi

  if [ "$RELEASE_SWITCHED" -eq 0 ] \
    && [ "${RELEASE_EXCHANGE_IN_PROGRESS:-0}" -eq 1 ]
  then
    echo "atomic app exchange state is uncertain; preserving the release transaction for recovery" >&2
    rollback_status=1
  fi

  if [ "$rollback_status" -eq 0 ] && [ "$RELEASE_SWITCHED" -eq 1 ]; then
    if ! stop_release_runtime; then
      rollback_status=1
    elif [ "$RELEASE_HAD_PREVIOUS" -eq 1 ]; then
      if [ ! -d "$RELEASE_BACKUP_APP" ] || [ ! -d "$INSTALLED_APP" ]; then
        rollback_status=1
      elif atomic_exchange_release_apps "$RELEASE_BACKUP_APP" "$INSTALLED_APP"; then
        restored_previous=1
      else
        rollback_status=1
      fi
    else
      installed_identity="$(release_path_identity "$INSTALLED_APP" 2>/dev/null || true)"
      if [ -z "${RELEASE_STAGED_APP_IDENTITY:-}" ] \
        || [ "$installed_identity" != "$RELEASE_STAGED_APP_IDENTITY" ]
      then
        echo "refusing to remove an installed app that is not the staged clean-install candidate" >&2
        rollback_status=1
      elif ! /bin/rm -rf "$INSTALLED_APP"; then
        rollback_status=1
      fi
    fi
  fi

  if [ "$rollback_status" -eq 0 ]; then
    if [ "$restored_previous" -eq 1 ]; then
      restore_release_runtime || rollback_status=1
    elif [ "$RELEASE_SWITCHED" -eq 1 ] \
      && [ "${RELEASE_WIDGET_REGISTRATION_ATTEMPTED:-0}" -eq 1 ]
    then
      unregister_widget_extensions || rollback_status=1
    fi
  fi

  if [ "$rollback_status" -eq 0 ]; then
    /bin/rm -rf "$RELEASE_TRANSACTION_DIR" || rollback_status=1
  fi
  if [ "$rollback_status" -eq 0 ]; then
    RELEASE_TRANSACTION_DIR=""
    RELEASE_STAGED_APP=""
    RELEASE_BACKUP_APP=""
    RELEASE_HAD_PREVIOUS=0
    RELEASE_SWITCHED=0
    RELEASE_COMMITTED=0
    RELEASE_EXCHANGE_STATUS_FILE=""
    RELEASE_EXCHANGE_IN_PROGRESS=0
    RELEASE_STAGED_APP_IDENTITY=""
    RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
  fi

  if [ "$rollback_status" -eq 0 ]; then
    if [ "$restored_previous" -eq 1 ]; then
      echo "release install failed; rolled back to the previous installed app" >&2
    elif [ "$switched_before_rollback" -eq 1 ] \
      && [ "$registration_attempted_before_rollback" -eq 1 ]
    then
      echo "release clean install failed; removed the candidate app and Widget registration" >&2
    elif [ "$switched_before_rollback" -eq 1 ]; then
      echo "release clean install failed; removed the candidate app without changing Widget registrations" >&2
    else
      echo "release install failed before activation; cleaned the staged candidate" >&2
    fi
  else
    echo "release install failed and rollback was incomplete; recovery required at $RELEASE_TRANSACTION_DIR" >&2
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
  local allow_widget_registration_add=0

  verify_release_bundle "$INSTALLED_APP" || return $?
  verify_installed_matches_build || return $?
  if [ "${RELEASE_HAD_PREVIOUS:-0}" -eq 0 ] \
    && [ "${RELEASE_SWITCHED:-0}" -eq 1 ]
  then
    allow_widget_registration_add=1
  fi
  register_widget_extension \
    "$INSTALLED_APP" \
    "$allow_widget_registration_add" || return $?
  installed_appex="$(find_widget_extension "$INSTALLED_APP")"
  widget_executable="$installed_appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  saved_record_count="$(saved_git_scan_root_record_count)" || return $?
  case "$saved_record_count" in
    ''|*[!0-9]*) echo "could not determine saved Git authorization record count" >&2; return 2 ;;
  esac
  minimum_refresh_epoch="$(/usr/bin/stat -f '%m' "$app_executable")" || return $?
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

  RELEASE_VERIFIED_APP_PID=""
  RELEASE_VERIFIED_WIDGET_PID=""
  RELEASE_SNAPSHOT_SCHEMA=""
  RELEASE_SNAPSHOT_REVISION=""
  RELEASE_SNAPSHOT_DAY=""
  RELEASE_REFRESH_WIDGET_CONTENT_CHANGED=""
  RELEASE_REFRESH_WIDGET_RELOADED=""
  launch_installed_release_app || return $?
  wait_for_running_bundle_process "$APP_NAME" "$app_executable" "$rejected_app_pids" "$APP_RUNTIME_TIMEOUT" || return $?
  verify_hud_window "$RELEASE_VERIFIED_APP_PID" || return $?
  wait_for_running_bundle_process "$WIDGET_EXTENSION_NAME" "$widget_executable" "$rejected_widget_pids" "$WIDGET_RUNTIME_TIMEOUT" || return $?
  verify_installed_sandbox_bookmark_recovery \
    "$saved_record_count" \
    "$baseline_refresh_epoch" \
    "$minimum_refresh_epoch" || return $?
  verify_authorization_record_preservation \
    "${RELEASE_AUTHORIZATION_RECORD_COUNT_BEFORE:-$saved_record_count}" \
    "${RELEASE_AUTHORIZATION_RECORD_IDENTITY_BEFORE:-unverified}" || return $?
  verify_shared_snapshot_contract || return $?
  verify_hud_snapshot_consumption \
    "$RELEASE_VERIFIED_APP_PID" \
    "$RELEASE_SNAPSHOT_SCHEMA" \
    "$RELEASE_SNAPSHOT_REVISION" \
    "$RELEASE_SNAPSHOT_DAY" || return $?
  wait_for_running_bundle_process \
    "$WIDGET_EXTENSION_NAME" \
    "$widget_executable" \
    "$rejected_widget_pids" \
    "$WIDGET_RUNTIME_TIMEOUT" || return $?
  verify_widget_snapshot_consumption \
    "$RELEASE_VERIFIED_WIDGET_PID" \
    "$RELEASE_SNAPSHOT_SCHEMA" \
    "$RELEASE_SNAPSHOT_REVISION" \
    "$RELEASE_SNAPSHOT_DAY" \
    "$RELEASE_REFRESH_WIDGET_CONTENT_CHANGED" || return $?
  verify_running_bundle_process \
    "$RELEASE_VERIFIED_APP_PID" \
    "$APP_NAME" \
    "$app_executable" || return $?
  verify_running_bundle_process \
    "$RELEASE_VERIFIED_WIDGET_PID" \
    "$WIDGET_EXTENSION_NAME" \
    "$widget_executable" || return $?
  fingerprint="$(release_bundle_fingerprint "$INSTALLED_APP")" || return $?
  echo "verified installed and running release: $INSTALLED_APP ($fingerprint)"
}

activate_and_verify_release_app() {
  verify_release_app "$RELEASE_PREVIOUS_APP_PIDS" "$RELEASE_PREVIOUS_WIDGET_PIDS"
}

verify_release_app_fresh() {
  verify_release_bundle "$INSTALLED_APP" || return $?
  verify_installed_matches_build || return $?
  verify_widget_registration_preflight || return $?
  RELEASE_AUTHORIZATION_RECORD_COUNT_BEFORE="$(saved_git_scan_root_record_count)" || return $?
  RELEASE_AUTHORIZATION_RECORD_IDENTITY_BEFORE="$(saved_git_scan_root_record_identity)" || return $?
  capture_release_runtime || return $?
  stop_release_runtime || return $?
  verify_release_app "$RELEASE_PREVIOUS_APP_PIDS" "$RELEASE_PREVIOUS_WIDGET_PIDS"
}

install_release_app() {
  local activation_status

  validate_release_install_paths || return $?
  verify_widget_registration_preflight || return $?
  RELEASE_AUTHORIZATION_RECORD_COUNT_BEFORE="$(saved_git_scan_root_record_count)" || return $?
  RELEASE_AUTHORIZATION_RECORD_IDENTITY_BEFORE="$(saved_git_scan_root_record_identity)" || return $?
  RELEASE_TRANSACTION_DIR=""
  RELEASE_STAGED_APP=""
  RELEASE_BACKUP_APP=""
  RELEASE_EXCHANGE_STATUS_FILE=""
  RELEASE_HAD_PREVIOUS=0
  RELEASE_SWITCHED=0
  RELEASE_COMMITTED=0
  RELEASE_EXCHANGE_IN_PROGRESS=0
  RELEASE_STAGED_APP_IDENTITY=""
  RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
  if RELEASE_TRANSACTION_DIR="$(
    /usr/bin/mktemp -d "$INSTALL_DIR/.TinyBuddy.install.XXXXXXXX"
  )"
  then
    trap 'rollback_release_install' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
  else
    activation_status="$?"
    RELEASE_TRANSACTION_DIR=""
    return "$activation_status"
  fi
  RELEASE_STAGED_APP="$RELEASE_TRANSACTION_DIR/$APP_NAME.candidate"
  RELEASE_BACKUP_APP="$RELEASE_STAGED_APP"
  RELEASE_EXCHANGE_STATUS_FILE="$RELEASE_TRANSACTION_DIR/exchange.status"

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
  if RELEASE_STAGED_APP_IDENTITY="$(release_path_identity "$RELEASE_STAGED_APP")"; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi

  if capture_release_runtime; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi
  if stop_release_runtime; then
    :
  else
    activation_status="$?"
    rollback_release_install || true
    return "$activation_status"
  fi

  if [ -e "$INSTALLED_APP" ] || [ -L "$INSTALLED_APP" ]; then
    RELEASE_HAD_PREVIOUS=1
    RELEASE_EXCHANGE_IN_PROGRESS=1
    if atomic_exchange_release_apps \
      "$RELEASE_STAGED_APP" \
      "$INSTALLED_APP" >"$RELEASE_EXCHANGE_STATUS_FILE"
    then
      RELEASE_SWITCHED=1
      RELEASE_EXCHANGE_IN_PROGRESS=0
      /bin/cat "$RELEASE_EXCHANGE_STATUS_FILE"
    else
      activation_status="$?"
      case "$activation_status" in
        64|66|69|74)
          RELEASE_EXCHANGE_IN_PROGRESS=0
          ;;
        75)
          # The installer exchanged the bundles but could not confirm that its
          # in-process reverse exchange completed. Treat the canonical path as
          # switched so rollback either restores the previous bundle or leaves
          # the transaction intact for recovery.
          RELEASE_SWITCHED=1
          RELEASE_EXCHANGE_IN_PROGRESS=0
          ;;
        *)
          # A crash or non-protocol status can occur on either side of the
          # exchange. The EXIT rollback must preserve both paths rather than
          # guess and delete the only previous bundle.
          :
          ;;
      esac
      rollback_release_install || true
      return "$activation_status"
    fi
  else
    RELEASE_EXCHANGE_IN_PROGRESS=1
    if atomic_place_release_candidate \
      "$RELEASE_STAGED_APP" \
      "$INSTALLED_APP" >"$RELEASE_EXCHANGE_STATUS_FILE"
    then
      RELEASE_SWITCHED=1
      RELEASE_EXCHANGE_IN_PROGRESS=0
      /bin/cat "$RELEASE_EXCHANGE_STATUS_FILE"
    else
      activation_status="$?"
      case "$activation_status" in
        64|66|69|73|74)
          RELEASE_EXCHANGE_IN_PROGRESS=0
          ;;
        75)
          RELEASE_SWITCHED=1
          RELEASE_EXCHANGE_IN_PROGRESS=0
          ;;
        *)
          :
          ;;
      esac
      rollback_release_install || true
      return "$activation_status"
    fi
  fi

  if activate_and_verify_release_app; then
    RELEASE_COMMITTED=1
    trap - EXIT
    trap '' HUP INT TERM
    if /bin/rm -rf "$RELEASE_TRANSACTION_DIR"; then
      :
    else
      activation_status="$?"
      trap - HUP INT TERM
      echo "post-commit transaction cleanup failed; the verified installed release remains active and residue must be recovered: $RELEASE_TRANSACTION_DIR" >&2
      return "$activation_status"
    fi
    RELEASE_SWITCHED=0
    RELEASE_HAD_PREVIOUS=0
    RELEASE_COMMITTED=0
    RELEASE_TRANSACTION_DIR=""
    RELEASE_STAGED_APP=""
    RELEASE_BACKUP_APP=""
    RELEASE_EXCHANGE_STATUS_FILE=""
    RELEASE_EXCHANGE_IN_PROGRESS=0
    RELEASE_STAGED_APP_IDENTITY=""
    RELEASE_WIDGET_REGISTRATION_ATTEMPTED=0
    trap - HUP INT TERM
    echo "transactionally installed $INSTALLED_APP"
    return 0
  else
    activation_status="$?"
  fi

  rollback_release_install || true
  return "$activation_status"
}

run_release_acceptance_stages() {
  run_release_stage "swift-test" run_release_regression_tests || return $?
  run_release_stage "release-build" build_current_app || return $?
  run_release_stage "candidate-contract" verify_release_bundle "$APP_BUNDLE" || return $?
  run_release_stage "environment-preflight" verify_release_environment_preflight || return $?
  run_release_stage "primary-install" install_release_app || return $?
  run_release_stage "same-version-reinstall" install_same_version_release_app || return $?
  run_release_stage "final-fresh-verification" verify_release_app_fresh || return $?
}

run_release_install_stages() {
  run_release_stage "release-build" build_current_app || return $?
  run_release_stage "candidate-contract" verify_release_bundle "$APP_BUNDLE" || return $?
  run_release_stage "environment-preflight" verify_release_environment_preflight || return $?
  run_release_stage "transactional-install" install_release_app || return $?
}

run_release_verify_stages() {
  run_release_stage "release-build" build_current_app || return $?
  run_release_stage "candidate-contract" verify_release_bundle "$APP_BUNDLE" || return $?
  run_release_stage "environment-preflight" verify_release_environment_preflight || return $?
  run_release_stage "fresh-runtime-verification" verify_release_app_fresh || return $?
}

run_locked_release_workflow() {
  local workflow_function="$1"
  local workflow_status=0
  local lock_status=0

  acquire_release_lock || return $?
  RELEASE_ACTIVE_STAGE_PID=""
  RELEASE_SIGNAL_NAME=""
  RELEASE_SIGNAL_STATUS=0
  RELEASE_SIGNAL_FORWARDED=0
  trap 'release_release_lock >/dev/null 2>&1 || true' EXIT
  trap 'record_release_signal HUP 129' HUP
  trap 'record_release_signal INT 130' INT
  trap 'record_release_signal TERM 143' TERM

  if initialize_release_evidence; then
    :
  else
    workflow_status="$?"
  fi

  if [ "$workflow_status" -eq 0 ]; then
    if initialize_build_artifact_paths; then
      :
    else
      workflow_status="$?"
    fi
  fi

  if [ "$workflow_status" -eq 0 ]; then
    if "$workflow_function"; then
      :
    else
      workflow_status="$?"
    fi
  fi

  trap '' HUP INT TERM
  if [ "$workflow_status" -eq 0 ] && [ "$RELEASE_SIGNAL_STATUS" -ne 0 ]; then
    workflow_status="$RELEASE_SIGNAL_STATUS"
  fi

  if [ "$workflow_status" -ne 0 ] && [ -n "$RELEASE_EVIDENCE_DIR" ]; then
    if ! finish_release_evidence failed "$workflow_status"; then
      echo "failed to persist overall release failure evidence: $RELEASE_EVIDENCE_DIR" >&2
    fi
  fi

  if release_release_lock; then
    :
  else
    lock_status="$?"
    echo "failed to release TinyBuddy release workflow lock" >&2
  fi
  trap - EXIT HUP INT TERM

  if [ "$workflow_status" -ne 0 ]; then
    return "$workflow_status"
  fi
  if [ "$lock_status" -ne 0 ]; then
    if [ -n "$RELEASE_EVIDENCE_DIR" ]; then
      finish_release_evidence failed "$lock_status" || true
    fi
    return "$lock_status"
  fi
  if finish_release_evidence passed 0; then
    return 0
  else
    workflow_status="$?"
  fi

  echo "release stages passed but final evidence could not be committed: $RELEASE_EVIDENCE_DIR" >&2
  finish_release_evidence failed "$workflow_status" || true
  return "$workflow_status"
}

case "$MODE" in
  release-install|--release-install|release-verify|--release-verify|release-acceptance|--release-acceptance)
    ;;
  *)
    initialize_build_artifact_paths
    ;;
esac

case "$MODE" in
  release-acceptance|--release-acceptance)
    run_locked_release_workflow run_release_acceptance_stages
    echo "release acceptance passed: installed_app=$INSTALLED_APP evidence=$RELEASE_EVIDENCE_DIR"
    ;;
  release-install|--release-install)
    run_locked_release_workflow run_release_install_stages
    echo "release install passed: installed_app=$INSTALLED_APP evidence=$RELEASE_EVIDENCE_DIR"
    ;;
  release-verify|--release-verify)
    run_locked_release_workflow run_release_verify_stages
    echo "release verification passed: installed_app=$INSTALLED_APP evidence=$RELEASE_EVIDENCE_DIR"
    ;;
  run)
    build_current_app
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    ;;
  --debug|debug)
    build_current_app
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_current_app
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_current_app
    run_optional_git_pre_refresh
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"$BUNDLE_ID\" OR subsystem == \"local.tinybuddy\""
    ;;
  --verify|verify)
    build_current_app
    run_optional_git_pre_refresh
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    check_widget_runtime_source_match fail
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|release-install|release-verify|release-acceptance]" >&2
    exit 2
    ;;
esac
