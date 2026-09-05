#!/bin/sh
# Builds dist/ChatGPT Bar.app from the SwiftPM executable target.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/ChatGPT Bar.app"

cd "$ROOT"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ChatGPTBar" "$APP/Contents/MacOS/ChatGPTBar"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. `--deep` is deprecated and unnecessary for a single binary.
codesign --force --sign - "$APP"

# Make the Services entry visible without a logout.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

echo "built: $APP"
