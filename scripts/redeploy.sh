#!/usr/bin/env bash
# Pull latest from master, rebuild image, force-recreate the container, dismiss
# the dev-channel warning prompt, and wait for Bolt to reconnect.
#
# Run from inside ~/dvl/win-ops/ on the mini, OR from any directory passed via
# SLOPS_DIR (or the legacy SLACK_CC_OPS_DIR fallback). From Cam's laptop:
#   ssh superpea@mac-mini 'bash ~/dvl/win-ops/scripts/redeploy.sh'

set -euo pipefail
export PATH="$HOME/.bun/bin:$PATH"

PROJECT_DIR="${SLOPS_DIR:-${SLACK_CC_OPS_DIR:-$HOME/dvl/win-ops}}"
cd "$PROJECT_DIR"

log() { echo "[redeploy] $*"; }

if ! git diff --quiet --ignore-submodules HEAD --; then
  log "tracked files are dirty; refusing to pull over local changes"
  git status --short
  log "commit, stash, or discard the tracked edits first, then rerun redeploy.sh"
  exit 1
fi

log "1/6 pulling latest master from origin"
git pull --ff-only origin master 2>&1 | tail -5

log "2/6 generating bun.lock if needed (gitignored)"
if [ ! -f bun.lock ]; then
  bun install
fi

log "3/6 docker compose up -d --build --force-recreate slops"
HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || echo 1)" \
  docker compose up -d --build --force-recreate slops 2>&1 | tail -8

log "4/6 waiting for container to be up"
sleep 12

log "5/6 dismissing dev-channel warning prompt (sends Enter to tmux)"
docker exec slops tmux send-keys -t slops Enter 2>/dev/null || log "  (tmux not ready yet — entrypoint may still be sleeping; try again or check 'docker logs slops')"
sleep 8

log "6/6 waiting for Bolt to report 'connected as ...' in server.err"
for i in {1..20}; do
  if docker exec slops grep -q "slack channel: connected as" /state/inbox/server.err 2>/dev/null; then
    log "  ✓ $(docker exec slops tail -1 /state/inbox/server.err)"
    break
  fi
  sleep 1
done

log "done. Tail logs with: bash scripts/logs.sh"
log "Verify in Slack with: @slops what's the dev status?"
