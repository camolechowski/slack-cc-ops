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

# If Bolt never connected, the bot may look alive but be unable to receive Slack.
tail -80 /state/inbox/server.err 2>/dev/null | grep -q "slack channel: connected as" \
  || fail "no successful Slack channel connection found in server.err"
