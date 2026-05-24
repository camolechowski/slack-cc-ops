#!/usr/bin/env bash
# Restart the container without rebuilding. Use for quick iteration on the
# system prompt or settings — anything that doesn't need a fresh image.
#
# NOTE: docker compose restart does NOT reload .env. If you've changed env
# vars, use redeploy.sh (which does --force-recreate) instead.

set -euo pipefail

PROJECT_DIR="${SLACK_CC_OPS_DIR:-$HOME/dvl/win-ops}"
cd "$PROJECT_DIR"

log() { echo "[restart] $*"; }

log "docker compose restart slack-cc-ops"
docker compose restart slack-cc-ops 2>&1 | tail -3

sleep 12

log "dismissing dev-channel warning prompt"
docker exec slack-cc-ops tmux send-keys -t slackcc Enter 2>/dev/null || true
sleep 8

log "waiting for Bolt 'connected as ...'"
for i in {1..20}; do
  if docker exec slack-cc-ops grep -q "slack channel: connected as" /state/inbox/server.err 2>/dev/null; then
    log "  ✓ $(docker exec slack-cc-ops tail -1 /state/inbox/server.err)"
    break
  fi
  sleep 1
done

log "done."
