#!/bin/bash
# HearMe 构建脚本 —— 只用 Command Line Tools，不需要 Xcode
# 用固定的本地自签证书签名，这样每次重编译后 macOS 的隐私授权不会失效
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HearMe"
BUILD=".build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos14.0"
IDENTITY="HearMe Local Dev"
export TMPDIR="$PWD/$BUILD/tmp"
mkdir -p "$BUILD/tmp" "$BUILD/modcache" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 (SDK: $SDK)"
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -module-cache-path "$BUILD/modcache" \
  -O \
  -parse-as-library \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework Speech -framework ScreenCaptureKit -framework CoreMedia \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 打包"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Icon/AppIcon.icns ]; then
  cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "==> 图标: Icon/AppIcon.icns"
fi

# 优先用稳定身份签名（授权只需给一次）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  SIGN_ARGS=(--sign "$IDENTITY")
  echo "==> 签名: ${IDENTITY} (稳定身份, 权限可复用)"
else
  SIGN_ARGS=(--sign -)
  echo "==> 签名: ad-hoc（注意：每次重编译都需要重新授权）"
fi

codesign --force --deep "${SIGN_ARGS[@]}" \
  --entitlements HearMe.entitlements \
  "$APP" 2>&1 | sed 's/^/    /'

# 注册到 LaunchServices，保证系统设置里显示为同一个 App
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "==> 完成: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" | sed 's/^/    /'
