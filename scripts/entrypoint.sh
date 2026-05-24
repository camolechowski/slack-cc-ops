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

# Pre-seed .claude.json with onboarding bypass so claude doesn't drop into
# the welcome wizard on each container start. Mirrors win/daemon's
# ensureSharedInteractiveState() in packages/daemon/src/tmux-suggester.ts.
CONFIG_FILE="$CLAUDE_CONFIG_DIR/.claude.json"
if [[ ! -f "$CONFIG_FILE" ]] || ! grep -q '"hasCompletedOnboarding"' "$CONFIG_FILE"; then
  NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  if [[ -f "$CONFIG_FILE" ]]; then
    # Merge into existing JSON without bun installed in container PATH for botuser
    # via a tiny Bun one-liner (bun is on PATH from the base image).
    bun -e "
      const fs = require('fs');
      const p = '$CONFIG_FILE';
      const cur = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {};
      const next = { ...cur,
        theme: typeof cur.theme === 'string' ? cur.theme : 'dark',
        hasCompletedOnboarding: true,
        firstStartTime: typeof cur.firstStartTime === 'string' ? cur.firstStartTime : '$NOW',
      };
      fs.writeFileSync(p, JSON.stringify(next, null, 2) + '\n');
    "
  else
    cat > "$CONFIG_FILE" <<EOF
{
  "theme": "dark",
  "hasCompletedOnboarding": true,
  "firstStartTime": "$NOW"
}
EOF
  fi
  chmod 600 "$CONFIG_FILE"
  echo "[slack-cc-ops] Pre-seeded $CONFIG_FILE with onboarding bypass."
fi

# Claude requires a TTY — without one it auto-switches to --print mode and
# errors. Spawn it inside a tmux session, with daemon-style flags and env.
SYSTEM_PROMPT="$(cat /app/system-prompts/win-ops.md)"
SESSION=slackcc
LOG=/state/inbox/claude.log

tmux kill-session -t "$SESSION" 2>/dev/null || true
: > "$LOG"

# Launch matches the channels-doc invocation:
#   claude --dangerously-load-development-channels server:slack-channel
# with --permission-mode bypassPermissions (daemon pattern, supersedes
# settings.json defaultMode for clarity) and daemon-style env hygiene.
LAUNCH="cd /app && \
  DISABLE_AUTOUPDATER=1 \
  USE_BUILTIN_RIPGREP=0 \
  CLAUDE_PLUGIN_ROOT=/app \
  claude \
    --permission-mode bypassPermissions \
    --append-system-prompt $(printf '%q' "$SYSTEM_PROMPT") \
    --dangerously-load-development-channels server:slack-channel"

tmux new-session -d -s "$SESSION" -x 240 -y 60 "bash -ic $(printf '%q' "$LAUNCH")"

# Mirror pane output to a log file -> docker logs (via PID 1 stdout).
tmux pipe-pane -o -t "$SESSION" "cat >> $LOG"
tail -F "$LOG" &
TAIL_PID=$!

# Block until tmux session goes away.
while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 5
done

kill "$TAIL_PID" 2>/dev/null || true
echo "[slack-cc-ops] tmux session ended — exiting so compose can restart"
exit 1
