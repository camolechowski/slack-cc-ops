#!/usr/bin/env bash
# Tail both server.err (clean Bolt + channel-server logs) and claude.log (the
# tmux pane mirror — full of ANSI escape codes). Strips ANSI on the way through
# and filters for the things worth seeing during normal operation.
#
# Pass --raw as the first arg to see everything without filtering.

set -euo pipefail

PROJECT_DIR="${SLACK_CC_OPS_DIR:-$HOME/dvl/win-ops}"

RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
fi

log() { echo "[logs] $*" >&2; }

if [ "$RAW" = "1" ]; then
  log "raw mode — all output, no filter"
  docker exec slack-cc-ops sh -c 'tail -F /state/inbox/server.err /state/inbox/claude.log 2>/dev/null'
  exit 0
fi

log "filtered mode — channel events, command runs, errors. Pass --raw for everything."

docker exec slack-cc-ops sh -c '(tail -F /state/inbox/server.err 2>/dev/null & tail -F /state/inbox/claude.log 2>/dev/null) | sed -uE "s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g"' \
  | grep -E --line-buffered -i 'slack channel:|app_mention|<channel|channel source|Bash\(|/win |gear|deny|notifications/claude|win dev|win deploy|win run|win jobs|message_id|chat_id|error|fail|connected|warn|new assistant'
