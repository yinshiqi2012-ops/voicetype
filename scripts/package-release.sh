#!/bin/bash
# 打一个可分发的 macOS 发布包（zip）。
#
#   ./scripts/package-release.sh          # 用 Info.plist 里的版本号
#   VERSION=0.1.0 ./scripts/package-release.sh
#
# 产物：dist/voicetype-<version>-macos.zip
#
# 说明：本应用使用自签名证书，**没有经过 Apple 公证**。用户首次打开会被
# Gatekeeper 拦截，需右键 → 打开，或执行 README 里写的那条 xattr 命令。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Voicetype.app"

cd "$ROOT"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)}"
OUT="$ROOT/dist/voicetype-$VERSION-macos.zip"

echo "==> 构建 app"
./scripts/build-app.sh > /dev/null

echo "==> 打包 $OUT"
rm -f "$OUT"
# 用 ditto 保留符号链接、资源分叉与可执行权限（zip 直接压会丢这些）。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"

echo
echo "==> 完成"
ls -lh "$OUT" | awk '{print "   ", $9, $5}'
shasum -a 256 "$OUT" | awk '{print "    sha256:", $1}'
cat <<'TXT'

用户首次打开前需要去掉隔离属性（自签名应用没有公证）：
    xattr -dr com.apple.quarantine /Applications/Voicetype.app

或者：在 Finder 里右键 App → 打开 → 仍要打开。
TXT
