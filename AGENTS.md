# slack-cc-ops agent notes

Start here for the fast path. `CLAUDE.md` is the full repo handbook; this file is the short operational contract for agents making changes or deploying the bot.

## What this repo controls

- This repo runs the `#win-ops` Slack bot on `ssh superpea@mac-mini`.
- The repo checkout on the mini is `~/dvl/win-ops`.
- The container is `slack-cc-ops` in the `docker compose` stack rooted at that checkout.
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
  - `docker exec slack-cc-ops sh -lc 'id && ls -ln /var/run/docker.sock && docker ps --format "{{.Names}}"'`

## Health and validation

- Healthy runtime signals:
  - `docker compose ps` shows `slack-cc-ops` as `Up` and `healthy`
  - `docker exec slack-cc-ops tail -40 /state/inbox/server.err` includes `slack channel: connected as`
  - `docker exec slack-cc-ops tmux capture-pane -pt slackcc | tail -40` shows Claude at an interactive prompt instead of a stuck startup screen
- The current image auto-confirms Claude's "Loading development channels" prompt during startup. If startup looks wedged, inspect `scripts/entrypoint.sh` and the tmux pane before assuming Slack is down.

## Notes discipline

- For non-trivial work, append to the existing note in `docs/implementation-notes/` instead of creating parallel history.
- This repo already has a good home for container/runtime decisions: `docs/implementation-notes/container-infrastructure.md`.
