# DEPENDENCIES

What needs to exist for `slack-cc-ops` to run.

## Mac mini (host)

- **Docker Desktop** running. The bot lives in a container, and orchestrates the `win-live` compose stack via the mounted docker socket.
- **bun** ≥ 1.3 on PATH for `superpea`. Used by `bootstrap-mini.sh` and `redeploy.sh`. Installed at `~/.bun/bin/bun`; scripts add this to PATH explicitly because non-interactive SSH doesn't source `~/.zshrc`.
- **git** — for cloning, pulling, and worktree management.
- **openssl** — for `openssl rand -hex 32` in token-rotation scripts.
- **`~/dvl/win-live/`** — the canonical win checkout. Must be a healthy git working tree on the `slack-cc-ops-bot` branch base (or wherever the bot's worktree was created from). The bot's read-only `/win` mount is a worktree of this.
- **`~/.win-deploy-controller/`** — controller state dir with `.env` (containing `WIN_DEPLOY_RUNTIME_TOKEN`) and `runtime.json`. The controller process listens on `:9475`.
- **`~/dvl/win-live/.env`** — gitignored; contains `WIN_DEPLOY_RUNTIME_TOKEN` for the server's compose env substitution. **Same value as `~/.win-deploy-controller/.env`** (both ends of the same handshake).

## Slack workspace (one-time setup)

- **Workspace**: `ole labs` (team ID `T0A0TGHUAP6`).
- **App**: `win-ops` (app ID `A0B5RPP0S7Q`). Manifest in `docs/implementation-notes/slack-app-manifest.json` (TODO — not currently committed; regenerate from the live app's manifest export).
- **Socket Mode**: **ON**.
- **Agents & AI Apps**: **OFF**. (If ON, Slack hijacks DMs into the AI Assistant pane and they don't fire `message.im` events.)
- **Bot scopes** (38, no `assistant:write`): `app_mentions:read`, `channels:history`, `channels:join`, `channels:manage`, `channels:read`, `channels:write.invites`, `channels:write.topic`, `chat:write`, `chat:write.public`, `commands`, `files:write`, `groups:history`, `groups:read`, `im:history`, `im:read`, `im:write`, `im:write.topic`, `incoming-webhook`, `links.embed:write`, `links:read`, `links:write`, `mpim:history`, `mpim:read`, `pins:write`, `search:read.files`, `search:read.im`, `search:read.mpim`, `search:read.private`, `search:read.public`, `search:read.users`, `team:read`, `usergroups:read`, `usergroups:write`, `users.profile:read`, `users:read`, `users:read.email`, `users:write`, `calls:write`.
- **Event subscriptions** (Subscribe to bot events): `app_mention`, `message.channels`, `message.groups`, `message.im`.
- **Tokens** — these live in `~/dvl/win-ops/.env` on the mini (chmod 600, gitignored):
  - `SLACK_BOT_TOKEN` — `xoxb-…`, from OAuth & Permissions page. **Only changes on full uninstall + reinstall**. Reinstall alone does NOT rotate it.
  - `SLACK_APP_TOKEN` — `xapp-…`, app-level token with `connections:write` scope from Basic Information page.
  - `SLACK_SIGNING_SECRET` — from Basic Information page.
- **Channel**: `#win-ops` (`C0B6N4T8EQ0`, public). Bot user (`@winops`, `U0B5MJ031C3`) must be invited.

## Bot's Anthropic credential

- The bot uses **Cam's Anthropic account** but in a **separate `CLAUDE_CONFIG_DIR`** (`/state/claude-config` inside container = `~/dvl/win-ops/.win-ops/claude-config` on host) so it doesn't race with Cam's host claude session for token refresh.
- Initial login: `docker exec -it slack-cc-ops claude login` (one-time, after first container start). Refresh happens in-place automatically thereafter — no rotation procedure needed unless the OAuth refresh token expires (months/years out).
- This means **the bot consumes Cam's Pro/Max quota**. If Scott uses it heavily, Cam's host claude usage will share that budget. Phase 2 plan is to route through win's `proxy` for multi-account load balancing.

## Container build-time

- Base image: `oven/bun:1-alpine` (built off Alpine — uses musl libc, which matters for the claude code binary symlink fix in the Dockerfile).
- Build arg `DOCKER_GID` — must match the host's `/var/run/docker.sock` GID (`stat -f '%g' /var/run/docker.sock` on macOS = `1`; `bootstrap-mini.sh` and `redeploy.sh` detect this automatically). Container's `botuser` gets added to that group so `docker ps` etc. work.
- Bun packages (installed inside container during build, from `package.json`): `@modelcontextprotocol/sdk`, `@slack/bolt` v4, `@types/bun`.

## What's NOT a dependency

- **A public HTTPS endpoint / Cloudflare Tunnel for the bot.** Socket Mode is outbound-only WebSocket. The bot dials Slack; Slack pushes events through that same connection. No incoming traffic = no tunnel needed for the bot itself. (`win-live` has its own cloudflared for `bigwinbeta.olelabs.xyz` — that's separate.)
- **A launchd plist for the bot container.** The container restart policy (`unless-stopped`) handles process death; the mini reboots are rare and manual restart via `redeploy.sh` is fine for now. **The deploy controller** does need a launchd plist eventually (currently dies on reboot — see followup).
- **A separate Anthropic account for the bot.** We considered it; opted to share Cam's account via separate config dir.

## Tokens that exist and where they live

| Token | Where set | Where read |
|-|-|-|
| `SLACK_BOT_TOKEN` (`xoxb-`) | `~/dvl/win-ops/.env` | bot container env (loaded by `env_file:` in compose) |
| `SLACK_APP_TOKEN` (`xapp-`) | `~/dvl/win-ops/.env` | bot container env |
| `SLACK_SIGNING_SECRET` | `~/dvl/win-ops/.env` | bot container env |
| `WIN_DEPLOY_CONTROLLER_TOKEN` | `~/dvl/win-ops/.env` (bot side) | bot container env, used by `win deploy *` to auth to controller |
| `WIN_DEPLOY_CONTROLLER_TOKEN` | `~/.win-deploy-controller/.env` (controller side) | controller process env at launch, validates incoming requests |
| `WIN_DEPLOY_RUNTIME_TOKEN` | `~/dvl/win-live/.env` (server side) | win-live's `server` container env (compose substitution) |
| `WIN_DEPLOY_RUNTIME_TOKEN` | `~/.win-deploy-controller/.env` (controller side) | controller process env, presented when controller calls `/api/deploy/runtime/*` on the server |
| Claude OAuth tokens | `~/dvl/win-ops/.win-ops/claude-config/.credentials.json` | container's claude process |

**Two pairs that must match**:
- `WIN_DEPLOY_CONTROLLER_TOKEN` on bot side ↔ controller side
- `WIN_DEPLOY_RUNTIME_TOKEN` on server side ↔ controller side

Rotation: regenerate with `openssl rand -hex 32`, update both sides, recreate the affected container(s). Documented in `~/dvl/win-live/docs/followups/2026-05-23-deploy-runtime-token-setup.md`.
