#!/usr/bin/env bash
# tb-install.sh — TinyBuddy 构建 → 签名 → 安装 → 启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TinyBuddy"
SCHEME="$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
APP_GROUP="group.com.ryukeili.TinyBuddy"
XCODEPROJ="$ROOT/TinyBuddy.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/xcode}"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALL_APP="${INSTALL_APP:-/Applications/$APP_NAME.app}"
LOG_DIR="$ROOT/.build/logs"

info()  { printf '\033[36m[tb]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[tb]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[tb] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() { [ -n "${BACKUP_DIR:-}" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ── 查找签名身份 ──────────────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/{print $2; exit}' || true)"
fi
[ -n "$SIGN_IDENTITY" ] || fail "未找到 Apple Development 签名身份"

# 自动查找 entitlements
ENTITLEMENTS_APP=""
ENTITLEMENTS_WIDGET=""
while IFS= read -r f; do
  case "$(basename "$f")" in
    *Widget*|*widget*) ENTITLEMENTS_WIDGET="$f" ;;
    *) ENTITLEMENTS_APP="$f" ;;
  esac
done < <(find "$ROOT" -name "*.entitlements" -not -path "*/.git/*" 2>/dev/null)

# ── 1. 构建 ───────────────────────────────────────────────────
info "构建 $APP_NAME ..."
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
  -configuration Debug -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee "$LOG" | tail -3

[ -d "$BUILD_APP" ] || fail "构建产物未找到: $BUILD_APP"
ok "构建完成: $BUILD_APP"

# ── 2. 签名 ───────────────────────────────────────────────────
info "签名 ..."

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

if [ -d "$INSTALL_APP" ]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-backup.XXXXXX")"
  mv "$INSTALL_APP" "$BACKUP_DIR/$APP_NAME.app"
fi

mkdir -p "$(dirname "$INSTALL_APP")"
ditto "$BUILD_APP" "$INSTALL_APP"

# 注册 Widget Extension
pluginkit -a "$INSTALL_APP/Contents/PlugIns/"*.appex 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "$INSTALL_APP" 2>/dev/null || true
ok "已安装: $INSTALL_APP"

# ── 4. 启动 ───────────────────────────────────────────────────
info "启动 ..."
open -n "$INSTALL_APP"
for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 && break; sleep 0.25; done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "启动失败"
ok "$APP_NAME 运行中"
