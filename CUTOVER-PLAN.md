# slops Cutover Plan

Coordinator: Cam. Expected downtime: ~1 minute (compose down → up).
This plan covers switching the live Mac Mini container from `slack-cc-ops` (project `win-ops`) to `slops` (project `slops`).

---

## Prerequisites

- Branch `slops-rename-and-hardening` is merged to `master` in `camolechowski/slack-cc-ops`.
- The new image has been validated with the smoke test on the branch (see PR).
- No active slops jobs are in flight (the bot does not queue jobs internally, but verify no pending tool approvals are awaiting a reply in `#win-ops`).

---

## Step 1 — Pull latest master on the mini

```bash
ssh superpea@mac-mini
cd ~/dvl/win-ops
git fetch origin
git checkout master
git pull --ff-only origin master
```

---

## Step 2 — Stop the old container and compose project

The old project name is `win-ops`, service `slack-cc-ops`. Bring it down without `-v` (keeps volumes):

```bash
cd ~/dvl/win-ops
docker compose --project-name win-ops down
```

If the live container was started without an explicit project name (defaults to directory name `win-ops`), this is equivalent to:

```bash
docker compose down
```

Verify it stopped:

```bash
docker ps | grep slack-cc-ops   # expect no output
```

---

## Step 3 (optional) — Rename the directory to slops

This is entirely optional and purely cosmetic. If you want to rename:

```bash
mv ~/dvl/win-ops ~/dvl/slops
cd ~/dvl/slops
```

If you rename, update:
- All SSH shortcut aliases or scripts referencing `~/dvl/win-ops`
- `SLOPS_DIR` env override in any shell profiles (previously `SLACK_CC_OPS_DIR`)
- The win worktree paths if they're absolute (the `./win` bind-mount is relative so it auto-follows)

If you skip the rename, `~/dvl/win-ops` stays as-is and everything works — project name, container name, and image name are controlled by `docker-compose.yml`, not the directory.

---

## Step 4 (optional) — Rename the state directory

The bind-mount path `./.win-ops:/state` is intentionally preserved in this branch to keep live state (credentials, channel config, thread map, plugin.lock) intact without a migration step.

If you later want to rename it to `.slops` for clarity:

```bash
cd ~/dvl/win-ops   # or ~/dvl/slops if you renamed
mv .win-ops .slops
```

Then edit `docker-compose.yml` volume line:

```yaml
      - ./.slops:/state
```

Rebuild and restart — credentials and channel state will be where the container expects them. Verify `docker exec slops ls /state/claude-config/.credentials.json` before declaring success.

**Do not do this at the same time as the directory rename — one change at a time.**

---

## Step 5 — Start the new slops container

```bash
cd ~/dvl/win-ops   # or ~/dvl/slops
HOST_DOCKER_GID="$(stat -f '%g' /var/run/docker.sock 2>/dev/null || echo 999)"
export HOST_DOCKER_GID
docker compose up -d --build
```

Or use the wrapper:

```bash
bash scripts/redeploy.sh
```

(redeploy.sh now targets service `slops`, so `git pull` will run first — fine on a clean tree post-merge.)

---

## Step 6 — Healthcheck verify

```bash
docker compose ps          # expect: slops   Up   (healthy)
docker exec slops bash /app/scripts/container-healthcheck.sh
docker exec slops tail -20 /state/inbox/server.err   # expect "slack channel: connected as ..."
docker exec slops tmux capture-pane -pt slops | tail -20   # expect Claude at interactive prompt
```

---

## Step 7 — Slack reconnect check

Post a test message in `#win-ops`:

```
@winops status check — slops cutover complete?
```

Expect a reply within 10–15 seconds. If no reply within 30 seconds:

```bash
docker exec slops tmux capture-pane -pt slops | tail -40   # look for stuck prompt
bash scripts/logs.sh --raw | head -80                       # look for Bolt errors
```

---

## Step 8 — Cleanup (post-verification)

Remove the old `slack-cc-ops:latest` image to free space:

```bash
docker image rm slack-cc-ops:latest 2>/dev/null || true
```

---

## Rollback

If the new container fails to start or Slack does not reconnect within 2 minutes:

```bash
cd ~/dvl/win-ops
docker compose down
docker compose --project-name win-ops up -d --build   # force old project name
```

Or restore from the old image if it's still cached:

```bash
docker run -d --name slack-cc-ops \
  --env-file .env \
  -v "$(pwd)/.win-ops:/state" \
  -v "$(pwd)/win:/win:ro" \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  --restart unless-stopped \
  slack-cc-ops:latest
```

---

## Follow-up items (for Cam — not part of this PR)

1. **GitHub repo rename**: `camolechowski/slack-cc-ops` → `camolechowski/slops` via GitHub web UI (Settings → Rename). After rename, update the remote on the mini:
   ```bash
   git -C ~/dvl/win-ops remote set-url origin git@github.com:camolechowski/slops.git
   ```

2. **Directory rename**: `~/dvl/win-ops` → `~/dvl/slops` (Step 3 above). Low priority — works fine as-is.

3. **State dir rename**: `.win-ops` → `.slops` + volume mount update (Step 4 above). Low priority — state survives either way.

4. **SLOPS_DIR env** (optional): set in `~/.zshrc` on the mini so operator scripts work from any directory:
   ```bash
   export SLOPS_DIR="$HOME/dvl/win-ops"   # update to ~/dvl/slops if directory renamed
   ```

5. **Worktree branch rename**: `slack-cc-ops-bot` branch in the win repo could be renamed to `slops-bot`. Low priority — works as-is.
