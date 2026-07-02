#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TinyBuddy"
WIDGET_EXTENSION_NAME="TinyBuddyWidgetExtension"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
WIDGET_EXTENSION_POINT="com.apple.widgetkit-extension"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode"
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
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
INSTALL_DIR="${TINYBUDDY_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

patch_swift_objc_header_phase() {
  local project_file="$ROOT_DIR/TinyBuddy.xcodeproj/project.pbxproj"

  if [ ! -f "$project_file" ]; then
    return 0
  fi

  /usr/bin/perl -pi -e 's/ditto \\"\$\{SCRIPT_INPUT_FILE_0\}\\" \\"\$\{SCRIPT_OUTPUT_FILE_0\}\\"/cp \\"\$\{SCRIPT_INPUT_FILE_0\}\\" \\"\$\{SCRIPT_OUTPUT_FILE_0\}\\"/g' "$project_file"

}

patch_swift_objc_header_phase

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
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  release-install|--release-install)
    install_release_app
    verify_release_app
    ;;
  release-verify|--release-verify)
    verify_release_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|release-install|release-verify]" >&2
    exit 2
    ;;
esac
