#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/pretooluse-bash.sh"
PASSED=0
FAILED=0

run_case() {
  local expected="$1"
  local description="$2"
  local command="$3"
  local payload output rc

  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$command")"
  if output="$(printf '%s' "$payload" | bash "$HOOK" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$expected" == "allow" && "$rc" -eq 0 && "$output" == *'"continue": true'* ]]; then
    PASSED=$((PASSED + 1))
    printf 'ok - %s\n' "$description"
    return
  fi
  if [[ "$expected" == "deny" && "$rc" -eq 2 && "$output" == *'[hook] denied'* ]]; then
    PASSED=$((PASSED + 1))
    printf 'ok - %s\n' "$description"
    return
  fi

  FAILED=$((FAILED + 1))
  printf 'not ok - %s (expected=%s rc=%s output=%s)\n' "$description" "$expected" "$rc" "$output" >&2
}

run_case allow "staging tunnel sidecar restart" \
  "docker restart bigwinstaging-cloudflared"
run_case allow "beta tunnel sidecar restart" \
  "docker restart bigwinbeta-cloudflared"
run_case deny "unlisted sidecar restart" \
  "docker restart unrelated-cloudflared"
run_case deny "WIN application container restart" \
  "docker restart win-live-server-1"
run_case deny "extra restart target" \
  "docker restart bigwinbeta-cloudflared unrelated-cloudflared"

run_case allow "live compose up from trusted mount" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never server"
run_case allow "staging compose stop from trusted mount" \
  "cd /win && docker compose --project-name win-staging stop server"
run_case allow "live compose rm from trusted mount" \
  "cd /win && docker compose --project-name=win-live rm -f server"
run_case deny "compose mutation without trusted mount" \
  "docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never server"
run_case deny "compose mutation without project" \
  "cd /win && docker compose up -d --no-build --no-recreate --no-deps --pull never server"
run_case deny "compose mutation for unrelated project" \
  "cd /win && docker compose -p slops stop server"
run_case deny "compose file override" \
  "cd /win && docker compose -f /state/scratch/compose.yml -p win-live up -d --no-build --no-recreate --no-deps --pull never server"
run_case deny "compose restart remains outside self-heal set" \
  "cd /win && docker compose -p win-live restart server"
run_case deny "compose down remains outside self-heal set" \
  "cd /win && docker compose -p win-live down"
run_case deny "direct stop remains outside self-heal set" \
  "docker stop win-live-server-1"
run_case deny "direct rm remains outside self-heal set" \
  "docker rm win-live-server-1"
run_case allow "read-only compose status" \
  "docker compose ps"

run_case allow "read-only GitHub PR inspection" \
  "gh pr view 729 --repo bigwinai/win --json state"
run_case allow "read-only GitHub Actions inspection" \
  "gh run view 29110539622 --repo bigwinai/win"
run_case allow "GitHub auth status without token disclosure" \
  "gh auth status --hostname github.com"
run_case deny "GitHub PR write" \
  "gh pr merge 729 --repo bigwinai/win"
run_case deny "GitHub Actions mutation" \
  "gh run rerun 29110539622 --repo bigwinai/win"
run_case deny "raw GitHub API is not in the bot allowlist" \
  "gh api repos/bigwinai/win"
run_case deny "GitHub auth cannot print token" \
  "gh auth status --hostname github.com --show-token"
run_case deny "GitHub reads cannot target another repository" \
  "gh pr view 1 --repo another/repo"
run_case deny "GitHub reads require the pinned repository" \
  "gh pr view 729"
run_case deny "WIN GitHub wrapper cannot bypass direct policy" \
  "win gh pr merge 729 --repo bigwinai/win"

run_case deny "env cannot wrap Docker mutation" \
  "env docker restart unrelated-cloudflared"
run_case deny "xargs cannot wrap Docker mutation" \
  "xargs docker restart unrelated-cloudflared"
run_case deny "awk cannot wrap Docker mutation" \
  'awk BEGIN{system("docker restart unrelated-cloudflared")}'
run_case deny "raw Docker socket API is denied" \
  "curl --unix-socket /var/run/docker.sock -X DELETE http://localhost/containers/unrelated"
run_case deny "docker exec cannot mutate sibling containers" \
  "docker exec unrelated sh -c 'kill 1'"
run_case deny "docker cp cannot mutate sibling containers" \
  "docker cp /state/scratch/file unrelated:/tmp/file"
run_case deny "docker network mutation is denied" \
  "docker network rm unrelated"
run_case allow "docker network inspection remains available" \
  "docker network inspect win-live_default"

run_case deny "compose up cannot build" \
  "cd /win && docker compose -p win-live up -d --no-recreate --no-deps --pull never --build server"
run_case deny "compose up cannot pull" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull always server"
run_case deny "compose up cannot force recreation" \
  "cd /win && docker compose -p win-live up -d --no-build --no-deps --pull never --force-recreate server"
run_case deny "compose up cannot renew anonymous volumes" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never --renew-anon-volumes server"
run_case deny "compose up cannot use short anonymous-volume renewal" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never -V server"
run_case deny "compose up cannot remove orphans" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never --remove-orphans server"
run_case deny "compose up cannot scale" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never --scale server=2 server"
run_case deny "compose up requires an explicit service" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never"
run_case deny "compose up rejects an unknown service" \
  "cd /win && docker compose -p win-live up -d --no-build --no-recreate --no-deps --pull never attacker"
run_case deny "duplicate project override cannot retarget recovery" \
  "cd /win && docker compose -p win-live --project-name unrelated up -d --no-build --no-recreate --no-deps --pull never server"

run_case deny "read command cannot chain into Docker mutation" \
  "docker ps && docker restart unrelated-cloudflared"
run_case deny "allowed recovery cannot chain another command" \
  "docker restart bigwinbeta-cloudflared; docker restart unrelated-cloudflared"
run_case deny "allowed recovery cannot use command substitution" \
  'docker restart bigwinbeta-cloudflared$(printf x)'
run_case deny "allowed recovery cannot redirect output" \
  "docker restart bigwinbeta-cloudflared >/state/scratch/restart.log"
run_case deny "allowed GitHub read cannot chain a write" \
  "gh pr view 729 && gh pr merge 729"
run_case deny "compose volume destruction stays hard-denied" \
  "cd /win && docker compose -p win-live down -v"
run_case deny "Docker volume removal stays hard-denied" \
  "docker volume rm win-data"
run_case deny "dropdb stays hard-denied" \
  "dropdb win"

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
