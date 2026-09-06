#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

swift build
swift run SelfTest
sh scripts/build.sh
sh scripts/test-webkit-diagnostics.sh

if [ -n "${PLAYWRIGHT_PACKAGE:-}" ]; then
  node scripts/test-browser-bridge.mjs
elif [ -d "/Users/youbin/node_modules/playwright" ]; then
  node scripts/test-browser-bridge.mjs
else
  echo "Browser bridge fixture test skipped: Playwright is not installed."
fi
