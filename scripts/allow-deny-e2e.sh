#!/bin/bash
# End-to-end Allow/Deny against the real Claude Code: a debug AgentScope (isolated home, Allow/Deny on)
# holds Claude's PermissionRequest hook; this script answers it the way a click would. Costs two short
# headless `claude -p` runs on haiku.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build >/dev/null
BIN="$(swift build --show-bin-path)"
export AGENTSCOPE_HOME="$(mktemp -d /tmp/as-ad.XXXXXX)"
WORK="$(mktemp -d /tmp/as-ad-work.XXXXXX)"
APP_PID=""
cleanup() { [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true; rm -rf "$AGENTSCOPE_HOME" "$WORK"; }
trap cleanup EXIT

AGENTSCOPE_DEBUG_ALLOW_DENY=1 "$BIN/AgentScopeApp" &
APP_PID=$!
for _ in $(seq 50); do [[ -S "$AGENTSCOPE_HOME/agentscope.sock" ]] && break; sleep 0.1; done

cat > "$WORK/settings.json" <<JSON
{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","timeout":120,
 "command":"AGENTSCOPE_HOME=$AGENTSCOPE_HOME $BIN/agentscope hook --agent claude --event PermissionRequest --decide"}]}]}}
JSON

answer() { # waits for a held request, then answers it
  for _ in $(seq 120); do
    out=$(python3 - "$AGENTSCOPE_HOME/agentscope.sock" "$1" <<'PY'
import socket, sys, json
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"type": "debug-decide", "allow": sys.argv[2] == "allow"}) + "\n").encode())
s.shutdown(socket.SHUT_WR); print(s.recv(100).decode().strip())
PY
)
    [[ "$out" == "decided 1" ]] && return 0
    sleep 0.5
  done
  return 1
}

for mode in allow deny; do
  mkdir -p "$WORK/$mode" && echo hi > "$WORK/$mode/notes.txt"
  answer "$mode" &
  ANSWER=$!
  (cd "$WORK/$mode" && echo "Run exactly this bash command once: rm notes.txt   Then reply with one word." \
    | claude -p --model haiku --setting-sources project --settings "$WORK/settings.json" >/dev/null 2>&1)
  wait "$ANSWER" || { echo "FAIL: no held request for $mode"; exit 1; }
  if [[ "$mode" == allow ]]; then
    [[ ! -e "$WORK/allow/notes.txt" ]] || { echo "FAIL: allow did not run the command"; exit 1; }
  else
    [[ -e "$WORK/deny/notes.txt" ]] || { echo "FAIL: deny did not block the command"; exit 1; }
  fi
  echo "ok: $mode"
done
echo PASS
