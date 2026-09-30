#!/bin/bash
# ============================================================
# build_ipa.sh  —  编译并打包成 TrollStore 可安装的 IPA
#
# 完全绕过 Xcode GUI 和 Apple ID：
#   编译 → 组装 .app → ad-hoc 签名 → 打包 IPA
#
# TrollStore 安装时会用它自己的签名重新签，所以不需要苹果证书。
#
# 用法：bash build_ipa.sh
# 产物：build/SlideShow.ipa
# ============================================================

set -e

# ── 配置 ──────────────────────────────────────────────
APP_NAME="SlideShow"
BUNDLE_ID="com.yuan.slideshow"
DISPLAY_NAME="相框"
MIN_IOS="14.0"                  # 改这里也要改 Info.plist 的 MinimumOSVersion
VERSION="1.9"                   # 语义版本：只有加了真功能才改

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SRC_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# build number 每次构建自动 +1，不用手写。
# VERSION 不变、BUILD_NUMBER 变 → iPad 上就能分清装的是哪个构建。
BUILD_NUMBER_FILE="$SRC_DIR/build_number.txt"
if [ -f "$BUILD_NUMBER_FILE" ]; then
    BUILD_NUMBER=$(( $(cat "$BUILD_NUMBER_FILE") + 1 ))
else
    BUILD_NUMBER=1
fi
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

# ── 颜色输出 ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

step()  { echo ""; echo -e "${BOLD}${BLUE}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
fail()  { echo -e "${RED}  ❌ $1${NC}" >&2; exit 1; }

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  构建 $DISPLAY_NAME ($APP_NAME)  v$VERSION · build $BUILD_NUMBER${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"

# ── 1. 检查环境 ───────────────────────────────────────
step "1/7 检查环境"

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) \
    || fail "找不到 iOS SDK。请确认 Xcode 已安装并运行过：sudo xcodebuild -runFirstLaunch"

SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)
ok "iOS SDK $SDK_VERSION"
ok "SDK 路径 $SDK_PATH"

command -v codesign >/dev/null || fail "找不到 codesign"
command -v zip >/dev/null || fail "找不到 zip"

# ── 2. 清理 ───────────────────────────────────────────
step "2/7 清理旧的构建产物"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"
ok "已清理 $BUILD_DIR"

# ── 3. 编译 ───────────────────────────────────────────
step "3/7 编译 Swift 源码 (arm64, iOS $MIN_IOS)"

SWIFT_FILES=("$SRC_DIR"/*.swift)
ok "源文件 ${#SWIFT_FILES[@]} 个"

xcrun --sdk iphoneos swiftc \
    -target "arm64-apple-ios$MIN_IOS" \
    -sdk "$SDK_PATH" \
    -swift-version 5 \
    -O \
    -o "$APP_DIR/$APP_NAME" \
    "${SWIFT_FILES[@]}" \
    || fail "编译失败"

ok "编译成功"

# 验证二进制里记录的部署目标
MINOS=$(vtool -show-build "$APP_DIR/$APP_NAME" 2>/dev/null | awk '/minos/{print $2}')
[ "$MINOS" = "$MIN_IOS" ] && ok "二进制 minos = $MINOS" \
    || warn "二进制 minos = $MINOS（预期 $MIN_IOS）"

# ── 3.5 并发符号检查 ──────────────────────────────────
step "3.5/7 检查有没有误用 iOS 15+ 的并发符号"

# View.body 是 @MainActor 的。在 body（或它调用的计算属性）里写
# Binding(get:set:) 这种「把 @MainActor 闭包传给 nonisolated 参数」的
# 代码，编译器会插一层 actor 跳转 thunk，它引用
#     _$sScM6sharedScMvgZ   Swift.MainActor.shared
#     _$sScMMa              type metadata accessor for Swift.MainActor
# 这俩是 iOS 15 才有的。按 iOS 14 编译时它们是弱引用，iOS 14 的 dyld
# 解析成 NULL，代码走到桩里的 `br x16`（x16 = 0）就跳到地址 0：
#     EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0
# 这就是「一点上传服务就闪退」的根因，详见 ServerSheet.swift 文件头。
#
# 这里直接扫二进制：只要还有代码 bl 到 MainActor.shared 的桩，就说明
# 又踩了这条线，构建直接失败。
MA_SHARED_STUB=$(otool -Iv "$APP_DIR/$APP_NAME" 2>/dev/null \
    | grep -F '_$sScM6sharedScMvgZ' | head -1 | awk '{print $1}' \
    | sed 's/^0x0*//')

if [ -n "$MA_SHARED_STUB" ]; then
    DISASM="$BUILD_DIR/disasm.txt"
    objdump --disassemble "$APP_DIR/$APP_NAME" > "$DISASM" 2>/dev/null || true
    HITS=$(grep -E "bl[[:space:]]+0x${MA_SHARED_STUB}([[:space:]]|$)" "$DISASM" || true)
    if [ -n "$HITS" ]; then
        echo "$HITS" | sed 's/^/    /'
        rm -f "$DISASM"
        fail "二进制调用了 Swift.MainActor.shared（iOS 15+）—— iOS 14 上会跳地址 0 崩溃"
    fi
    rm -f "$DISASM"
fi
ok "没有引用 iOS 15+ 的并发符号"

# ── 4. 生成图标 ───────────────────────────────────────
step "4/7 生成 App 图标"

ICON_TOOL="$BUILD_DIR/make_icon"
xcrun --sdk macosx swiftc -O \
    -o "$ICON_TOOL" \
    "$SRC_DIR/tools/make_icon.swift" \
    || fail "图标生成器编译失败"

# iPad Air 2 需要 76pt@2x = 152px
for spec in "152:Icon-152" "120:Icon-120" "76:Icon-76" "180:Icon-180" "167:Icon-167"; do
    px="${spec%%:*}"
    name="${spec##*:}"
    "$ICON_TOOL" "$px" "$APP_DIR/$name.png" || fail "生成 $name.png 失败"
done
ok "已生成 5 个尺寸的图标"

# ── 5. 组装 bundle ────────────────────────────────────
step "5/7 组装 .app bundle"

# Info.plist：以 Info.plist 为模板，用 plutil 覆盖可变字段
cp "$SRC_DIR/Info.plist" "$APP_DIR/Info.plist"
plutil -replace CFBundleIdentifier          -string "$BUNDLE_ID"    "$APP_DIR/Info.plist"
plutil -replace CFBundleDisplayName         -string "$DISPLAY_NAME" "$APP_DIR/Info.plist"
plutil -replace CFBundleName                -string "$APP_NAME"     "$APP_DIR/Info.plist"
plutil -replace CFBundleExecutable          -string "$APP_NAME"     "$APP_DIR/Info.plist"
plutil -replace CFBundleShortVersionString  -string "$VERSION"      "$APP_DIR/Info.plist"
plutil -replace CFBundleVersion             -string "$BUILD_NUMBER" "$APP_DIR/Info.plist"
plutil -replace MinimumOSVersion            -string "$MIN_IOS"      "$APP_DIR/Info.plist"
plutil -replace DTPlatformVersion           -string "$SDK_VERSION"  "$APP_DIR/Info.plist"
plutil -replace DTSDKName                   -string "iphoneos$SDK_VERSION" "$APP_DIR/Info.plist"

# PkgInfo：老式但无害，某些工具会检查
printf 'APPL????' > "$APP_DIR/PkgInfo"

plutil -lint "$APP_DIR/Info.plist" >/dev/null || fail "Info.plist 格式错误"
ok "Info.plist 校验通过"

# 确认关键键都在
for key in CFBundleExecutable CFBundleIdentifier MinimumOSVersion \
           UIDeviceFamily NSPhotoLibraryUsageDescription \
           NSPhotoLibraryAddUsageDescription \
           NSLocalNetworkUsageDescription; do
    plutil -extract "$key" raw "$APP_DIR/Info.plist" >/dev/null 2>&1 \
        || fail "Info.plist 缺少关键键: $key"
done
ok "关键键齐全（含相册 + 局域网权限描述）"

# ── 6. 签名 ───────────────────────────────────────────
step "6/7 ad-hoc 签名"

codesign --force --sign - \
    --entitlements "$SRC_DIR/$APP_NAME.entitlements" \
    --timestamp=none \
    "$APP_DIR" 2>&1 | sed 's/^/  /'

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/  /' || warn "签名校验有警告"
ok "已签名（ad-hoc，TrollStore 安装时会重新签）"

# ── 7. 打包 IPA ───────────────────────────────────────
step "7/7 打包 IPA"

IPA_DIR="$BUILD_DIR/ipa"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_DIR" "$IPA_DIR/Payload/"

IPA_PATH="$BUILD_DIR/$APP_NAME.ipa"
rm -f "$IPA_PATH"
(cd "$IPA_DIR" && zip -qry "$IPA_PATH" Payload)

IPA_SIZE=$(du -h "$IPA_PATH" | cut -f1)
ok "已生成 $IPA_PATH ($IPA_SIZE)"

# ── 完成 ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  🎉 构建完成${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo -e "  版本: ${BOLD}v$VERSION (build $BUILD_NUMBER)${NC}"
echo -e "  IPA:  ${BOLD}$IPA_PATH${NC}"
echo ""
echo -e "  ${BOLD}安装到 iPad：${NC}"
echo "    1. AirDrop 把 SlideShow.ipa 传到 iPad"
echo "       （或存到网盘 / 用数据线拷）"
echo "    2. 在 iPad 上点开这个文件 → 用 TrollStore 打开"
echo "    3. TrollStore 里点 Install"
echo ""
echo -e "  ${BOLD}调试信息：${NC}"
echo "    查看 bundle 内容: open \"$APP_DIR\""
echo "    查看部署目标:     vtool -show-build \"$APP_DIR/$APP_NAME\""
echo ""
