#!/usr/bin/env bash
# tb-install.sh — TinyBuddy 构建 → 签名 → 安装 → 启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TinyBuddy"
SCHEME="$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
APP_GROUP="group.com.ryukeili.TinyBuddy"
DEVELOPMENT_TEAM="JYL9G28DP3"
XCODEPROJ="$ROOT/TinyBuddy.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/xcode}"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALL_APP="${INSTALL_APP:-/Applications/$APP_NAME.app}"
LOG_DIR="$ROOT/.build/logs"
SW_VERS_BIN="${SW_VERS_BIN:-/usr/bin/sw_vers}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-/usr/bin/xcodebuild}"
PLUGINKIT_BIN="${PLUGINKIT_BIN:-/usr/bin/pluginkit}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
PLIST_BUDDY_BIN="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
PROFILE_TEMP_DIR=""
USE_PROFILED_SIGNING=0
WIDGET_REGISTRATION_PRESERVED=0
INSTALL_APP_CREATED=0
INSTALL_COMMITTED=0

info()  { printf '\033[36m[tb]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[tb]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[tb] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  local exit_status=$?
  local rollback_candidate=""
  local rollback_failed=0
  trap - EXIT

  if [ "$INSTALL_COMMITTED" -eq 1 ]; then
    if [ -n "${BACKUP_DIR:-}" ] && [ -e "$BACKUP_DIR" ]; then
      rm -rf "$BACKUP_DIR" 2>/dev/null \
        || printf '[tb] WARNING: 安装已提交，旧版本备份仍保留在 %s\n' "$BACKUP_DIR" >&2
    fi
  elif [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR/$APP_NAME.app" ]; then
    rollback_candidate="$BACKUP_DIR/failed-$APP_NAME.app"
    if [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; then
      if ! mv "$INSTALL_APP" "$rollback_candidate"; then
        rollback_failed=1
        printf '[tb] ERROR: 无法移走未提交的安装；旧版本仍保留在 %s\n' \
          "$BACKUP_DIR/$APP_NAME.app" >&2
      fi
    fi

    if [ "$rollback_failed" -eq 0 ]; then
      if mv "$BACKUP_DIR/$APP_NAME.app" "$INSTALL_APP"; then
        rm -rf "$BACKUP_DIR" 2>/dev/null \
          || printf '[tb] WARNING: 已恢复旧版本，回滚目录仍保留在 %s\n' "$BACKUP_DIR" >&2
      else
        printf '[tb] ERROR: 无法恢复旧版本；备份仍保留在 %s\n' \
          "$BACKUP_DIR/$APP_NAME.app" >&2
      fi
    fi
  else
    if [ "$INSTALL_APP_CREATED" -eq 1 ] && { [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; }; then
      rm -rf "$INSTALL_APP" 2>/dev/null \
        || printf '[tb] WARNING: 未提交的新安装仍保留在 %s\n' "$INSTALL_APP" >&2
    fi
    [ -n "${BACKUP_DIR:-}" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true
  fi

  [ -n "$PROFILE_TEMP_DIR" ] && rm -rf "$PROFILE_TEMP_DIR" 2>/dev/null || true
  exit "$exit_status"
}
trap cleanup EXIT

MACOS_VERSION="$("$SW_VERS_BIN" -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
case "$MACOS_MAJOR" in
  ''|*[!0-9]*) fail "无法识别 macOS 版本: $MACOS_VERSION" ;;
esac

if [ "$MACOS_MAJOR" -ge 15 ]; then
  USE_PROFILED_SIGNING=1
  XCODEBUILD_SIGNING_ARGS=(-allowProvisioningUpdates)
else
  XCODEBUILD_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  # ── 查找签名身份 ────────────────────────────────────────────
  SIGN_IDENTITY="${SIGN_IDENTITY:-}"
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Apple Development/{print $2; exit}' || true)"
  fi
  [ -n "$SIGN_IDENTITY" ] || fail "未找到 Apple Development 签名身份"
fi

# 自动查找 entitlements
ENTITLEMENTS_APP=""
ENTITLEMENTS_WIDGET=""
while IFS= read -r f; do
  case "$(basename "$f")" in
    *Widget*|*widget*) ENTITLEMENTS_WIDGET="$f" ;;
    *) ENTITLEMENTS_APP="$f" ;;
  esac
done < <(find "$ROOT" -name "*.entitlements" -not -path "*/.git/*" 2>/dev/null)

# ── 0. 工程与源文件同步 ───────────────────────────────────
# project.yml 的 sources 以路径引用，新增源文件后 Xcode 目标的文件
# 列表不会自动更新，需重新生成 TinyBuddy.xcodeproj 才有新文件（否则
# 编译报 "cannot find 'X' in scope"）。仅在工程过期（project.yml 或任一
# 源文件比 pbxproj 新）且本机装有 xcodegen 时重新生成，避免无关 churn。
XCODEGEN_BIN="$(command -v xcodegen 2>/dev/null || true)"
PBXPROJ="$XCODEPROJ/project.pbxproj"
STALE_INPUT="$(find "$ROOT/project.yml" "$ROOT/Sources" "$ROOT/Widget" "$ROOT/Tests" \
  -type f \( -name "*.swift" -o -name "*.yml" \) -newer "$PBXPROJ" -print 2>/dev/null | head -1)"
if [ -n "$XCODEGEN_BIN" ] && [ -n "$STALE_INPUT" ]; then
  info "工程过期（$STALE_INPUT 更新于 ${PBXPROJ}），重新生成 Xcode 工程 ..."
  ( cd "$ROOT" && "$XCODEGEN_BIN" generate ) || fail "xcodegen generate 失败：请安装 xcodegen 或手动运行它"
fi

registered_widget_paths() {
  "$PLUGINKIT_BIN" -m -A -D -v -i "$WIDGET_BUNDLE_ID" \
    | awk -F '\t' 'NF >= 2 { path = $NF; sub(/^[[:space:]]+/, "", path); sub(/[[:space:]]+$/, "", path); if (path ~ /\.appex$/) print path }'
}

verify_widget_registration_preflight() {
  local expected_path="$INSTALL_APP/Contents/PlugIns/TinyBuddyWidgetExtension.appex"
  local paths
  local count

  paths="$(registered_widget_paths)" || return $?
  count="$(printf '%s\n' "$paths" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [ -d "$INSTALL_APP" ] \
    && [ "$count" -eq 1 ] \
    && [ "$paths" = "$expected_path" ]
  then
    WIDGET_REGISTRATION_PRESERVED=1
    return 0
  fi
  if { [ ! -e "$INSTALL_APP" ] && [ ! -L "$INSTALL_APP" ]; } && [ "$count" -eq 0 ]; then
    return 0
  fi

  fail "现有 WidgetKit 注册状态不唯一或路径不匹配；请先修复 PlugInKit 注册后再安装"
}

verify_provisioned_app_group() {
  local bundle="$1"
  local bundle_id="$2"
  local profile="$bundle/Contents/embedded.provisionprofile"
  local decoded="$PROFILE_TEMP_DIR/profile.plist"
  local app_identifier
  local groups

  [ -f "$profile" ] || fail "缺少 provisioning profile: $(basename "$bundle")"
  "$SECURITY_BIN" cms -D -i "$profile" >"$decoded" \
    || fail "无法解码 provisioning profile: $(basename "$bundle")"
  app_identifier="$("$PLIST_BUDDY_BIN" -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || true)"
  groups="$("$PLIST_BUDDY_BIN" -c 'Print :Entitlements:com.apple.security.application-groups' "$decoded" 2>/dev/null || true)"
  [ "$app_identifier" = "$DEVELOPMENT_TEAM.$bundle_id" ] \
    || fail "provisioning profile 的应用标识不匹配: $(basename "$bundle")"
  printf '%s\n' "$groups" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -Fqx "$APP_GROUP" \
    || fail "provisioning profile 未授权预期 App Group: $(basename "$bundle")"
}

verify_built_widget_extension() {
  local widget=""
  local candidate
  local bundle_count=0
  local bundle_id
  local extension_point

  for candidate in "$BUILD_APP"/Contents/PlugIns/*.appex; do
    [ -d "$candidate" ] || continue
    bundle_count=$((bundle_count + 1))
    widget="$candidate"
  done
  [ "$bundle_count" -eq 1 ] || fail "构建产物必须包含且只包含一个 Widget 扩展"

  [ -f "$widget/Contents/Info.plist" ] || fail "Widget 扩展缺少 Info.plist"
  bundle_id="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$widget/Contents/Info.plist" 2>/dev/null)" \
    || fail "无法读取 Widget 扩展 bundle identifier"
  [ "$bundle_id" = "$WIDGET_BUNDLE_ID" ] || fail "构建产物中的 Widget bundle identifier 不匹配"
  extension_point="$("$PLIST_BUDDY_BIN" -c 'Print :NSExtension:NSExtensionPointIdentifier' "$widget/Contents/Info.plist" 2>/dev/null)" \
    || fail "无法读取 Widget 扩展类型"
  [ "$extension_point" = "com.apple.widgetkit-extension" ] \
    || fail "构建产物不是预期的 WidgetKit 扩展"
}

# 失败的重复注册必须在构建、安装或替换之前明确暴露。
verify_widget_registration_preflight

# ── 1. 构建 ───────────────────────────────────────────────────
info "构建 $APP_NAME ..."
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

"$XCODEBUILD_BIN" -project "$XCODEPROJ" -scheme "$SCHEME" \
  -configuration Debug -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS" \
  "${XCODEBUILD_SIGNING_ARGS[@]}" \
  build 2>&1 | tee "$LOG" | tail -3

[ -d "$BUILD_APP" ] || fail "构建产物未找到: $BUILD_APP"
verify_built_widget_extension
ok "构建完成: $BUILD_APP"

# ── 2. 签名 ───────────────────────────────────────────────────
info "验证签名 ..."

if [ "$USE_PROFILED_SIGNING" -eq 1 ]; then
  PROFILE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-profiles.XXXXXX")"
  verify_provisioned_app_group "$BUILD_APP" "$BUNDLE_ID"
  for widget in "$BUILD_APP"/Contents/PlugIns/*.appex; do
    [ -d "$widget" ] || continue
    verify_provisioned_app_group "$widget" "$WIDGET_BUNDLE_ID"
  done
else
  # 移除测试 bundle
  rm -rf "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" 2>/dev/null || true

  # 签名 Widget Extension
  for widget in "$BUILD_APP"/Contents/PlugIns/*.appex; do
    [ -d "$widget" ] || continue
    wname="$(basename "$widget")"
    if [ -f "$ENTITLEMENTS_WIDGET" ]; then
      codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
        --entitlements "$ENTITLEMENTS_WIDGET" "$widget"
    else
      codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
        --generate-entitlement-der "$widget"
    fi
    ok "签名 widget: $wname"
  done

  # 签名主应用
  if [ -f "$ENTITLEMENTS_APP" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --entitlements "$ENTITLEMENTS_APP" "$BUILD_APP"
  else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --generate-entitlement-der "$BUILD_APP"
  fi
fi
codesign --verify --deep --strict --verbose=2 "$BUILD_APP" 2>&1 | tail -1
ok "签名验证通过"

# ── 3. 安装 ───────────────────────────────────────────────────
info "安装到 $INSTALL_APP ..."

# 关闭正在运行的旧实例
OLD_PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ]; then
  kill $OLD_PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  REMAINING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [ -z "$REMAINING" ] || { kill -KILL $REMAINING 2>/dev/null || true; sleep 0.5; }
fi

mkdir -p "$(dirname "$INSTALL_APP")"
if [ -d "$INSTALL_APP" ]; then
  BACKUP_DIR="$(mktemp -d "$(dirname "$INSTALL_APP")/.${APP_NAME}-backup.XXXXXX")"
  mv "$INSTALL_APP" "$BACKUP_DIR/$APP_NAME.app"
fi

INSTALL_APP_CREATED=1
ditto "$BUILD_APP" "$INSTALL_APP"

# 注册 Widget Extension
if [ "$WIDGET_REGISTRATION_PRESERVED" -eq 0 ]; then
  "$PLUGINKIT_BIN" -a "$INSTALL_APP/Contents/PlugIns/"*.appex
fi
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "$INSTALL_APP"
registered_after_install="$(registered_widget_paths)"
registered_count="$(printf '%s\n' "$registered_after_install" | awk 'NF { count += 1 } END { print count + 0 }')"
[ "$registered_count" -eq 1 ] \
  && [ "$registered_after_install" = "$INSTALL_APP/Contents/PlugIns/TinyBuddyWidgetExtension.appex" ] \
  || fail "安装后 WidgetKit 注册未唯一指向当前 App"
ok "已安装: $INSTALL_APP"

# ── 4. 启动 ───────────────────────────────────────────────────
info "启动 ..."
open -n "$INSTALL_APP"
for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 && break; sleep 0.25; done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "启动失败"
INSTALL_COMMITTED=1
ok "$APP_NAME 运行中"
