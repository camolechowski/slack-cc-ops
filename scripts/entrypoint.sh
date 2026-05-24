#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$CLAUDE_CONFIG_DIR" /state/inbox /usr/local/bin

ln -sfn /app/settings.json "$CLAUDE_CONFIG_DIR/settings.json"

# `win` shim: runs the @win/cli source from the mounted worktree via Bun.
# The worktree is bind-mounted read-only; bun resolution doesn't write.
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

# Claude requires a TTY — without one it auto-switches to --print mode and
# errors out. Spawn it inside a tmux session (which provides a pty), then
# pipe the pane output to PID 1's stdout so it shows up in `docker logs`.
SYSTEM_PROMPT="$(cat /app/system-prompts/win-ops.md)"
SESSION=slackcc

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 240 -y 60 \
  "claude --append-system-prompt $(printf '%q' "$SYSTEM_PROMPT")"

# Mirror pane output to a log file so `docker logs` sees it.
LOG=/state/inbox/claude.log
: > "$LOG"
tmux pipe-pane -o -t "$SESSION" "cat >> $LOG"

# Tail the log and forward to PID 1's stdout; if the tmux session dies,
# this process exits and the container restarts (per compose policy).
tail -F "$LOG" &
TAIL_PID=$!

# Block until tmux session goes away.
while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 5
done

kill "$TAIL_PID" 2>/dev/null || true
echo "[slack-cc-ops] tmux session ended — exiting so compose can restart"
exit 1
