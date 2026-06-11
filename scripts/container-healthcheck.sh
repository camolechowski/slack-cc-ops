#!/usr/bin/env bash
# In-container capability healthcheck for slack-cc-ops.
# This is stricter than a plain process check: it proves the bot can still act
# like an operator after restarts, long idle periods, and host drift.

set -euo pipefail

fail() {
  echo "[container-healthcheck] $*" >&2
  exit 1
}

pgrep -f "^claude " >/dev/null 2>&1 || fail "claude REPL process is not running"
pgrep -f "bun.*server.ts" >/dev/null 2>&1 || fail "channel MCP server is not running"

# /win is a mounted worktree. If git metadata mounts drift, this breaks one of
# the bot's most important operator questions: "what is on origin/main?"
git -C /win rev-parse --verify --quiet origin/main^{commit} >/dev/null \
  || fail "/win cannot resolve origin/main"

# The bot needs sibling-container visibility for real incident response.
docker ps >/dev/null 2>&1 || fail "docker ps failed"

WHOAMI_OUTPUT="$(win whoami 2>/dev/null || true)"
printf '%s' "$WHOAMI_OUTPUT" | grep -Eq '"authState"[[:space:]]*:[[:space:]]*"oauth-active"' \
  || fail "win whoami is not oauth-active"

# A rate-limit wedge (Claude alive but stuck on the session-limit modal) leaves
# every process running, so the checks above all pass. The liveness loop drops
# this marker when it sees the wedge; treat its presence as unhealthy so compose
# recycles the container.
[ -f /state/inbox/WEDGED ] && fail "WEDGED marker present — Claude session-limit wedge detected"

# Slack liveness. The old check grepped server.err for "connected as", which
# stays true forever once printed — it passed even after a multi-day Bolt
# disconnect. Instead, prove the channel server that is *currently running* also
# *currently holds* the plugin lock: server.ts writes the lock with its own PID
# at startup and releases it on shutdown, so a live lock-owner means a live,
# connected Bolt process. This cannot pass while the server is dead.
LOCK="${SLACK_STATE_DIR:-/state/channels/slack}/plugin.lock"
[ -f "$LOCK" ] || fail "channel plugin.lock missing — Bolt server not holding the lock"
LOCK_PID="$(cat "$LOCK" 2>/dev/null || true)"
case "$LOCK_PID" in
  ''|*[!0-9]*) fail "channel plugin.lock has no valid PID ('$LOCK_PID')" ;;
esac
kill -0 "$LOCK_PID" 2>/dev/null || fail "channel plugin.lock PID $LOCK_PID is not a live process"
