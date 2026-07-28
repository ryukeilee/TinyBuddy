#!/usr/bin/env bash
# build-and-install.sh — TinyBuddy
#
# codesign 手动签名构建并安装到 /Applications。
# 适用于 Xcode 命令行无 accounts 配置的环境（免费 Apple ID）。
#
# 用法:
#   ./script/build-and-install.sh
#   DEVPULSE_SIGNING_IDENTITY=<hash> ./script/build-and-install.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR"
XCODEPROJ="$PROJECT_DIR/TinyBuddy.xcodeproj"
SCHEME="TinyBuddy"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/tinybuddy-build}"
BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/TinyBuddy.app"
INSTALL_APP="/Applications/TinyBuddy.app"
APP_BUNDLE_ID="com.ryukeili.TinyBuddy"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddyWidgetExtension"
APP_GROUP="group.com.ryukeili.TinyBuddy"

info()  { printf '\033[36m%s\033[0m\n' "$1"; }
ok()    { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; exit 1; }

resolve_signing_identity() {
    if [ -n "${DEVPULSE_SIGNING_IDENTITY:-}" ]; then
        echo "$DEVPULSE_SIGNING_IDENTITY"
        return
    fi
    local line
    line="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n '/Apple Development:/{s/^[[:space:]]*[0-9]*)[[:space:]]*//;s/[[:space:]]*$//;p;q}')"
    [ -n "$line" ] || fail "No Apple Development signing identity. Set DEVPULSE_SIGNING_IDENTITY."
    echo "$line"
}

resolve_team() {
    echo "$1" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p'
}

stop_running_app() {
    local pids
    pids="$(pgrep -x TinyBuddy 2>/dev/null || true)"
    [ -z "$pids" ] && return
    info "Stopping running TinyBuddy…"
    kill "$pids" 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x TinyBuddy >/dev/null 2>&1 || return 0
        sleep 0.25
    done
    fail "TinyBuddy did not exit."
}

build_unsigned() {
    info "Building (unsigned)…"
    xcodebuild -project "$XCODEPROJ" \
        -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        build 2>&1 | tail -5
    [ -d "$BUILD_APP" ] || fail "Build product not found at $BUILD_APP"
    ok "Build succeeded"
}

sign_bundle() {
    local identity="$1"
    local team="$2"
    info "Signing…"

    local widget_path="$BUILD_APP/Contents/PlugIns/TinyBuddyWidgetExtension.appex"

    # 如果项目没有 Widget Extension 则跳过
    local has_widget=false
    [ -d "$widget_path" ] && has_widget=true

    local app_entitlements="/tmp/tinybuddy-app-entitlements.plist"
    cat > "$app_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$APP_GROUP</string>
    </array>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
PLIST

    if $has_widget; then
        local widget_entitlements="/tmp/tinybuddy-widget-entitlements.plist"
        cat > "$widget_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$APP_GROUP</string>
    </array>
</dict>
</plist>
PLIST

        codesign --force --sign "$identity" \
            --entitlements "$widget_entitlements" \
            --verbose "$widget_path" 2>&1 | sed 's/^/  /'
        ok "Widget Extension signed"
    fi

    codesign --force --sign "$identity" \
        --entitlements "$app_entitlements" \
        --verbose "$BUILD_APP" 2>&1 | sed 's/^/  /'
    ok "App signed"

    local app_team
    app_team="$(codesign -dvvv "$BUILD_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    ok "Signed with Team $app_team"
}

install_app() {
    info "Installing to $INSTALL_APP …"
    if [ -d "$INSTALL_APP" ]; then rm -rf "$INSTALL_APP"; fi
    cp -R "$BUILD_APP" "$INSTALL_APP"
    ok "Installed"
}

launch_app() {
    info "Launching…"
    open "$INSTALL_APP"
    sleep 3
    if pgrep -x TinyBuddy >/dev/null 2>&1; then
        ok "App is running (PID $(pgrep -x TinyBuddy))"
    else
        fail "App failed to launch"
    fi
}

main() {
    info "=== TinyBuddy Build & Install ==="
    local identity team
    identity="$(resolve_signing_identity)"
    team="$(resolve_team "$identity")"
    ok "Identity: $identity"
    ok "Team: $team"
    stop_running_app
    build_unsigned
    sign_bundle "$identity" "$team"
    install_app
    launch_app
    echo ""; info "=== Done ==="
}

main "$@"
