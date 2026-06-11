#!/usr/bin/env bash
# SessionStart hook.
#
# Writes /state/sessions/${PPID}.json so the channel server (server.ts) can
# correlate a Claude conversation back to the Slack thread that started it —
# the lookup that thread persistence depends on. Documented in CLAUDE.md
# ("lifted from odfalik's plugin"); this is the minimal implementation of that
# contract.
#
# The SessionStart payload carries session_id and source on stdin; we record
# both alongside the parent pid and a UTC timestamp. The hook must never block
# session start, so every failure path is swallowed and it exits 0.
set -u

SESSIONS_DIR=/state/sessions
mkdir -p "$SESSIONS_DIR" 2>/dev/null || exit 0

input="$(cat)"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$SESSIONS_DIR/${PPID}.json"

write_json() {
  printf '%s\n' "$1" >"$out" 2>/dev/null || true
  exit 0
}

if command -v python3 >/dev/null 2>&1; then
  json="$(PPID_VAL="$PPID" STARTED="$started" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(json.dumps({
    "pid": int(os.environ["PPID_VAL"]),
    "started": os.environ["STARTED"],
    "session_id": d.get("session_id", ""),
    "source": d.get("source", ""),
}))
' <<<"$input" 2>/dev/null)"
  [[ -n "$json" ]] && write_json "$json"
fi

write_json "{\"pid\": ${PPID}, \"started\": \"${started}\"}"
