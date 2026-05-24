---
spec: slack-cc-ops:container assignment and /Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md
status: shipped
created: 2026-05-23
last_updated: 2026-05-24
related: []
---

# Container Infrastructure

## Summary
This workstream owns the standalone Docker infrastructure for running the slack-cc-ops Claude Code session on the Mac mini. The implementation is based on Cam's `plex-mcp-server` Docker style while adding Claude Code, docker socket access, a persistent `CLAUDE_CONFIG_DIR`, a dedicated `/win` worktree mount, and bootstrap scripts for first-run setup. It now also carries the runtime hardening needed for current Claude builds and Docker Desktop on macOS: the container healthcheck proves real operator capability instead of only process presence, startup auto-confirms the development-channel prompt, `botuser` is explicitly added to group `0` so `docker` commands work against the mounted socket, and the container mounts the host-side git metadata paths that the `/win` worktree's `.git` file points at so the bot can resolve `origin/main` locally. The next obvious step is to keep deploy/runtime rules centralized in `AGENTS.md` and this note whenever the bot's Mac mini contract changes.

## Current open questions
- [x] ~~Should `scripts/bootstrap-mini.sh` support macOS `stat -f '%g'` as a fallback, or should it stay literal to the brief's Linux-style `stat -c '%g'` command for Docker socket group detection?~~ -> Support both. The script tries the requested `stat -c '%g'` first, then falls back to macOS `stat -f '%g'`, decided 2026-05-23.
- [x] ~~Is host-side Docker socket GID detection sufficient to make `docker` usable inside the container on the Mac mini?~~ -> No. On Docker Desktop for macOS the mounted socket can still appear as `root:root` inside the container, so the image must also keep `botuser` in group `0`, decided 2026-05-24.

## Sessions

### 2026-05-24 — session `20260524-6bdbf41-eq0` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** ad-hoc reliability audit for core `win-ops` command paths
**Files touched:** `scripts/container-healthcheck.sh`, `docker-compose.yml`, `scripts/healthcheck.sh`, `AGENTS.md`, `CLAUDE.md`, `docs/implementation-notes/README.md`, `docs/implementation-notes/container-infrastructure.md`

#### Context loaded
After the deploy recovery work, Cam asked for a pass over the commands and subcommands most relevant to the bot's real operator duties and whether a separate heartbeat/logging monitor was needed. I audited the live container on the mini and confirmed that the key command paths were currently working: `win whoami`, `win deploy status`, `win doctor show`, `git -C /win rev-parse origin/main`, `docker ps`, and the host-side `scripts/healthcheck.sh`.

#### Design decisions
- **Strengthen the existing Docker healthcheck instead of adding a new daemon:** The prior healthcheck only checked whether `bun server.ts` existed. That was too weak because the bot could look healthy while lacking Docker access, git worktree access, or WIN auth. I added an in-container `scripts/container-healthcheck.sh` that proves those capabilities directly.
- **Make the host audit exercise operator commands explicitly:** `scripts/healthcheck.sh` already covered broad runtime status, but it did not clearly prove that the command paths Cam cares about still work. I added a dedicated `core operator commands` section that checks `git -C /win`, `docker ps`, `win deploy status`, and `win doctor show`.
- **Avoid a standalone heartbeat monitor for now:** With the stronger in-container healthcheck, Docker already marks the bot unhealthy when it loses real operator capability. That gives a low-friction reliability layer without yet adding a separate heartbeat daemon or notification loop.

#### Deviations from spec
- **No extra monitor service yet:** The user raised heartbeat monitoring as a possibility, but the minimal reliable move was to promote capability checks into the existing healthcheck path first. A separate monitor would add more moving parts before we know we need them.

#### Tradeoffs considered
- **Process health vs. capability health:** Process-only checks are cheap and quiet, but they miss the exact failures that matter here: broken `/win` metadata mounts, expired WIN auth, missing Docker socket access, and Slack-connect regressions. Capability checks are slightly heavier, but they map to the actual operator contract.
- **Healthcheck vs. external notification loop:** A cron/launchd/heartbeat notifier could catch issues sooner, but it also increases complexity and alert fatigue. Strengthening the healthcheck keeps the system simpler while still making failures visible through `docker compose ps`, `scripts/healthcheck.sh`, and any future restart policy or alerting built on Docker health.

#### Open questions
- [ ] If the bot still exhibits long-idle or multi-message degradation after this stronger healthcheck has been live for a while, should we add a failure-only notifier that runs `scripts/healthcheck.sh` periodically and pages only on red status?

#### Footguns and gotchas
- The stronger container healthcheck relies on live WIN auth and host git metadata mounts. If either of those is intentionally unavailable during maintenance, Docker may temporarily mark the bot unhealthy even if the Claude process itself is still up.
- `scripts/container-healthcheck.sh` checks `win whoami` for `oauth-active`. If future auth behavior intentionally changes to a different healthy state, this script will need to be updated in lockstep.

#### What shipped this session
- Added `scripts/container-healthcheck.sh` as an in-container capability healthcheck.
- Updated Docker health status to use that capability healthcheck instead of a simple `pgrep`.
- Expanded `scripts/healthcheck.sh` to exercise the core operator command paths explicitly.
- Documented the stronger health model in `AGENTS.md` and `CLAUDE.md`.

#### What's next
- Redeploy `slack-cc-ops`, verify the container remains healthy under the stronger healthcheck, and rerun the host-side healthcheck on the mini. If that stays green across a few restart/idle cycles, prefer this over adding a dedicated heartbeat monitor.

### 2026-05-24 — session `20260524-6660dc8-s2v` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** ad-hoc operator follow-up about answering `HEAD of main` vs deployed SHAs
**Files touched:** `docker-compose.yml`, `AGENTS.md`, `CLAUDE.md`, `docs/implementation-notes/README.md`, `docs/implementation-notes/container-infrastructure.md`

#### Context loaded
After the bot redeploy and beta recovery, Cam asked why the bot still could not answer "what commit is on HEAD of main and what's deployed on beta and staging?" I inspected `/win` inside the running container and found that the files were mounted, but `git -C /win` failed because `/win/.git` points to an absolute host path under `/Users/superpea/dvl/win/.git/worktrees/win`, which did not exist inside the container.

#### Design decisions
- **Mount host-style git metadata paths verbatim:** Rather than replacing the worktree with a separate clone, I added read-only bind mounts for the exact absolute paths git expects: `./win -> /Users/superpea/dvl/win-ops/win` and `/Users/superpea/dvl/win -> /Users/superpea/dvl/win`. This makes the existing `/win` worktree usable in-container with the least disruption.
- **Document the worktree trap explicitly:** The failure looked like a broken git checkout or missing `GH_TOKEN`, but the real issue was missing worktree metadata mounts. I added this to `AGENTS.md` and `CLAUDE.md` so future agents do not misdiagnose it.

#### Deviations from spec
- **Host-specific absolute path mounts:** The compose file now encodes the Mac mini's concrete host paths because this repo targets one known deployment. A more portable design would avoid host-specific absolute paths, but portability matters less here than making the live bot answer core ops questions reliably.

#### Tradeoffs considered
- **Worktree metadata mounts vs. standalone clone:** Considered replacing `./win` with a plain clone to avoid absolute-path gitdir pointers. I kept the worktree because it already exists in the bootstrap flow, shares objects efficiently with the host repo, and only needed two additional read-only mounts to become usable inside the container.

#### Open questions
- None.

#### Footguns and gotchas
- Mounting `./win` alone is not enough for git commands inside the container when the directory is a worktree. The companion metadata mounts are part of the contract now.
- If the host-side source repo path ever moves away from `/Users/superpea/dvl/win`, the container mounts and the worktree pointer must be updated together.

#### What shipped this session
- Added the host-side worktree metadata mounts needed for `git -C /win` to resolve `origin/main` inside the container.
- Documented the `/win` worktree metadata requirement in both `AGENTS.md` and `CLAUDE.md`.

#### What's next
- Rebuild/redeploy `slack-cc-ops`, then verify that `git -C /win rev-parse origin/main` works inside the container and that the bot can answer the `HEAD of main / deployed beta / deployed staging` question directly.

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
