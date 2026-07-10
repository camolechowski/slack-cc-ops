# slops agent notes

(Formerly **slack-cc-ops** / **win-ops** — renamed to **slops** (BigWin AI Slack Ops Agent) on 2026-06-09.)

Start here for the fast path. `CLAUDE.md` is the full repo handbook; this file is the short operational contract for agents making changes or deploying the bot.

## What this repo controls

- This repo runs the `#win-ops` Slack bot on `ssh superpea@mac-mini`.
- The repo checkout on the mini is `~/dvl/win-ops`.
- The container is `slops` in the `docker compose` stack (project name `slops`) rooted at that checkout.
- The bot talks to Slack over Socket Mode only; there are no public HTTP ports to validate.

## First files to read

- `CLAUDE.md` for architecture, file map, and operator scripts.
- `system-prompts/win-ops.md` for the bot's runtime behavior contract.
- `docs/implementation-notes/README.md` plus the relevant note before non-trivial changes.

## Deployment contract

- Canonical branch is `master`. `scripts/redeploy.sh` pulls `origin/master`, rebuilds, force-recreates the container, dismisses the Claude dev-channel prompt, and waits for Slack reconnect logs.
- `scripts/restart.sh` is only for prompt/config changes that do not need a rebuild.
- Before redeploying, check `git status --short`. Tracked local edits on the mini will block `git pull --ff-only` and strand fixes outside a commit.
- Preferred remote flow:
  1. `ssh superpea@mac-mini`
  2. `cd ~/dvl/win-ops`
  3. `bash scripts/redeploy.sh`

## Mac mini Docker gotcha

- The container mounts `/var/run/docker.sock` so the bot can inspect sibling containers and assist with WIN deploy/debug tasks.
- On Docker Desktop for macOS, the mounted socket may appear inside the container as `root:root` with mode `660` even when host-side GID detection says otherwise.
- The image must keep `botuser` in group `0` as well as the detected socket group. If not, `docker ps` and `docker exec` fail with `permission denied while trying to connect to the Docker daemon socket`.
- After touching Docker permissions, validate with:
  - `docker exec slops sh -lc 'id && ls -ln /var/run/docker.sock && docker ps --format "{{.Names}}"'`
- `/win` is a mounted git worktree, not a plain clone. To let `git -C /win ...` resolve `origin/main`, the container must also mount the host-side worktree metadata paths that `/win/.git` points at:
  - `./win -> /Users/superpea/dvl/win-ops/win`
  - `/Users/superpea/dvl/win -> /Users/superpea/dvl/win`
- If the bot says `/win` is a dangling worktree or "not a git repository," check those companion mounts before reaching for `GH_TOKEN`.
- The hook now allows `git -C /win ...` read verbs directly. If a `git` diagnostic is denied, inspect the hook before assuming the worktree mounts broke.

## Health and validation

- Healthy runtime signals:
  - `docker compose ps` shows `slops` as `Up` and `healthy`
  - `docker exec slops tail -40 /state/inbox/server.err` includes `slack channel: connected as`
  - `docker exec slops tmux capture-pane -pt slops | tail -40` shows Claude at an interactive prompt instead of a stuck startup screen
- The Docker healthcheck is intentionally stronger than a plain process probe. It verifies:
  - Claude is running
  - the Slack MCP process is running
  - `git -C /win` can resolve `origin/main`
  - `docker ps` works from inside the bot container
  - `gh` is installed and the `GH_TOKEN` environment contract is populated
  - `win whoami` is still `oauth-active`
  - at least one successful Slack connection was logged
- The current image auto-confirms Claude's "Loading development channels" prompt during startup. If startup looks wedged, inspect `scripts/entrypoint.sh` and the tmux pane before assuming Slack is down.
- For a deeper host-side audit, run `bash scripts/healthcheck.sh` on the mini. It exercises the core operator commands (`git -C /win`, `docker ps`, `win deploy status`, `win doctor show`) and proves the scoped GitHub token can read `bigwinai/win` pull requests and Actions in addition to container/process health.
- The Bash hook's only direct Docker lifecycle authority is the two exact cloudflared sidecar restarts plus `cd /win && docker compose -p win-live|win-staging up|stop|rm ...`. Compose `up` requires `-d --no-build --no-recreate --no-deps --pull never` and an explicit known service. Those flags prevent build, pull, and recreation of an existing container, but Compose may still create a missing container from `/win`; that path requires operator disposition/live proof before activation. Other container/project names, Compose file overrides, direct `stop`/`rm`, and Compose `down`/`restart` remain denied.
- Prefer `win deploy beta|staging|cancel` over the older `win admin deploy *` relay whenever the task maps cleanly to the per-environment controller path.

## Notes discipline

- For non-trivial work, append to the existing note in `docs/implementation-notes/` instead of creating parallel history.
- This repo already has a good home for container/runtime decisions: `docs/implementation-notes/container-infrastructure.md`.
