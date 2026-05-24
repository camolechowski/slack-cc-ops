#!/usr/bin/env bash
set -euo pipefail

# Bootstrap slack-cc-ops on the Mac mini.
#
# Expected layout:
#   ~/dvl/win-ops/            (this repo, cloned here)
#   ~/dvl/win-ops/win/        (git worktree of ~/dvl/win-live tracking main)
#   ~/dvl/win-ops/state/      (gitignored, bind-mounted to /state in container)
#   ~/dvl/win-ops/.env        (created interactively if missing, chmod 600)
#
# Run from inside ~/dvl/win-ops/.

log() {
  echo "[slack-cc-ops] $*"
}

detect_docker_gid() {
  local gid
  if gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null)"; then
    echo "$gid"
    return 0
  fi
  if gid="$(stat -f '%g' /var/run/docker.sock 2>/dev/null)"; then
    echo "$gid"
    return 0
  fi
  echo "999"
}

prompt_secret() {
  local name="$1"
  local value
  read -r -s -p "$name: " value
  echo >&2
  printf '%s' "$value"
}

if ! docker info >/dev/null 2>&1; then
  echo "[slack-cc-ops] docker info failed; start Docker Desktop on the Mac mini and retry." >&2
  exit 1
fi

# Source win repo (where to add the worktree FROM). Default ~/dvl/win-live.
WIN_LIVE="${WIN_LIVE:-$HOME/dvl/win-live}"
PROJECT_DIR="$(pwd)"
WIN_WORKTREE_DIR="$PROJECT_DIR/win"

if [[ ! -d "$WIN_LIVE/.git" ]] && [[ ! -f "$WIN_LIVE/.git" ]]; then
  echo "[slack-cc-ops] Cannot find win repo at $WIN_LIVE (override with WIN_LIVE=...)." >&2
  exit 1
fi

# `main` is typically already checked out in another worktree on the mini.
# Use a dedicated branch for the bot so multiple worktrees can coexist.
# To sync the bot to latest main: cd into ./win and run
#   git fetch && git reset --hard origin/main
WORKTREE_BRANCH="${WORKTREE_BRANCH:-slack-cc-ops-bot}"

if [[ ! -e "$WIN_WORKTREE_DIR" ]]; then
  if git -C "$WIN_LIVE" rev-parse --verify "$WORKTREE_BRANCH" >/dev/null 2>&1; then
    log "Branch $WORKTREE_BRANCH already exists in $WIN_LIVE; checking it out at $WIN_WORKTREE_DIR"
    git -C "$WIN_LIVE" worktree add "$WIN_WORKTREE_DIR" "$WORKTREE_BRANCH"
  else
    log "Creating branch $WORKTREE_BRANCH from main at $WIN_WORKTREE_DIR"
    git -C "$WIN_LIVE" worktree add -b "$WORKTREE_BRANCH" "$WIN_WORKTREE_DIR" main
  fi
  log "Running bun install in the worktree"
  (cd "$WIN_WORKTREE_DIR" && bun install)
else
  log "Using existing win worktree at $WIN_WORKTREE_DIR"
fi

export HOST_DOCKER_GID="${HOST_DOCKER_GID:-$(detect_docker_gid)}"

if [[ ! -f .env ]]; then
  log "Creating .env (will prompt for Slack secrets)"
  SLACK_BOT_TOKEN="$(prompt_secret "SLACK_BOT_TOKEN (xoxb-...)")"
  SLACK_APP_TOKEN="$(prompt_secret "SLACK_APP_TOKEN (xapp-...)")"
  SLACK_SIGNING_SECRET="$(prompt_secret "SLACK_SIGNING_SECRET")"

  umask 077
  cat > .env <<EOF
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
SLACK_APP_TOKEN=$SLACK_APP_TOKEN
SLACK_SIGNING_SECRET=$SLACK_SIGNING_SECRET
HOST_DOCKER_GID=$HOST_DOCKER_GID
EOF
  chmod 600 .env
else
  log "Using existing .env"
fi

log "Building and starting slack-cc-ops"
docker compose up -d --build

cat <<'EOF'

[slack-cc-ops] Container started.

Next steps:
  1. Interactive login:
       docker exec -it slack-cc-ops claude login
     (open the URL in your browser, paste the code back)

  2. Restart so claude picks up the credentials:
       docker compose restart slack-cc-ops

  3. Tail logs and watch for "Slack socket connected":
       docker compose logs -f slack-cc-ops

  4. Pair Slack users (run for each — Cam + dad):
       docker exec -it slack-cc-ops claude /slack-channel:access pair @cam
       docker exec -it slack-cc-ops claude /slack-channel:access pair @dad
EOF
