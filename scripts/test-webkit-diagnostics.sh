#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/ChatGPT Bar.app/Contents/MacOS/ChatGPTBar"
PORT=${CHATGPT_BAR_TEST_PORT:-8765}
STAMP=$(date +%s)
REPORT="${TMPDIR:-/tmp}/chatgpt-bar-diagnostics-$STAMP.json"
SERVER_LOG="${TMPDIR:-/tmp}/chatgpt-bar-diagnostics-server-$STAMP.log"

if [ ! -x "$APP" ]; then
  echo "Missing app bundle; run: sh scripts/build.sh" >&2
  exit 1
fi

python3 -m http.server "$PORT" \
  --bind 127.0.0.1 \
  --directory "$ROOT/tests/fixtures" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 0.5

timeout 30s "$APP" \
  --url "http://127.0.0.1:$PORT/diagnostics.html" \
  --dev-report "$REPORT" \
  --settle 2 \
  --exit-after-report

jq -e '
  .passA.timeToFirstTurnSeconds < 5
  and .passA.page.turns >= 40
  and .passA.page.conversationScroller.scrollHeight > .passA.page.documentScrollHeight
  and .passA.contentStable == true
  and (
    (.passA.jank.supported == true and .passA.jank.frames > 0)
    or (.passA.jank.supported == false and .passA.jank.visibilityState != null)
  )
' "$REPORT" >/dev/null

echo "WebKit diagnostics smoke test passed: $REPORT"

HOME_REPORT="${TMPDIR:-/tmp}/chatgpt-bar-home-diagnostics-$STAMP.json"
timeout 15s "$APP" \
  --url "http://127.0.0.1:$PORT/home.html" \
  --dev-report "$HOME_REPORT" \
  --settle 1 \
  --exit-after-report

jq -e '
  .passA.page.contentState == "home"
  and .passA.timeToFirstTurnSeconds < 3
  and .passA.contentStable == true
' "$HOME_REPORT" >/dev/null

echo "WebKit home diagnostics smoke test passed: $HOME_REPORT"

STREAM_REPORT="${TMPDIR:-/tmp}/chatgpt-bar-stream-diagnostics-$STAMP.json"
timeout 20s "$APP" \
  --url "http://127.0.0.1:$PORT/diagnostics.html?streaming=1" \
  --dev-report "$STREAM_REPORT" \
  --settle 1 \
  --exit-after-report

jq -e '
  .passA.page.turns >= 40
  and .passA.contentStable == true
  and .passA.turnsWhenStable >= .passA.turnsWhenRendered
' "$STREAM_REPORT" >/dev/null

echo "WebKit streaming diagnostics smoke test passed: $STREAM_REPORT"

OPT_REPORT="${TMPDIR:-/tmp}/chatgpt-bar-optimization-diagnostics-$STAMP.json"
timeout 20s "$APP" \
  --url "http://127.0.0.1:$PORT/diagnostics.html" \
  --force-optimization 1 \
  --dev-report "$OPT_REPORT" \
  --settle 1 \
  --exit-after-report

jq -e '
  .passA.page.turnContentVisibility == "auto"
  and .passA.page.turns >= 40
' "$OPT_REPORT" >/dev/null

echo "WebKit optimization diagnostics smoke test passed: $OPT_REPORT"
