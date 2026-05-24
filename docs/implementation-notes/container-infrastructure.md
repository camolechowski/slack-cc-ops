---
spec: slack-cc-ops:container assignment and /Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md
status: shipped
created: 2026-05-23
last_updated: 2026-05-23
related: []
---

# Container Infrastructure

## Summary
This workstream owns the standalone Docker infrastructure for running the slack-cc-ops Claude Code session on the Mac mini. The implementation is based on Cam's `plex-mcp-server` Docker style while adding Claude Code, docker socket access, a persistent `CLAUDE_CONFIG_DIR`, a dedicated `/win` worktree mount, and bootstrap scripts for first-run setup. The initial Dockerfile, compose file, environment template, ignore rules, entrypoint, and bootstrap script are now in place; the next layer is to pair them with the settings, hooks, prompts, and plugin changes owned by the adjacent panes.

## Current open questions
- [x] ~~Should `scripts/bootstrap-mini.sh` support macOS `stat -f '%g'` as a fallback, or should it stay literal to the brief's Linux-style `stat -c '%g'` command for Docker socket group detection?~~ -> Support both. The script tries the requested `stat -c '%g'` first, then falls back to macOS `stat -f '%g'`, decided 2026-05-23.

## Sessions

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
