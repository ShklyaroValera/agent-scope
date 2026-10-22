#!/bin/bash
# End-to-end: recorded fixtures → `agentscope hook` → (spool | socket) → app → `agentscope status`.
# Runs against an isolated AGENTSCOPE_HOME; briefly shows a second AgentScope icon in the menu bar.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null
BIN="$(swift build --show-bin-path)"
FIXTURES=Tests/Fixtures/claude/2.1.283
export AGENTSCOPE_HOME="$(mktemp -d /tmp/as-int.XXXXXX)"
APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  rm -rf "$AGENTSCOPE_HOME"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

send() {
  local file=$1 event
  event=$(basename "$file" .json | cut -d- -f2)
  local start end output status
  start=$(now_ms)
  set +e
  output=$("$BIN/agentscope" hook --agent claude --event "$event" < "$file")
  status=$?
  set -e
  end=$(now_ms)
  [[ $status -eq 0 ]] || fail "hook exited $status for $file"
  [[ -z "$output" ]] || fail "hook printed output for $file"
  (( end - start < 100 )) || echo "warn: hook took $((end - start)) ms for $file (cold start?)" >&2
}

# 1. App not running: events go to the spool.
for file in "$FIXTURES"/0[1-5]-*.json; do send "$file"; done
lines=$(wc -l < "$AGENTSCOPE_HOME/spool.ndjson" | tr -d ' ')
[[ "$lines" == 5 ]] || fail "expected 5 spooled lines, got $lines"
"$BIN/agentscope" status >/dev/null 2>&1 && fail "status should fail while the app is down"

# 2. Start the app: it replays the spool and listens.
"$BIN/AgentScopeApp" &
APP_PID=$!
for _ in $(seq 50); do [[ -S "$AGENTSCOPE_HOME/agentscope.sock" ]] && break; sleep 0.1; done
[[ -S "$AGENTSCOPE_HOME/agentscope.sock" ]] || fail "app did not open its socket"
[[ ! -e "$AGENTSCOPE_HOME/spool.ndjson" ]] || fail "spool was not drained"

# 3. Live events up to the permission request.
for file in "$FIXTURES"/0[6-9]-*.json "$FIXTURES"/1[0-5]-*.json; do send "$file"; done
sleep 0.3
"$BIN/agentscope" status --json > "$AGENTSCOPE_HOME/status.json"
python3 - "$AGENTSCOPE_HOME/status.json" <<'EOF'
import json, sys
status = json.load(open(sys.argv[1]))
sessions = status["sessions"]
assert len(sessions) == 1, sessions
session = sessions[0]
assert session["status"] == "needsYou", session
assert session["project"] == "demo", session
assert session["activity"] == "Waiting for permission", session
assert [p["summary"] for p in status["pending"]] == ["Bash rm notes.txt"], status["pending"]
assert status["today"]["toolCalls"] == 6, status["today"]
EOF

# 4. The rest of the session.
for file in "$FIXTURES"/1[6-9]-*.json "$FIXTURES"/2*.json; do send "$file"; done
sleep 0.3
"$BIN/agentscope" status --json | python3 -c '
import json, sys
status = json.load(sys.stdin)
session = status["sessions"][0]
assert session["status"] == "idle", session
assert session["activity"] == "Session ended", session
assert status["pending"] == [], status
assert status["today"]["toolCalls"] == 7, status["today"]
'
"$BIN/agentscope" status
echo "PASS"
