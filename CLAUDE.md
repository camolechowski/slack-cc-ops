# slack-cc-ops Notes

## What this is

This is a fork of retrodigio's Slack channel plugin, customized for Cam + dad's olelabs workspace and the BigWin/win ops use case.

## Layout

- `server.ts` is the root-level MCP server and Slack Bolt receiver.
- `gate.ts` implements allowlist and channel policy enforcement.
- `skills/access` contains the access management skill.
- `skills/threads` contains the Slack thread to Claude agent dispatcher.
- `skills/configure` contains the Slack token configuration skill.
- `Dockerfile` and `docker-compose.yml` define the container hosting layer.
- `hooks/pretooluse-bash.sh` is the only tool gate in v1.
- `system-prompts/win-ops.md` is the bot's principal prompt.
- `scripts/entrypoint.sh` and `scripts/bootstrap-mini.sh` handle container startup and Mac mini bootstrap.

## State

`state/` is gitignored and bind-mounted into the container at `/state`.

- `state/claude-config/` is the `CLAUDE_CONFIG_DIR` target. `.credentials.json` lives here after `claude login`.
- `state/access.json` is the Slack allowlist.
- `state/routes.json` maps Slack channels to working directories.
- `state/inbox/` stores hook logs and the healthcheck socket.

## Bootstrap

Run `scripts/bootstrap-mini.sh` on the Mac mini, then run:

```bash
docker exec -it slack-cc-ops claude login
docker compose restart slack-cc-ops
```

## Upstream

Use this remote when pulling future upstream updates:

```bash
git remote add upstream https://github.com/retrodigio/claude-channel-slack
```

## Don't touch

Keep the diff against upstream small. Do not touch `server.ts`, `gate.ts`, `gate.test.ts`, `ACCESS.md`, `LICENSE`, or `routes.example.json` unless intentionally diverging.

## Plan doc

Canonical plan: `/Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md`
