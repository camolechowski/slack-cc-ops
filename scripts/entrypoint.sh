#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$CLAUDE_CONFIG_DIR" /state/inbox /usr/local/bin

ln -sfn /app/settings.json "$CLAUDE_CONFIG_DIR/settings.json"

# `win` shim: runs @win/cli from the mounted worktree via Bun.
cat > /usr/local/bin/win <<'WIN_SHIM'
#!/bin/sh
exec bun /win/packages/cli/src/index.ts "$@"
WIN_SHIM
chmod +x /usr/local/bin/win

if [[ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
  echo "[slops] No Claude credentials yet."
  echo "[slops] Run: docker exec -it slops claude login"
  echo "[slops] Then: docker compose restart slops"
  exec sleep infinity
fi

# Pre-seed .claude.json with the interactive acknowledgements needed for
# unattended restarts: onboarding, project trust for /app, and the legacy
# bypass-permissions warning bit. Current Claude versions read the bypass
# warning from settings.json; the legacy key is retained for nearby versions.
CONFIG_FILE="$CLAUDE_CONFIG_DIR/.claude.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
PRESEED_RESULT="$(CONFIG_FILE="$CONFIG_FILE" NOW="$NOW" bun -e '
  const fs = require("fs");
  const p = process.env.CONFIG_FILE;
  const now = process.env.NOW;
  const isObject = (value) => value && typeof value === "object" && !Array.isArray(value);
  let cur = {};
  if (fs.existsSync(p)) {
    try {
      cur = JSON.parse(fs.readFileSync(p, "utf8"));
    } catch {
      cur = {};
    }
  }
  const projectPath = "/app";
  const defaultProject = {
    allowedTools: [],
    mcpContextUris: [],
    mcpServers: {},
    enabledMcpjsonServers: [],
    disabledMcpjsonServers: [],
    hasTrustDialogAccepted: false,
    projectOnboardingSeenCount: 0,
    hasClaudeMdExternalIncludesApproved: false,
    hasClaudeMdExternalIncludesWarningShown: false,
  };
  const projects = isObject(cur.projects) ? cur.projects : {};
  const existingProject = isObject(projects[projectPath]) ? projects[projectPath] : {};
  const next = {
    ...cur,
    theme: typeof cur.theme === "string" ? cur.theme : "dark",
    hasCompletedOnboarding: true,
    firstStartTime: typeof cur.firstStartTime === "string" ? cur.firstStartTime : now,
    bypassPermissionsModeAccepted: true,
    projects: {
      ...projects,
      [projectPath]: {
        ...defaultProject,
        ...existingProject,
        hasTrustDialogAccepted: true,
      },
    },
  };
  if (JSON.stringify(next) !== JSON.stringify(cur)) {
    fs.writeFileSync(p, JSON.stringify(next, null, 2) + "\n");
    console.log("updated");
  }
')"
if [[ "$PRESEED_RESULT" == "updated" ]]; then
  chmod 600 "$CONFIG_FILE"
  echo "[slops] Pre-seeded $CONFIG_FILE with Claude startup acknowledgements."
fi

# Claude requires a TTY — without one it auto-switches to --print mode and
# errors. Spawn it inside a tmux session, with daemon-style flags and env.
#
# IMPORTANT: write the launch to a shell script and have tmux exec that
# directly. Inline 'bash -ic "..."' with printf '%q' nested quoting was
# silently dropping the trailing --dangerously-load-development-channels
# flag, leaving the channel server unspawned.
SESSION=slops
LOG=/state/inbox/claude.log
LAUNCH_SCRIPT=/tmp/slops-launch.sh

# Channel plugin state — server.ts reads $SLACK_STATE_DIR or falls back to
# $HOME/.claude/channels/slack. We want it on the bind mount so access.json,
# routes.json, and threads.json survive container rebuilds.
mkdir -p /state/channels/slack

# Clear the plugin.lock if no bun server.ts is actually running. Container
# restarts wipe the previous bun process but the lock file persists on the
# bind mount with the dead PID, and server.ts's stale-detection sometimes
# misclassifies — leaving the new server.ts process refusing to start.
LOCK=/state/channels/slack/plugin.lock
if [ -f "$LOCK" ] && ! pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
  echo "[slops] No bun server.ts running but $LOCK exists — clearing stale lock"
  rm -f "$LOCK"
fi

cat > "$LAUNCH_SCRIPT" <<'LAUNCH_EOF'
#!/bin/bash
set -e
cd /app
export DISABLE_AUTOUPDATER=1
export USE_BUILTIN_RIPGREP=0
export CLAUDE_PLUGIN_ROOT=/app
export SLACK_STATE_DIR=/state/channels/slack
exec claude \
  --permission-mode bypassPermissions \
  --append-system-prompt "$(cat /app/system-prompts/win-ops.md)" \
  --dangerously-load-development-channels server:slack-channel
LAUNCH_EOF
chmod +x "$LAUNCH_SCRIPT"

tmux kill-session -t "$SESSION" 2>/dev/null || true
: > "$LOG"

tmux new-session -d -s "$SESSION" -x 240 -y 60 "$LAUNCH_SCRIPT"

slog() { echo "[slops] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

WEDGED_MARKER=/state/inbox/WEDGED
rm -f "$WEDGED_MARKER" 2>/dev/null || true

# A fresh boot can land directly on the interactive session-limit modal. The
# safe default is option "1. Stop and wait for limit to reset" — acknowledge it
# so the container doesn't hang on an unattended modal. The supervisor loop
# below then catches the wedge state and marks the container unhealthy.
acknowledge_limit_modal() {
  local pane="$1"
  case "$pane" in
    *"Stop and wait"*|*"wait for limit to reset"*)
      slog "session-limit modal detected — acknowledging '1. Stop and wait'"
      tmux send-keys -t "$SESSION" "1" 2>/dev/null || true
      tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
      return 0
      ;;
  esac
  return 1
}

# Newer Claude builds prompt for confirmation before loading development
# channels. The default selection is the safe "local development" option, so
# acknowledge it automatically until the channel MCP is actually alive. A boot
# that lands on the session-limit modal is acknowledged here too.
for _ in 1 2 3 4 5 6 7 8; do
  if pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
    break
  fi
  boot_pane="$(tmux capture-pane -pt "$SESSION" 2>/dev/null || true)"
  if grep -q "Loading development channels" <<<"$boot_pane"; then
    echo "[slops] Confirming Claude development-channel prompt"
    tmux send-keys -t "$SESSION" Enter
  fi
  acknowledge_limit_modal "$boot_pane" || true
  sleep 2
done

# Mirror pane output to a log file -> docker logs (via PID 1 stdout).
tmux pipe-pane -o -t "$SESSION" "cat >> $LOG"
tail -F "$LOG" &
TAIL_PID=$!

# Liveness loop — exit (and let compose restart us) when ANY of:
#   - tmux session dies (claude crashed)
#   - bun server.ts dies (MCP channel server crashed; tmux/claude may be
#     up but the bot can't receive Slack events without this)
#   - Claude hits its usage/session limit (a "wedge": every process stays up
#     but Claude is unresponsive). We mark the container unhealthy via a marker
#     file the healthcheck fails on, and exit for a compose restart.
#
# It also narrates lifecycle to stdout (-> docker logs) so an operator can tell
# a live-but-idle bot from a wedged one without reading the ANSI pane mirror.
#
# Give bun server.ts a few seconds to start up before we begin enforcing.
sleep 30
slog "liveness loop started — supervising tmux session '$SESSION' + bun server.ts"

prev_activity=""
wedged=false
heartbeat_ticks=0
HEARTBEAT_EVERY=30   # ~5 min at a 10s interval

while tmux has-session -t "$SESSION" 2>/dev/null; do
  if ! pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
    slog "bun server.ts (the channel MCP) is no longer running — exiting so compose restarts the container"
    break
  fi

  pane="$(tmux capture-pane -pt "$SESSION" 2>/dev/null || true)"

  # Wedge detection: the usage/session-limit state. Act once, on first sight.
  if [[ "$wedged" == false ]]; then
    case "$pane" in
      *"session limit"*|*"usage limit"*|*"hit your limit"*|*"wait for limit to reset"*|*"Stop and wait"*)
        wedged=true
        slog "WEDGE DETECTED: Claude session/usage limit — writing $WEDGED_MARKER, acknowledging modal, exiting for restart"
        acknowledge_limit_modal "$pane" || true
        printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) session-limit wedge" >"$WEDGED_MARKER" 2>/dev/null || true
        break
        ;;
    esac
  fi

  # Lifecycle narration: derive busy/idle from the pane and log on transitions.
  # "esc to interrupt" / a running-token line means Claude is actively working;
  # the prompt box (│ >) with no working indicator means it is idle and ready.
  activity="idle"
  case "$pane" in
    *"esc to interrupt"*|*"tokens ·"*|*"Running…"*|*"Thinking…"*) activity="busy" ;;
  esac
  if [[ "$activity" != "$prev_activity" ]]; then
    case "$activity" in
      busy) slog "session-busy — Claude is processing a message" ;;
      idle) [[ -n "$prev_activity" ]] && slog "session-idle — Claude finished, awaiting next message" ;;
    esac
    prev_activity="$activity"
  fi

  heartbeat_ticks=$((heartbeat_ticks + 1))
  if (( heartbeat_ticks >= HEARTBEAT_EVERY )); then
    slog "alive — session '$SESSION' up, server.ts up, state=$activity"
    heartbeat_ticks=0
  fi

  sleep 10
done

kill "$TAIL_PID" 2>/dev/null || true
slog "liveness loop exiting"
exit 1
