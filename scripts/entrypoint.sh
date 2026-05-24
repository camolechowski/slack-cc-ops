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
  echo "[slack-cc-ops] No Claude credentials yet."
  echo "[slack-cc-ops] Run: docker exec -it slack-cc-ops claude login"
  echo "[slack-cc-ops] Then: docker compose restart slack-cc-ops"
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
  echo "[slack-cc-ops] Pre-seeded $CONFIG_FILE with Claude startup acknowledgements."
fi

# Claude requires a TTY — without one it auto-switches to --print mode and
# errors. Spawn it inside a tmux session, with daemon-style flags and env.
#
# IMPORTANT: write the launch to a shell script and have tmux exec that
# directly. Inline 'bash -ic "..."' with printf '%q' nested quoting was
# silently dropping the trailing --dangerously-load-development-channels
# flag, leaving the channel server unspawned.
SESSION=slackcc
LOG=/state/inbox/claude.log
LAUNCH_SCRIPT=/tmp/slack-cc-ops-launch.sh

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
  echo "[slack-cc-ops] No bun server.ts running but $LOCK exists — clearing stale lock"
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

# Mirror pane output to a log file -> docker logs (via PID 1 stdout).
tmux pipe-pane -o -t "$SESSION" "cat >> $LOG"
tail -F "$LOG" &
TAIL_PID=$!

# Liveness loop — exit (and let compose restart us) when ANY of:
#   - tmux session dies (claude crashed)
#   - bun server.ts dies (MCP channel server crashed; tmux/claude may be
#     up but the bot can't receive Slack events without this)
#
# Give bun server.ts a few seconds to start up before we begin enforcing.
sleep 30

while tmux has-session -t "$SESSION" 2>/dev/null; do
  if ! pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
    echo "[slack-cc-ops] bun server.ts (the channel MCP) is no longer running — exiting so compose restarts the container"
    break
  fi
  sleep 10
done

kill "$TAIL_PID" 2>/dev/null || true
echo "[slack-cc-ops] liveness loop exiting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 1
