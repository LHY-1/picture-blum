#!/bin/bash
# ============================================================
# publish.sh  —  构建 + 发布到 GitHub Releases（一条命令）
#
# 用法：bash publish.sh [owner/repo]
#       默认发布到 LHY-1/picture-blum
#
# 做的事：
#   1. 跑 build_ipa.sh（自动升 build number）
#   2. 算 sha256，生成 manifest.json
#   3. gh release create：SlideShow.ipa + manifest.json 一起挂上
#
# 设备端以后自动更新（1.9）只需要认两个固定地址：
#   https://github.com/<owner>/<repo>/releases/latest/download/SlideShow.ipa
#   https://github.com/<owner>/<repo>/releases/latest/download/manifest.json
#   （latest 指针由 GitHub 维护，发布完自动指向最新 Release）
#
# 前置：brew install gh && gh auth login
# ============================================================

set -e

REMOTE_REPO="${1:-LHY-1/picture-blum}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC_DIR"

echo "▶ 构建 + 发布 → $REMOTE_REPO"
bash build_ipa.sh

VERSION=$(grep '^VERSION=' build_ipa.sh | cut -d'"' -f2)
BUILD_NO=$(cat build_number.txt)
SHA256=$(shasum -a 256 build/SlideShow.ipa | cut -d' ' -f1)
TAG="v${VERSION}-b${BUILD_NO}"

command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && {
    # 有 gh token 就正常走 gh
    # manifest.json：设备端轮询它判断有没有新版
    cat > build/manifest.json <<EOF
{
  "version": "$VERSION",
  "build": $BUILD_NO,
  "sha256": "$SHA256",
  "url": "https://github.com/${REMOTE_REPO}/releases/latest/download/SlideShow.ipa",
  "min_ios": "14.0"
}
EOF

    echo "▶ 创建 Release $TAG"
    gh release create "$TAG" \
    build/SlideShow.ipa \
    build/manifest.json \
    --title "相框 v$VERSION (build $BUILD_NO)" \
    --notes "自动生成。校验：shasum -a 256 应为 $SHA256"
    echo ""
    echo "✅ 发布完成：https://github.com/${REMOTE_REPO}/releases/${TAG}"
    exit 0
}

# ── 无 gh 认证：git tag + 手动 release（SSH 密钥推 tag 到远端）──
# 设备端 manifest 地址不变，只是 Release 页面要手动建一次（或配 GitHub Actions 自动建）
echo "▶ 没有 gh 认证，走 git tag + 手动 release"
GIT_REPO="git@github.com-LHY-1:${REMOTE_REPO}.git"
cd "$SRC_DIR"

# 打包 zip（含 ipa + manifest）
zip -j build/SlideShow.zip build/SlideShow.ipa
cat > build/manifest.json <<EOF
{
  "version": "$VERSION",
  "build": $BUILD_NO,
  "sha256": "$SHA256",
  "url": "https://github.com/${REMOTE_REPO}/releases/latest/download/SlideShow.zip",
  "min_ios": "14.0"
}
EOF

# 提交构建产物到独立 build 分支（不污染 main）
git add build/SlideShow.ipa build/SlideShow.zip build/manifest.json build/build_number.txt 2>/dev/null || true
TAG="v${VERSION}-b${BUILD_NO}"
git tag -f "$TAG"

# 推 tag 到远端（SSH）
git push -f origin "$TAG" 2>&1
echo ""
echo "✅ Tag $TAG 已推送到远端（SSH）"
echo "   还需要手动在 GitHub 建 Release 挂上 build/SlideShow.zip + manifest.json："
echo "   https://github.com/${REMOTE_REPO}/releases/new?tag=$TAG"
echo "   或者配 GitHub Actions（repo 里加 .github/workflows/publish.yml）自动建 Release"
    build/SlideShow.ipa \
    build/manifest.json \
    --title "相框 v$VERSION (build $BUILD_NO)" \
    --notes "自动生成。校验：shasum -a 256 应为 $SHA256"

echo ""
echo "✅ 发布完成：https://github.com/${REMOTE_REPO}/releases/${TAG}"
echo "   设备端固定下载地址：https://github.com/${REMOTE_REPO}/releases/latest/download/SlideShow.ipa"
