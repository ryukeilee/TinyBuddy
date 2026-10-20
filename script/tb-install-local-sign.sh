#!/usr/bin/env bash
# tb-install-local-sign.sh — TinyBuddy 本机开发安装（无账号、无 profile）
#
# 仅用于本机开发调试：无签名构建，再用本机的 Apple Development 身份按仓库自带的
# entitlements 文件依次签 Widget Extension 与主 App，最后安装到
# /Applications/TinyBuddy.app 并启动。
#
# 产物内不含任何 provisioning profile，因此：
#   * 不可分发，不可 notarize（公证/分发必须走带 profile 的签名流程）；
#   * 只在能接受该 Apple Development 身份的机器上运行；
#   * App Group 权限由 entitlements 直接授予，未经过 profile 校验。
#
# 存在意义：免费 Personal Team（isFreeProvisioningTeam=1）无法签发带 App Group
# 授权的 profile，标准流程 script/tb-install.sh 在 macOS 15+ 会因 “No profiles
# for 'com.ryukeili.TinyBuddy'” 直接失败。标准路径仍然是 script/tb-install.sh
# （需要与 App Group 匹配的 App/Widget profiles）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="TinyBuddy"
SCHEME="$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"
APP_GROUP="group.com.ryukeili.TinyBuddy"
XCODEPROJ="$ROOT/TinyBuddy.xcodeproj"
ENTITLEMENTS_APP="$ROOT/Resources/TinyBuddyApp/TinyBuddy.entitlements"
ENTITLEMENTS_WIDGET="$ROOT/Resources/TinyBuddyWidget/TinyBuddyWidget.entitlements"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.build/xcode}"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALL_APP="${INSTALL_APP:-/Applications/$APP_NAME.app}"
LOG_DIR="${LOG_DIR:-$ROOT/.build/logs}"
PLIST_BUDDY_BIN="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
BACKUP_DIR=""
ENTITLEMENTS_TEMP_DIR=""
ENTITLEMENTS_SEQ=0
INSTALL_PREEXISTING=0
INSTALL_STARTED=0
# 安装互斥锁：与安装路径同级，整个“备份+复制+启动校验+回滚”窗口独占。
# LOCK_HELD 只在 mkdir 成功后置 1，因此加锁前的任何失败（含加锁失败本身）都不会
# 让 cleanup 删掉别人的锁。
LOCK_DIR="$(dirname "${INSTALL_APP:-}")/.${APP_NAME}.install.lock"
LOCK_HELD=0

info() { printf '\033[36m[tb]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[tb]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[tb] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# 断言签名后的 entitlements 真的带上了沙箱与 App Group 授权。
# 缺任何一个都说明 entitlements 文件被静默丢弃，此时 App Group 容器不可用。
# 取值用 PlistBuddy 精确比对，不做 substring 匹配（注释或相邻键里的同名文本会
# 让 grep 假通过）。dump 共用同一个临时目录，由 cleanup 兜底删除。
assert_entitlements() {
  local target="$1" label="$2" dump="" sandbox="" group_entry="" index=0 found=0
  if [ -z "$ENTITLEMENTS_TEMP_DIR" ]; then
    ENTITLEMENTS_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tb-entitlements.XXXXXX")" \
      || fail "无法创建 entitlements 临时目录"
  fi
  ENTITLEMENTS_SEQ=$((ENTITLEMENTS_SEQ + 1))
  dump="$ENTITLEMENTS_TEMP_DIR/entitlements-$ENTITLEMENTS_SEQ.plist"
  codesign -d --entitlements :- "$target" >"$dump" 2>/dev/null \
    || fail "$label 无法读取签名后的 entitlements（entitlements 可能被静默丢弃）"
  [ -s "$dump" ] || fail "$label 签名后的 entitlements 为空"

  sandbox="$("$PLIST_BUDDY_BIN" -c 'Print :com.apple.security.app-sandbox' "$dump" 2>/dev/null)" \
    || fail "$label 签名后缺少 com.apple.security.app-sandbox"
  [ "$sandbox" = "true" ] \
    || fail "$label 的 com.apple.security.app-sandbox 不是 true（实际 '$sandbox'）"

  while [ "$index" -lt 32 ] \
    && group_entry="$("$PLIST_BUDDY_BIN" -c "Print :com.apple.security.application-groups:$index" "$dump" 2>/dev/null)"; do
    if [ "$group_entry" = "$APP_GROUP" ]; then
      found=1
      break
    fi
    index=$((index + 1))
  done
  [ "$found" -eq 1 ] \
    || fail "$label 的 com.apple.security.application-groups 不含 $APP_GROUP"
}

# 回滚：安装阶段任何一步失败都撤掉新产物并还原旧版本；成功启动后才删除备份。
#
# 关键约束：只有在“新安装确实被移除”或“安装路径原本没有旧版本”时才允许还原。
# 否则 mv 会把旧 bundle 移到 $INSTALL_APP 内部（bundle 套 bundle），打印“已回滚”
# 而实际上安装入口已损坏、唯一副本被埋进子目录。任何无法完成还原的分支都必须
# 保留备份目录并打印它的绝对路径。
#
# 并发危险（本文件的锁就是为它存在的）：两个安装同时运行时，A 备份旧包并安装，
# A 的启动校验失败，A 在 cleanup 里删掉自己的新产物；此时 B 的 ditto 又把
# $INSTALL_APP 重新创建出来，A 的 mv 于是把旧包塞进 $INSTALL_APP/TinyBuddy.app，
# 旧的“目录存在即通过”检查还会放行，A 删掉备份并打印“已回滚”——安装入口坏掉、
# 唯一副本被埋。锁消除了这个交错，下面的还原校验作为第二道独立防线。
cleanup() {
  local exit_status=$?
  local backup_app="$BACKUP_DIR/$APP_NAME.app"
  local restored_ok=0
  trap - EXIT

  # 锁必须在每一条退出路径（成功、早期失败、回滚）上释放，所以放在 exit_status
  # 分支之前。锁目录只是个空目录：进程被 SIGKILL 后留下的陈旧锁，在确认没有其他
  # 安装进程运行时手工删除该目录即可恢复（提示信息见加锁处）。
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null \
      || printf '[tb] WARNING: 未能删除锁目录 %s\n' "$LOCK_DIR" >&2
  fi

  if [ -n "$ENTITLEMENTS_TEMP_DIR" ] && [ -e "$ENTITLEMENTS_TEMP_DIR" ]; then
    rm -rf "$ENTITLEMENTS_TEMP_DIR" 2>/dev/null || true
    ENTITLEMENTS_TEMP_DIR=""
  fi

  if [ "$exit_status" -eq 0 ]; then
    if [ -n "$BACKUP_DIR" ]; then
      rm -rf "$BACKUP_DIR" 2>/dev/null \
        || printf '[tb] WARNING: 旧版本备份未删除，仍在 %s\n' "$BACKUP_DIR" >&2
    fi
    exit 0
  fi

  # 还没进入安装阶段：旧安装从未被移动，既不删除也不还原。
  if [ "$INSTALL_STARTED" -eq 0 ]; then
    exit "$exit_status"
  fi

  # 备份目录没建立（mktemp 失败等）：只清理可能写了一半的新产物，不动原有安装。
  if [ -z "$BACKUP_DIR" ]; then
    if [ "$INSTALL_PREEXISTING" -eq 0 ] \
      && { [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; }; then
      rm -rf "$INSTALL_APP" 2>/dev/null \
        || printf '[tb] WARNING: 未提交的新安装仍保留在 %s\n' "$INSTALL_APP" >&2
    fi
    exit "$exit_status"
  fi

  # 备份内容不在：旧版本可能还在安装路径或已被破坏，绝不删除安装路径。
  if [ ! -e "$backup_app" ] && [ ! -L "$backup_app" ]; then
    printf '[tb] ERROR: 备份不存在（%s），无法回滚；安装路径 %s 保持现状，请手工确认\n' \
      "$backup_app" "$INSTALL_APP" >&2
    exit "$exit_status"
  fi

  # 第一步：移走未提交的新安装。移不掉就完全不还原，只保留备份并报错。
  if [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; then
    if ! rm -rf "$INSTALL_APP"; then
      printf '[tb] ERROR: 无法移除未提交的新安装 %s；未执行回滚，旧版本备份仍保留在 %s\n' \
        "$INSTALL_APP" "$backup_app" >&2
      exit "$exit_status"
    fi
  fi

  # 第二步：还原（目录与符号链接都用 mv），并确认真的落到了安装路径上。
  if ! mv "$backup_app" "$INSTALL_APP"; then
    printf '[tb] ERROR: 无法还原旧版本；旧版本备份仍保留在 %s\n' "$backup_app" >&2
    exit "$exit_status"
  fi
  # 路径存在，且作为目录必须真的含 Contents/MacOS/$APP_NAME 可执行文件。只判断
  # “目录存在”会放过 bundle 套 bundle 的形状（$INSTALL_APP/TinyBuddy.app），因此
  # 这里独立复核还原结果；不合格就不删备份。
  if [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; then
    if [ -d "$INSTALL_APP" ] && [ -f "$INSTALL_APP/Contents/MacOS/$APP_NAME" ]; then
      restored_ok=1
    fi
  fi
  if [ "$restored_ok" -eq 0 ]; then
    printf '[tb] ERROR: 还原后 %s 不是有效的 %s bundle（缺少 Contents/MacOS/%s）；旧版本备份仍保留在 %s\n' \
      "$INSTALL_APP" "$APP_NAME" "$APP_NAME" "$backup_app" >&2
    exit "$exit_status"
  fi

  rm -rf "$BACKUP_DIR" 2>/dev/null \
    || printf '[tb] WARNING: 已还原旧版本，但备份目录仍保留在 %s\n' "$BACKUP_DIR" >&2
  printf '[tb] 已回滚到安装前的版本: %s\n' "$INSTALL_APP" >&2
  exit "$exit_status"
}

# EXIT trap 在任何备份/安装动作之前安装：不存在“旧版本已被移入备份目录、但 trap
# 还没登记”的窗口。回滚本身由 cleanup 里的 INSTALL_STARTED / BACKUP_DIR /
# INSTALL_PREEXISTING 状态位门控，未进入安装阶段时不会删除或还原任何东西。
trap cleanup EXIT

# ── 1. 签名身份 ───────────────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/{print $2; exit}' || true)"
fi
[ -n "$SIGN_IDENTITY" ] \
  || fail "未找到 Apple Development 签名身份；请先在 Xcode 登录 Apple ID 或显式设置 SIGN_IDENTITY"
info "签名身份: $SIGN_IDENTITY"

# ── 2. entitlements ──────────────────────────────────────────
[ -f "$ENTITLEMENTS_APP" ] \
  || fail "缺少 App entitlements: ${ENTITLEMENTS_APP#"$ROOT"/}"
[ -f "$ENTITLEMENTS_WIDGET" ] \
  || fail "缺少 Widget entitlements: ${ENTITLEMENTS_WIDGET#"$ROOT"/}"

# ── 3. 工程与源文件同步 ───────────────────────────────────────
# project.yml 的 sources 以路径引用，新增源文件后 Xcode 目标的文件列表不会自动
# 更新，需重新生成 TinyBuddy.xcodeproj 才有新文件（否则编译报
# "cannot find 'X' in scope"）。仅在工程过期（project.yml 或任一源文件比 pbxproj
# 新）且本机装有 xcodegen 时重新生成，避免无关 churn。
XCODEGEN_BIN="$(command -v xcodegen 2>/dev/null || true)"
PBXPROJ="$XCODEPROJ/project.pbxproj"
if [ ! -f "$PBXPROJ" ]; then
  [ -n "$XCODEGEN_BIN" ] || fail "缺少 TinyBuddy.xcodeproj 且未安装 xcodegen；请运行 xcodegen generate"
  info "缺少 TinyBuddy.xcodeproj，重新生成 ..."
  ( cd "$ROOT" && "$XCODEGEN_BIN" generate ) || fail "xcodegen generate 失败"
else
  STALE_INPUT="$(find "$ROOT/project.yml" "$ROOT/Sources" "$ROOT/Widget" "$ROOT/Tests" \
    -type f \( -name "*.swift" -o -name "*.yml" \) -newer "$PBXPROJ" -print 2>/dev/null | head -1)"
  if [ -n "$XCODEGEN_BIN" ] && [ -n "$STALE_INPUT" ]; then
    info "工程过期（$STALE_INPUT 更新于 project.pbxproj），重新生成 Xcode 工程 ..."
    ( cd "$ROOT" && "$XCODEGEN_BIN" generate ) \
      || fail "xcodegen generate 失败：请安装 xcodegen 或手动运行它"
  fi
fi

# ── 4. 无签名构建 ─────────────────────────────────────────────
info "构建 $APP_NAME （CODE_SIGNING_ALLOWED=NO）..."
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/local-sign-build-$(date +%Y%m%d-%H%M%S).log"
set +e
xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
  -configuration Debug -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$LOG" | tail -3
BUILD_STATUS="${PIPESTATUS[0]}"
set -e
if [ "$BUILD_STATUS" -ne 0 ]; then
  printf '[tb] ERROR: 构建失败；完整日志: %s\n' "$LOG" >&2
  exit 1
fi
[ -s "$LOG" ] || fail "构建日志未写入: $LOG"
[ -d "$BUILD_APP" ] || fail "构建产物未找到: $BUILD_APP"
ok "构建完成: $BUILD_APP"

# ── 5. 校验构建产物 ───────────────────────────────────────────
rm -rf "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" 2>/dev/null || true
WIDGET_APPEX=""
APPEX_COUNT=0
for candidate in "$BUILD_APP"/Contents/PlugIns/*.appex; do
  [ -d "$candidate" ] || continue
  APPEX_COUNT=$((APPEX_COUNT + 1))
  WIDGET_APPEX="$candidate"
done
[ "$APPEX_COUNT" -eq 1 ] || fail "构建产物必须包含且只包含一个 .appex，实际 $APPEX_COUNT 个"
[ -f "$WIDGET_APPEX/Contents/Info.plist" ] || fail "Widget 扩展缺少 Info.plist"
[ -f "$BUILD_APP/Contents/Info.plist" ] || fail "App 缺少 Info.plist"
[ "$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$BUILD_APP/Contents/Info.plist" 2>/dev/null)" \
  = "$BUNDLE_ID" ] || fail "App bundle identifier 不是 $BUNDLE_ID"
[ "$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$WIDGET_APPEX/Contents/Info.plist" 2>/dev/null)" \
  = "$WIDGET_BUNDLE_ID" ] || fail "Widget bundle identifier 不是 $WIDGET_BUNDLE_ID"
[ "$("$PLIST_BUDDY_BIN" -c 'Print :NSExtension:NSExtensionPointIdentifier' \
  "$WIDGET_APPEX/Contents/Info.plist" 2>/dev/null)" \
  = "com.apple.widgetkit-extension" ] || fail "构建产物不是预期的 WidgetKit 扩展"
ok "构建产物校验通过: $(basename "$WIDGET_APPEX")"

# ── 6. 本机签名 ───────────────────────────────────────────────
# 本流程的产物必须不含 provisioning profile（无 profile 才能在免费 Personal Team
# 上使用 App Group 授权）。构建目录里可能残留其他构建路径留下的 profile，先清掉。
for bundle_path in "$BUILD_APP" "$WIDGET_APPEX"; do
  if [ -e "$bundle_path/Contents/embedded.provisionprofile" ]; then
    rm -f "$bundle_path/Contents/embedded.provisionprofile" \
      || fail "无法移除残留的 embedded.provisionprofile: $bundle_path"
    info "已移除残留的 provisioning profile（$(basename "$bundle_path")）"
  fi
done

# codesign --sign 在这里同时充当身份可用性检查：身份无效会直接失败。
info "签名 Widget 与 App ..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS_WIDGET" "$WIDGET_APPEX" \
  || fail "Widget 签名失败；请确认 SIGN_IDENTITY 指向有效的 Apple Development 身份"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS_APP" "$BUILD_APP" \
  || fail "App 签名失败；请确认 SIGN_IDENTITY 指向有效的 Apple Development 身份"
codesign --verify --deep --strict "$BUILD_APP" \
  || fail "签名校验失败: $BUILD_APP"

assert_entitlements "$WIDGET_APPEX" "Widget 扩展"
assert_entitlements "$BUILD_APP" "App"
# 签名后再次确认 profile 没有回到产物里（例如 codesign 引入了外部 profile）。
for bundle_path in "$BUILD_APP" "$WIDGET_APPEX"; do
  if [ -e "$bundle_path/Contents/embedded.provisionprofile" ]; then
    fail "签名后 $bundle_path 出现 embedded.provisionprofile；本流程的产物必须不含 profile"
  fi
done
ok "签名、entitlements 与无 profile 校验通过"

# ── 7. 安装（带旧版本备份与回滚）──────────────────────────────
info "安装到 $INSTALL_APP ..."

mkdir -p "$(dirname "$INSTALL_APP")"
# 必须在 INSTALL_STARTED=1 / 备份 mktemp 之前加锁：并发运行会互相移动对方的备份，
# 造成下面注释描述的 bundle 套 bundle 交错（见 cleanup 顶部）。加锁失败时
# LOCK_HELD 仍为 0 且 INSTALL_STARTED 仍为 0，cleanup 不删任何东西，直接退出。
#
# 加锁也必须早于下面「退出正在运行的旧实例」：否则被锁挡回去的那一个进程会先把
# 另一个实例刚启动（或用户正在使用）的 App 关掉再失败，把失败变成用户可见的掉线。
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "另一个安装正在进行（锁目录: $LOCK_DIR）。确认没有其他安装进程后，删除该目录再重试。"
fi
LOCK_HELD=1

# 关闭正在运行的旧实例
OLD_PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ]; then
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  fi
  REMAINING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  if [ -n "$REMAINING" ]; then
    printf '%s\n' "$REMAINING" | xargs -r kill -KILL 2>/dev/null || true
    sleep 0.5
  fi
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && fail "无法退出正在运行的 $APP_NAME"
fi

INSTALL_STARTED=1
# INSTALL_PREEXISTING 必须在 mktemp 之前定下来：mktemp 失败时 cleanup 据此判断
# 安装路径上的是旧版本（不能删），还是以前不存在（可以清理残留新产物）。
if [ -e "$INSTALL_APP" ] || [ -L "$INSTALL_APP" ]; then
  INSTALL_PREEXISTING=1
  BACKUP_DIR="$(mktemp -d "$(dirname "$INSTALL_APP")/.${APP_NAME}-backup.XXXXXX")" \
    || fail "无法创建备份目录（$(dirname "$INSTALL_APP") 不可写？）"
fi
if [ -n "$BACKUP_DIR" ]; then
  mv "$INSTALL_APP" "$BACKUP_DIR/$APP_NAME.app" || fail "无法备份现有安装: $INSTALL_APP"
fi

ditto "$BUILD_APP" "$INSTALL_APP" || fail "复制安装失败: $INSTALL_APP"
ok "已安装: $INSTALL_APP"

# ── 8. 启动 ───────────────────────────────────────────────────
# Widget 扩展由系统按需拉起，因此只校验主 App 进程。
info "启动 ..."
open -a "$INSTALL_APP" || fail "open -a 启动失败: $INSTALL_APP"
for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 && break; sleep 0.5; done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "启动后未发现 $APP_NAME 进程"

COMMIT="未在 Git 仓库中"
if COMMIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  [ -n "$COMMIT_SHA" ] && COMMIT="$COMMIT_SHA"
fi
ok "$APP_NAME 运行中"
info "安装路径: $INSTALL_APP"
info "签名身份: $SIGN_IDENTITY"
info "仓库提交: $COMMIT"
info "本产物不含 provisioning profile，仅限本机开发使用，不可分发或公证；标准流程见 script/tb-install.sh"
