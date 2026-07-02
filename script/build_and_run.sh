#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TinyBuddy"
WIDGET_EXTENSION_NAME="TinyBuddyWidgetExtension"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
WIDGET_EXTENSION_POINT="com.apple.widgetkit-extension"

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

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

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

verify_widget_extension() {
  local app_bundle="$1"
  local appex
  local plist
  local bundle_id
  local extension_point

  appex="$(find_widget_extension "$app_bundle")"
  if [ -z "$appex" ]; then
    echo "missing $WIDGET_EXTENSION_NAME.appex in $app_bundle" >&2
    exit 1
  fi

  plist="$appex/Contents/Info.plist"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist")"

  if [ "$bundle_id" != "$WIDGET_BUNDLE_ID" ]; then
    echo "unexpected widget bundle id: $bundle_id" >&2
    exit 1
  fi

  if [ "$extension_point" != "$WIDGET_EXTENSION_POINT" ]; then
    echo "unexpected widget extension point: $extension_point" >&2
    exit 1
  fi

  /usr/bin/codesign --verify --strict --verbose=2 "$appex"
  /usr/bin/pluginkit -r "$appex" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -a "$appex"

  if ! /usr/bin/pluginkit -m -A -p "$WIDGET_EXTENSION_POINT" | /usr/bin/grep -F "$WIDGET_BUNDLE_ID" >/dev/null; then
    echo "$WIDGET_BUNDLE_ID is not registered with PlugInKit" >&2
    exit 1
  fi

  echo "verified widget extension: $appex"
}

widget_executable_hash() {
  local appex="$1"
  local executable="$appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"

  if [ ! -f "$executable" ]; then
    echo "missing widget executable: $executable" >&2
    exit 1
  fi

  /usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}'
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

install_release_app() {
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  echo "installed $INSTALLED_APP"
}

verify_release_app() {
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
  verify_widget_extension "$INSTALLED_APP"
}

case "$MODE" in
  run)
    update_git_completion_count
    check_widget_runtime_source_match warn
    open_app
    ;;
  --debug|debug)
    update_git_completion_count
    check_widget_runtime_source_match warn
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    update_git_completion_count
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    update_git_completion_count
    check_widget_runtime_source_match warn
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    update_git_completion_count
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    check_widget_runtime_source_match fail
    ;;
  release-install|--release-install)
    update_git_completion_count
    install_release_app
    verify_release_app
    ;;
  release-verify|--release-verify)
    update_git_completion_count
    verify_release_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|release-install|release-verify]" >&2
    exit 2
    ;;
esac
