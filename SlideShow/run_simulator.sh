#!/bin/bash
# ============================================================
# run_simulator.sh  —  在 Mac 上的 iOS 模拟器里跑起来
#
# 比 AirDrop 到 iPad 快得多，适合改布局时反复看效果。
#
# 前提：已安装模拟器运行时（脚本会检查并给出下载命令）
#
# 用法：bash run_simulator.sh
# ============================================================

set -e

APP_NAME="SlideShow"
BUNDLE_ID="com.yuan.slideshow"
MIN_IOS="14.0"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SRC_DIR/build-sim"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

step() { echo ""; echo -e "${BOLD}${BLUE}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
fail() { echo -e "${RED}  ❌ $1${NC}" >&2; exit 1; }

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  在模拟器里运行 $APP_NAME${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"

# ── 1. 检查模拟器运行时 ───────────────────────────────
step "1/5 检查模拟器运行时"

RUNTIMES=$(xcrun simctl list runtimes 2>/dev/null | grep -c "^iOS" || true)
if [ "$RUNTIMES" -eq 0 ]; then
    fail "没有安装任何 iOS 模拟器运行时

  ${BOLD}先运行这条命令下载（约 7 GB，需要一段时间）：${NC}

      xcodebuild -downloadPlatform iOS

  或者：打开 Xcode → Settings → Components → 下载 iOS 模拟器

  下载完再重新跑本脚本。"
fi

ok "找到 $RUNTIMES 个 iOS 运行时"
xcrun simctl list runtimes 2>/dev/null | grep "^iOS" | sed 's/^/    /'

# ── 2. 编译（模拟器架构）─────────────────────────────
step "2/5 编译 (arm64-simulator, iOS $MIN_IOS)"

SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ok "模拟器 SDK $(xcrun --sdk iphonesimulator --show-sdk-version)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"

xcrun --sdk iphonesimulator swiftc \
    -target "arm64-apple-ios$MIN_IOS-simulator" \
    -sdk "$SIM_SDK" \
    -swift-version 5 \
    -o "$APP_DIR/$APP_NAME" \
    "$SRC_DIR"/*.swift \
    || fail "编译失败"

ok "编译成功"

# ── 3. 组装 bundle ────────────────────────────────────
step "3/5 组装 bundle"

cp "$SRC_DIR/Info.plist" "$APP_DIR/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID"  "$APP_DIR/Info.plist"
plutil -replace CFBundleExecutable -string "$APP_NAME"   "$APP_DIR/Info.plist"
plutil -replace MinimumOSVersion  -string "$MIN_IOS"     "$APP_DIR/Info.plist"
printf 'APPL????' > "$APP_DIR/PkgInfo"

# 图标：复用真机构建用过的生成器
ICON_TOOL="$BUILD_DIR/make_icon"
xcrun --sdk macosx swiftc -O -o "$ICON_TOOL" "$SRC_DIR/tools/make_icon.swift"
for spec in "152:Icon-152" "120:Icon-120" "76:Icon-76"; do
    "$ICON_TOOL" "${spec%%:*}" "$APP_DIR/${spec##*:}.png"
done

# 模拟器不校验签名，ad-hoc 足够
codesign --force --sign - "$APP_DIR" 2>/dev/null

ok "bundle 就绪"

# ── 4. 启动模拟器 ─────────────────────────────────────
step "4/5 启动模拟器"

# 优先挑 iPad（贴近你的目标设备），没有就用第一个可用的
DEVICE_UDID=$(xcrun simctl list devices available 2>/dev/null \
    | grep -i "ipad" | head -1 | grep -oE '[0-9A-F-]{36}')

if [ -z "$DEVICE_UDID" ]; then
    DEVICE_UDID=$(xcrun simctl list devices available 2>/dev/null \
        | grep -oE '[0-9A-F-]{36}' | head -1)
fi

if [ -z "$DEVICE_UDID" ]; then
    warn "没有可用设备，创建一个 iPad 模拟器"
    RUNTIME=$(xcrun simctl list runtimes 2>/dev/null \
        | grep "^iOS" | head -1 | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+')
    DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"

    DEVICE_UDID=$(xcrun simctl create "SlideShow iPad" "$DEVICE_TYPE" "$RUNTIME" 2>/dev/null) \
        || fail "创建模拟器失败。手动在 Xcode → Window → Devices and Simulators 里建一个。"
    ok "已创建: $DEVICE_UDID"
fi

DEVICE_NAME=$(xcrun simctl list devices | grep "$DEVICE_UDID" | sed 's/ *(.*//' | xargs)
ok "使用设备: $DEVICE_NAME"

xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
open -a Simulator

# 等设备真正启动完成
echo -n "  等待设备启动"
for i in $(seq 1 60); do
    if xcrun simctl bootstatus "$DEVICE_UDID" -b >/dev/null 2>&1; then break; fi
    echo -n "."
    sleep 1
done
echo ""
ok "设备已就绪"

# ── 5. 安装并运行 ─────────────────────────────────────
step "5/5 安装并运行"

xcrun simctl uninstall "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_UDID" "$APP_DIR" || fail "安装失败"
ok "已安装"

xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID" || fail "启动失败"

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  🎉 已在模拟器中运行${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo "  模拟器自带几张示例照片，相册权限弹窗同意后就能看到效果。"
echo ""
echo "  改了代码后重新跑：bash run_simulator.sh"
echo ""
echo "  常用命令："
echo "    看日志:   xcrun simctl spawn $DEVICE_UDID log stream --predicate 'process == \"$APP_NAME\"'"
echo "    卸载:     xcrun simctl uninstall $DEVICE_UDID $BUNDLE_ID"
echo "    关闭全部: xcrun simctl shutdown all"
echo ""
