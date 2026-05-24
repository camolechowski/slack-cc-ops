---
spec: slack-cc-ops:container assignment and /Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md
status: shipped
created: 2026-05-23
last_updated: 2026-05-24
related: []
---

# Container Infrastructure

## Summary
This workstream owns the standalone Docker infrastructure for running the slack-cc-ops Claude Code session on the Mac mini. The implementation is based on Cam's `plex-mcp-server` Docker style while adding Claude Code, docker socket access, a persistent `CLAUDE_CONFIG_DIR`, a dedicated `/win` worktree mount, and bootstrap scripts for first-run setup. It now also carries the runtime hardening needed for current Claude builds and Docker Desktop on macOS: the compose healthcheck tracks `bun server.ts`, startup auto-confirms the development-channel prompt, and `botuser` is explicitly added to group `0` so `docker` commands work against the mounted socket. The next obvious step is to keep deploy/runtime rules centralized in `AGENTS.md` and this note whenever the bot's Mac mini contract changes.

## Current open questions
- [x] ~~Should `scripts/bootstrap-mini.sh` support macOS `stat -f '%g'` as a fallback, or should it stay literal to the brief's Linux-style `stat -c '%g'` command for Docker socket group detection?~~ -> Support both. The script tries the requested `stat -c '%g'` first, then falls back to macOS `stat -f '%g'`, decided 2026-05-23.
- [x] ~~Is host-side Docker socket GID detection sufficient to make `docker` usable inside the container on the Mac mini?~~ -> No. On Docker Desktop for macOS the mounted socket can still appear as `root:root` inside the container, so the image must also keep `botuser` in group `0`, decided 2026-05-24.

## Sessions

### 2026-05-24 — session `20260524-7c762c6-rca` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** ad-hoc runtime incident from `#win-ops`; see Summary above
**Files touched:** `Dockerfile`, `docker-compose.yml`, `scripts/entrypoint.sh`, `scripts/redeploy.sh`, `AGENTS.md`, `CLAUDE.md`, `docs/implementation-notes/README.md`, `docs/implementation-notes/container-infrastructure.md`

#### Context loaded
I read `CLAUDE.md`, the existing container-infrastructure note, and the live repo state on `superpea@mac-mini`. The running container was healthy enough to answer Slack, but the bot had just failed a WIN deploy-debug task because `docker ps` inside the container returned `permission denied` against `/var/run/docker.sock`.

#### Design decisions
- **Always add `botuser` to group `0`:** The existing build-time `HOST_DOCKER_GID` wiring was not enough on the Mac mini because the mounted socket presented inside the container as `root:root` with mode `660`. I kept the detected host group logic for Linux-ish cases, but also added `botuser` to `root` so Docker Desktop's root-owned socket remains usable.
- **Promote local runtime fixes into committed repo state:** Both the laptop checkout and the mini checkout had the same uncommitted changes for the compose healthcheck and the startup auto-confirm loop. I treated those as part of the deployability fix so "latest" stops living only in a dirty working tree.
- **Add a short operational `AGENTS.md`:** `CLAUDE.md` had the full architecture, but the current incident showed we also needed a terse file that future agents can scan for the deploy contract, the dirty-worktree trap, and the Docker socket rule before touching the mini.

#### Deviations from spec
- **Added a repo-local `AGENTS.md`:** No explicit spec required it, but the live debugging failure came from repo-specific operational assumptions that were only implicit in chat and a long handbook. The new file is intentionally short and points back to `CLAUDE.md` for detail.

#### Tradeoffs considered
- **Docker access model:** Considered switching the whole container to run as `root`, but kept the service as `botuser` and only granted root-group membership. Running as root would also fix socket access, but it would widen the default blast radius more than necessary given the bot already has privileged capabilities through the mounted Docker socket.
- **Redeploy behavior on dirty trees:** Considered teaching `scripts/redeploy.sh` to stash or overwrite tracked files automatically. I rejected that because it would hide exactly the kind of state drift that stranded these fixes. The script now fails fast with a clear message instead.

#### Open questions
- [ ] Should `scripts/bootstrap-mini.sh` also print an explicit note that macOS Docker Desktop may still require group `0`, so first-run operators know why the Dockerfile carries both group memberships?

#### Footguns and gotchas
- A healthy `docker compose ps` status for `slack-cc-ops` does not prove the bot can reach sibling containers. You must validate `docker ps` from inside the container after any socket-permission change.
- On this repo, "latest running" can fail for two separate reasons: the image is old, or the mini checkout is dirty and blocks `git pull --ff-only`. Check both before assuming Slack or Claude is the culprit.
- The bot can look functionally alive in Slack while still lacking the Docker access it needs for WIN deploy/debug tasks.

#### What shipped this session
- Added a Dockerfile hardening step that keeps `botuser` in group `0` in addition to the detected host Docker group.
- Promoted the compose healthcheck fix and Claude development-channel auto-confirm loop into intended repo state instead of leaving them as dirty local changes.
- Added `AGENTS.md` as the fast operational contract and linked it from `CLAUDE.md`.
- Hardened `scripts/redeploy.sh` to fail fast on dirty tracked files with an actionable message.

#### What's next
- Rebuild and redeploy the bot on `superpea@mac-mini`, then validate that `docker ps` works from inside the container and that Slack reconnects cleanly after the image update.

### 2026-05-23 — session `20260523-nogit-p1a` (agent: codex)
**Branch / working tree:** `not inspected per coordinator instruction: Do NOT touch git`
**Spec ref:** slack-cc-ops:container assignment; `/Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md`
**Files touched:** `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, `scripts/entrypoint.sh`, `scripts/bootstrap-mini.sh`, `.gitignore`, `docs/implementation-notes/README.md`, `docs/implementation-notes/container-infrastructure.md`

#### Context loaded
No prior `docs/implementation-notes/` folder existed, so this note and the index were scaffolded before implementation. I read Cam's reference Dockerfile and compose file from `/Users/cameronolechowski/code/play/plex-mcp-server/` plus the container plan in `/Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md`.

#### Design decisions
- **Writable symlink target for `win`:** The entrypoint is required to symlink `/opt/win-cli/bin/win` into `/usr/local/bin/win`, but the runtime user is non-root. The Dockerfile will make `/usr/local/bin` writable by `botuser` so that the required entrypoint behavior works without running the service as root.
- **Cross-platform docker socket GID detection:** `scripts/bootstrap-mini.sh` tries the brief's `stat -c '%g' /var/run/docker.sock` first, then tries macOS `stat -f '%g' /var/run/docker.sock`, then falls back to `999`. This keeps the Mac mini path working without weakening the requested Linux-style override path.

#### Deviations from spec
- **Added macOS `stat` fallback:** The brief specifically named `stat -c '%g'`; because the target host is a Mac mini, the script also supports `stat -f '%g'`. This is additive and only runs if the requested command is unavailable.

#### Tradeoffs considered
- **Docker socket group handling:** The assignment asks for a build-time `DOCKER_GID` and a `hostdocker` group. I am preserving that even though Docker Desktop for Mac may not enforce Linux group ownership the same way as a native Linux host, because it is harmless and keeps the image portable.

#### Open questions
- None.

#### Footguns and gotchas
- `/app/settings.json` and `/app/system-prompts/win-ops.md` are owned by another pane. This layer can reference them in the entrypoint but must not create or edit them.
- The docker socket mount intentionally gives the container host-level Docker power. The security model depends on the Slack gate, Claude settings, and Bash hook from the adjacent panes.
- The Dockerfile changes ownership of `/usr/local/bin` so the non-root entrypoint can refresh `/usr/local/bin/win` when the `/opt/win-cli` bind mount is present.

#### What shipped this session
- Added `Dockerfile` using `oven/bun:1-alpine`, `dumb-init`, production Bun install, Claude Code global install, `hostdocker` group membership, non-root `botuser`, persistent Claude config env, and socket-file healthcheck.
- Added `docker-compose.yml` for the standalone `slack-cc-ops` service with no ports, `.env` loading, state/worktree/docker-socket/win-cli mounts, and matching healthcheck.
- Added `.dockerignore`, `.env.example`, executable `scripts/entrypoint.sh`, executable `scripts/bootstrap-mini.sh`, and appended missing ignore rules to `.gitignore`.
- Verified both shell scripts with `bash -n` and confirmed executable bits.

#### What's next
- Adjacent panes need to supply `settings.json`, `system-prompts/win-ops.md`, hooks, and plugin changes. Once all panes land, build the image on the Mac mini, run `scripts/bootstrap-mini.sh`, perform `docker exec -it slack-cc-ops claude login`, restart the service, and verify the health socket plus Slack Socket Mode connection.
