#!/bin/bash
# 构建「合盖不休眠」菜单栏应用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="合盖不休眠"
APP="$ROOT/$APP_NAME.app"
BIN="$APP/Contents/MacOS/LidAwake"

echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译（Swift, arm64, macOS 13+）"
mkdir -p "$ROOT/.build/ModuleCache"
CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache" \
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$ROOT/.build/ModuleCache" \
  -framework Cocoa \
  "$ROOT"/Sources/*.swift \
  -o "$BIN"

chmod +x "$BIN"

echo "==> 组装 App Bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    （没有图标，跳过）"
fi

echo "==> ad-hoc 签名"
if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
  echo "    已签名"
else
  echo "    签名失败，但不影响本机运行"
fi

echo
echo "==> 完成：$APP"
echo "    双击打开，或执行：open \"$APP\""
