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

exec claude --append-system-prompt "$(cat /app/system-prompts/win-ops.md)"
