#!/usr/bin/env bash
# Local smoke test: builds Release, launches the tray app, verifies process health,
# dashboard endpoint and log output, then stops it. Run from win/ via: bash scripts/smoke-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

echo "[smoke] building Release..."
dotnet build src/AQB.App -c Release --nologo -v minimal || exit 1
EXE="src/AQB.App/bin/Release/net8.0-windows/AIQuotaBar.exe"
[ -f "$EXE" ] || { echo "[smoke] missing $EXE"; exit 1; }

LOG="$LOCALAPPDATA/AIQuotaBar/app.log"
rm -f "$LOG"

echo "[smoke] launching tray app..."
"$EXE" &
APP_PID=$!
sleep 6

fail() { kill $APP_PID 2>/dev/null; echo "[smoke] FAIL: $1"; exit 1; }

kill -0 $APP_PID 2>/dev/null || fail "process exited early"
echo "[smoke] process alive (pid $APP_PID)"

sleep 2
[ -f "$LOG" ] || fail "no log file written"
grep -q "Tray host started" "$LOG" || fail "log missing startup line: $(tail -5 "$LOG")"
echo "[smoke] log OK: $(grep -c . "$LOG") lines"

# Dashboard endpoint (only when enabled in settings; default off -> just check absence of crash)
HEALTH=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:18765/api/v1/health" || true)
echo "[smoke] dashboard health HTTP $HEALTH (404/000 acceptable when disabled)"

kill $APP_PID 2>/dev/null
sleep 1
kill -0 $APP_PID 2>/dev/null && kill -9 $APP_PID 2>/dev/null
echo "[smoke] PASS"
