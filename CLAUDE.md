# slack-cc-ops — repo handbook

`AGENTS.md` is the short operational checklist for future agents. Read that first if you need the fast path; use this file for the full architecture and file-level handbook.

> For future engineers (human or AI) working **on this repo** — bot code, container, deploy scripts, system prompt.
> If you're looking for the bot's **operational instructions**, read `system-prompts/win-ops.md`. That's what the running bot sees.

## What this repo is

A fork of [`retrodigio/claude-channel-slack`](https://github.com/retrodigio/claude-channel-slack) (Apache-2.0) customized for one specific deployment: a persistent Claude Code session in a Docker container on a Mac mini, driven from the `#win-ops` channel in the `ole labs` Slack workspace. Principals: **Cam** + **Scott**. The bot operates the **BigWin/win** platform (located at `~/dvl/win-live/` on the mini, mirrored at `~/code/work/plex/win/` on Cam's laptop).

Tonight (2026-05-23) we got the full Slack ↔ Bolt ↔ Claude Code ↔ `win` CLI loop working end-to-end after a ~5 hour debug session that included: token rotation gotchas, Slack's AI Assistant scope hijacking events, runtime token plumbing through `~/dvl/win-live/docker-compose.yml`. See `docs/implementation-notes/` and the corresponding day's followup in `~/dvl/win-live/docs/followups/` for the gory details.

## Architecture

```
[ Slack workspace: ole labs / #win-ops ]
        │ ▲                                              [ Cam + Scott on phones/laptops ]
        │ │  Socket Mode (outbound WebSocket, no public ingress)
        ▼ │
┌─────────────────────────────────────────────────────────────────────┐
│ Mac mini (superpea@mac-mini)                                         │
│                                                                       │
│  Docker compose project: win-ops                                      │
│   └─ container: slack-cc-ops                                          │
│       ├─ tmux session "slackcc"                                       │
│       │   └─ claude CLI (persistent REPL)                             │
│       │       └─ MCP subprocess: bash wrapper → bun server.ts         │
│       │           (the slack-channel MCP — Bolt receiver +            │
│       │            reply/react/edit_message/etc. tools)               │
│       ├─ mounts: ./state→/state, ./win→/win:ro, /var/run/docker.sock  │
│       └─ env: SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_SIGNING_SECRET, │
│              WIN_DEPLOY_CONTROLLER_TOKEN, HOST_DOCKER_GID, etc.       │
│                                                                       │
│  Sibling compose projects (not ours):                                 │
│   ├─ win-live      (the beta runtime — bigwinbeta.olelabs.xyz)        │
│   ├─ win-staging   (the staging runtime)                              │
│   └─ deploy controller (bun script, listens on :9475)                 │
└─────────────────────────────────────────────────────────────────────┘
```

## Layout (what file does what)

### Upstream files (keep close to retrodigio)
- `server.ts` — Slack Bolt receiver + MCP server. Channel events become `notifications/claude/channel` to claude; claude calls `reply`/`react`/`edit_message` tools back. **Touch sparingly** — only when intentionally diverging from upstream.
- `gate.ts` — allowlist + per-channel policy logic (default-allow humans, default-deny bots, requireMention).
- `gate.test.ts`, `LICENSE`, `ACCESS.md`, `routes.example.json` — upstream. Leave alone.
- `.mcp.json` — declares the `slack-channel` MCP server with a `bash -c "exec bun ... 2> >(tee -a /state/inbox/server.err >&2)"` wrapper so we can actually see Bolt's stderr (it's otherwise swallowed by claude's MCP stdio capture).

### Our fork-specific files
- `Dockerfile` — `oven/bun:1-alpine` base, installs claude code globally via `BUN_INSTALL=/usr/local`, re-symlinks the musl variant of claude (Alpine quirk), adds `bash`/`git`/`docker-cli`/`tmux`. Botuser shell is `/bin/bash` (NOT nologin — tmux needs a real shell).
- `docker-compose.yml` — single-service stack named `slack-cc-ops`. Bind-mounts `./state`, `./win`, the host-side git metadata paths that the `/win` worktree points at, and `/var/run/docker.sock`. No public ports (Socket Mode is outbound-only).
- `scripts/entrypoint.sh` — symlinks `/app/settings.json` into `$CLAUDE_CONFIG_DIR`, creates the `win` shim, pre-seeds `.claude.json` with onboarding bypass + project trust + bypass-permissions acceptance, clears stale `plugin.lock`, launches claude in tmux via `/tmp/slack-cc-ops-launch.sh` (which must be written as a file — inlining via `bash -ic` ate the `--dangerously-load-development-channels` flag).
- `scripts/bootstrap-mini.sh` — first-run setup on a fresh Mac mini. See below.
- `scripts/redeploy.sh|restart.sh|logs.sh|exec.sh` — operator quality-of-life (added 2026-05-23).
- `system-prompts/win-ops.md` — **the bot's principal system prompt**. This is what gets `--append-system-prompt`'d to the running claude. Update this when you want to change bot behavior — the running container reads it on every start.
- `settings.json` — claude's in-container `~/.claude/settings.json`. Enables `bypassPermissions` mode + registers the `PreToolUse` Bash hook.
- `hooks/pretooluse-bash.sh` — **the only tool-level gate** in v1. Allows `win` subcommands + a short read-only safelist; denies everything else. Read this before granting more.
- `hooks/on-session-start.sh` — lifted from odfalik's plugin. Writes `/state/sessions/${PPID}.json` so server.ts can find the conversation_id for thread persistence.
- `skills/access/`, `skills/threads/`, `skills/configure/` — upstream skills (access mgmt, thread dispatch, token configure). Threads skill currently misregistered ("Unknown skill") — followup.

## State

`./.win-ops/` is gitignored and bind-mounted into the container at `/state`. Directory shape:

- `.win-ops/claude-config/` — `$CLAUDE_CONFIG_DIR` target. `.credentials.json` (OAuth, written by interactive `claude login` on first boot), `.claude.json` (config including pre-seeded acknowledgements), `settings.json` (symlink → `/app/settings.json`).
- `.win-ops/channels/slack/` — channel-server state. `access.json` (allowlist), `routes.json` (channel ID → working dir mapping), `threads.json` (thread_ts → conversation_id), `plugin.lock` (PID singleton).
- `.win-ops/inbox/` — server.err (Bolt's stderr, tee'd), claude.log (tmux pane mirror), health.sock (created by server.ts when Bolt is up — healthcheck reads this).
- `.win-ops/sessions/` — `${PPID}.json` files from the SessionStart hook.

`./win/` is also gitignored and bind-mounted at `/win:ro`. It's a git worktree of `~/dvl/win-live/` on the `slack-cc-ops-bot` branch off main — the bot's read-only view of the win monorepo. Because git worktrees store metadata in the source repo's `.git/worktrees/...` directory, the container also bind-mounts the host-style absolute metadata paths (`/Users/superpea/dvl/win-ops/win` and `/Users/superpea/dvl/win`) so `git -C /win ...` works inside the container.

## Bootstrap on a fresh Mac mini

(Assumes Docker Desktop is running and `~/dvl/win-live/` exists.)

```bash
ssh superpea@mac-mini
mkdir -p ~/dvl && cd ~/dvl
git clone git@github.com:camolechowski/slack-cc-ops.git win-ops
cd win-ops
./scripts/bootstrap-mini.sh        # creates worktree, prompts for Slack secrets, builds + starts container
docker exec -it slack-cc-ops claude login   # paste OAuth code back
docker compose restart slack-cc-ops          # entrypoint sees credentials, claude starts for real
docker exec -it slack-cc-ops claude /slack-channel:access pair @cam
docker exec -it slack-cc-ops claude /slack-channel:access pair @scott
```

`bootstrap-mini.sh` handles: docker preflight, win worktree creation (`~/dvl/win-live → ~/dvl/win-ops/win` on `slack-cc-ops-bot` branch), `bun install` in the worktree, interactive Slack secret entry (writes `.env` chmod 600), `bun install` in project dir to generate `bun.lock`, `docker compose up -d --build`.

## Iterating on the bot from Cam's laptop

1. Edit `system-prompts/win-ops.md` (or `Dockerfile`, `hooks/`, etc.) here on the laptop
2. `git add … && git commit -m "..." && git push origin master`
3. On the mini, `bash scripts/redeploy.sh` — pulls, rebuilds, recreates, dismisses the dev-channel prompt, tails until "Slack socket connected" appears
4. Test in `#win-ops`

For trivial prompt-only changes (no Dockerfile/scripts changes), `bash scripts/restart.sh` is faster — just `docker compose restart` without rebuilding.

## Operator scripts

All in `scripts/`:

| Script | Purpose |
|-|-|
| `bootstrap-mini.sh` | One-time setup on a fresh mini |
| `entrypoint.sh` | Container PID 1 launcher (not run by humans) |
| `container-healthcheck.sh` | In-container capability healthcheck used by Docker health status |
| `redeploy.sh` | Pull latest from master + rebuild image + force-recreate + dismiss dev-channel prompt |
| `restart.sh` | Restart container only (no rebuild) — for prompt-only iteration |
| `healthcheck.sh` | Host-side end-to-end audit for bot auth, Slack connectivity, core operator commands, beta health, and deploy controller |
| `logs.sh` | Tail `server.err` + `claude.log` cleanly (ANSI stripped, trigger-filtered) |
| `exec.sh` | `ssh + docker exec -it` into the container's bash shell |

Run them on the mini via SSH (or from the laptop as `ssh superpea@mac-mini 'bash ~/dvl/win-ops/scripts/<name>.sh'`).

## Common gotchas

- **`docker compose restart` does NOT reload `.env`** — use `up -d --force-recreate` if you've changed env vars.
- **Bolt's WebSocket subscription set is fixed at connect time** — if you change Slack app event subscriptions, you need to restart the container so server.ts opens a fresh WS.
- **server.ts's stderr is captured by claude's MCP stdio** — that's why `.mcp.json` wraps the launch with `bash -c "exec ... 2> >(tee -a /state/inbox/server.err >&2)"`. Without that wrapper, you're flying blind on Bolt failures.
- **`--dangerously-load-development-channels` will fire a confirmation prompt** on every container start. The entrypoint waits for `Enter` via tmux send-keys after startup; if you're tail-following logs from a fresh start and it looks stuck, that's why.
- **Tokens** — `SLACK_BOT_TOKEN` is set at app install time and only changes when you fully uninstall+reinstall (re-installs don't rotate). If you ever see stale-scope behavior (e.g. `auth.test` returns a scope that's not in the OAuth UI's scope list anymore), the token needs to be rotated via uninstall+reinstall, not just reinstall.
- **Slack `assistant:write` scope** — if Agents & AI Apps is enabled OR `assistant:write` is granted, Slack hijacks DMs into the AI Assistant pane and they don't fire `message.im` events. Keep both **off**.
- **`#win-ops` is public** (`is_private: False`) — the gate.ts allowlist is the only access control.

## Upstream tracking

Pull future updates from retrodigio:

```bash
git remote add upstream https://github.com/retrodigio/claude-channel-slack
git fetch upstream
git merge upstream/master    # or rebase, depending on how invasive the changes are
```

Keep the diff against upstream **small and surgical**. Files to keep close to upstream: `server.ts`, `gate.ts`, `gate.test.ts`, `routes.example.json`, `ACCESS.md`, `LICENSE`, `.npmrc`.

## Plan + design docs

- Original plan: `~/.claude/plans/that-sounds-write-jaunty-pascal.md`
- Tonight's deploy-runtime-token followup (in win-live, not this repo): `~/dvl/win-live/docs/followups/2026-05-23-deploy-runtime-token-setup.md`
- Implementation notes from the multi-agent initial scaffold: `docs/implementation-notes/`

## Phase 2 backlog (not in scope tonight)

- Replace `bypassPermissions` + minimal Bash hook with proper `allow`/`ask`/`deny` scheme per the categorized win CLI surface
- Make `/win` mount read-write so the bot can apply diffs directly
- Add Write/Edit tools, WebFetch tool, OpenAI API key
- Migrate to a launchd plist for the deploy controller (currently restart-on-reboot is manual)
- Fix the `slack-channel:threads` skill registration so per-thread subagents work
- Fix the win quiescence bookkeeping bug (terminal-state jobs counted as active)
- Integrate with win's `proxy` for inference (free observability + multi-account routing without teamclaude)
