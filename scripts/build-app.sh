#!/bin/bash
# 构建 voicetype.app（非沙盒、自签名证书签名）。
#
#   ./scripts/build-app.sh            # release 构建
#   CONFIG=debug ./scripts/build-app.sh
#
# 说明：默认使用自签名证书身份「Voicetype Dev」签名，其 designated requirement
# 基于证书而非 cdhash，重建后不会丢失「辅助功能 / 输入监控 / 麦克风」授权。
# 若该身份不存在，会回退 ad-hoc 签名（此时每次重建都需重新授权），
# 可先运行 ./scripts/create-signing-cert.sh 创建身份。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="voicetype"
BUNDLE="$ROOT/dist/Voicetype.app"

cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "==> 组装 $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# VERSION 只覆盖「打出来的这个 bundle」，不动源码里的 Info.plist，
# 这样 VERSION=0.2.1 ./scripts/package-release.sh 打出的包版本号是真的 0.2.1。
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist"
fi
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"

# transcribe.cpp 的原生库是动态框架：必须嵌入 .app 并单独签名，
# 同时给可执行文件补一条 @executable_path/../Frameworks 的 rpath。
FRAMEWORK_SRC="$ROOT/Vendor/transcribe-cpp/build-apple/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework"
echo "==> 嵌入 CTranscribe.framework"
if [ -d "$FRAMEWORK_SRC" ]; then
  mkdir -p "$BUNDLE/Contents/Frameworks"
  cp -R "$FRAMEWORK_SRC" "$BUNDLE/Contents/Frameworks/"
  if ! otool -l "$BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$APP_NAME"
  fi
else
  echo "错误：找不到 $FRAMEWORK_SRC"
  echo "      先按 Vendor/transcribe-cpp/VENDOR.md 生成 xcframework。"
  exit 1
fi

echo "==> 签名"
SIGN_IDENTITY="${SIGN_IDENTITY:-Voicetype Dev}"
CODESIGN_ARGS=(--force --timestamp=none)
if security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
  CODESIGN_ARGS+=(--sign "${SIGN_IDENTITY}")
else
  echo "警告：未找到签名身份「${SIGN_IDENTITY}」，回退 ad-hoc。"
  echo "      重建后将需要重新授权，可运行 ./scripts/create-signing-cert.sh 创建稳定身份。"
  CODESIGN_ARGS+=(--sign -)
fi
# 先签内嵌框架，再签整个 app（顺序不能反）。
codesign "${CODESIGN_ARGS[@]}" "$BUNDLE/Contents/Frameworks/CTranscribe.framework"
codesign "${CODESIGN_ARGS[@]}" "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/    /'

cat <<'TXT'

构建完成：dist/Voicetype.app
启动：
  open dist/Voicetype.app
首次启动后请在「系统设置 → 隐私与安全性」中授权：
  1. 麦克风       （自动弹出申请）
  2. 输入监控     （监听右 Option 需要，缺失则热键失效）
  3. 辅助功能     （把文字注入到光标处需要，缺失则退化为「复制到剪贴板」）
授权后重启本应用。菜单栏会出现麦克风图标，按住右 Option 说话、松开即转写。
默认会再用本机 Ollama 的 Qwen3.5 9B 把口头禅和改口整理掉。菜单里可以改成「插入原文」或「总结成要点」。
TXT
