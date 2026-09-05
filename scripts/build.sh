#!/bin/sh
# Builds dist/ChatGPT Bar.app from the SwiftPM executable target.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")}"
BUILD_VERSION="${BUILD_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Support/Info.plist")}"
APP="$ROOT/dist/ChatGPT Bar.app"

cd "$ROOT"

ARCH_FLAGS=""
for arch in ${ARCHS:-}; do
  ARCH_FLAGS="$ARCH_FLAGS --arch $arch"
done

swift build -c "$CONFIG" $ARCH_FLAGS
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path $ARCH_FLAGS)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ChatGPTBar" "$APP/Contents/MacOS/ChatGPTBar"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"

# Ad-hoc signature. `--deep` is deprecated and unnecessary for a single binary.
codesign --force --sign - "$APP"

# Make the Services entry visible without a logout.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "built: $APP"
