#!/usr/bin/env bash
# End-to-end reliability check for the slack-cc-ops bot + win-live stack.
# Returns 0 if everything's green, non-zero with a clear error if anything's
# broken. Each check is independent; we print all results before exiting so
# you can see the complete picture in one shot.
#
# Run on the mini directly, OR from your laptop:
#   ssh superpea@mac-mini 'bash ~/dvl/win-ops/scripts/healthcheck.sh'
#
# Exit codes: 0 all green, 1 one or more failures, 2 catastrophic (mini unreachable)

set -uo pipefail

PROJECT_DIR="${SLACK_CC_OPS_DIR:-$HOME/dvl/win-ops}"
CONTAINER="${SLOPS_CONTAINER:-slops}"
FAILURES=0
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

ok() { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
fail() { printf "  ${RED}✗${RESET} %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
warn() { printf "  ${YELLOW}⚠${RESET} %s\n" "$1"; }
section() { printf "\n${YELLOW}== %s ==${RESET}\n" "$1"; }

# -----------------------------------------------------------------------------
section "1. bot container"

CONTAINER_STATE="$(docker ps --filter "name=$CONTAINER" --format '{{.Status}}' 2>/dev/null | head -1)"
if [ -z "$CONTAINER_STATE" ]; then
  fail "$CONTAINER container is NOT running"
else
  ok "$CONTAINER: $CONTAINER_STATE"
fi

# -----------------------------------------------------------------------------
section "2. bot internals (only if container is up)"

if [ -n "$CONTAINER_STATE" ]; then
  # claude process alive
  if docker exec "$CONTAINER" pgrep -f "^claude " >/dev/null 2>&1; then
    ok "claude REPL process is running"
  else
    fail "claude REPL process is NOT running"
  fi

  # bun server.ts (channel MCP) alive
  if docker exec "$CONTAINER" pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
    ok "bun server.ts (channel MCP) is running"
  else
    fail "bun server.ts (channel MCP) is NOT running — bot can't receive Slack events"
  fi

  # Bolt reports connected
  BOLT_LAST="$(docker exec "$CONTAINER" tail -50 /state/inbox/server.err 2>/dev/null | grep "slack channel:" | tail -1)"
  if echo "$BOLT_LAST" | grep -q "connected as"; then
    ok "Bolt last status: $(echo "$BOLT_LAST" | sed -E 's/^[^a-zA-Z]*//')"
  elif echo "$BOLT_LAST" | grep -q "shutting down"; then
    fail "Bolt last status: SHUT DOWN — $BOLT_LAST"
  elif [ -z "$BOLT_LAST" ]; then
    warn "no slack channel: log lines in server.err yet"
  else
    warn "Bolt last status: $BOLT_LAST"
  fi

  if docker exec "$CONTAINER" bash /app/scripts/container-healthcheck.sh >/dev/null 2>&1; then
    ok "container capability healthcheck passed"
  else
    fail "container capability healthcheck failed (docker/git/auth/slack capability regression)"
  fi

fi

# -----------------------------------------------------------------------------
section "3. core operator commands"

if [ -n "$CONTAINER_STATE" ]; then
  MAIN_SHA="$(docker exec "$CONTAINER" sh -lc 'git -C /win rev-parse --short origin/main' 2>/dev/null || true)"
  if [ -n "$MAIN_SHA" ]; then
    ok "git -C /win rev-parse origin/main: $MAIN_SHA"
  else
    fail "git -C /win rev-parse origin/main failed"
  fi

  if docker exec "$CONTAINER" sh -lc 'docker ps >/dev/null' 2>/dev/null; then
    ok "docker ps works inside the bot container"
  else
    fail "docker ps failed inside the bot container"
  fi

  DEPLOY_STATUS="$(docker exec "$CONTAINER" sh -lc 'win deploy status --json' 2>/dev/null || true)"
  if echo "$DEPLOY_STATUS" | grep -q '"name"[[:space:]]*:[[:space:]]*"beta"' && \
     echo "$DEPLOY_STATUS" | grep -q '"name"[[:space:]]*:[[:space:]]*"staging"'; then
    ok "win deploy status returned beta + staging entries"
  else
    fail "win deploy status did not return expected beta/staging entries"
  fi

  DOCTOR_SHOW="$(docker exec "$CONTAINER" sh -lc 'win doctor show --json' 2>/dev/null || true)"
  if echo "$DOCTOR_SHOW" | grep -q '"api-health"' && echo "$DOCTOR_SHOW" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    ok "win doctor show returned healthy diagnostics"
  else
    fail "win doctor show did not return healthy diagnostics"
  fi

  if docker exec "$CONTAINER" sh -lc 'test -n "${GH_TOKEN:-}" && command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1 && gh api --method GET repos/bigwinai/win/pulls -f state=open -f per_page=1 >/dev/null && gh api --method GET repos/bigwinai/win/actions/runs -f per_page=1 >/dev/null' 2>/dev/null; then
    ok "GH_TOKEN can read bigwinai/win pull requests and Actions"
  else
    fail "GH_TOKEN read contract failed (auth, repository, pull-request, or Actions access)"
  fi
fi

# -----------------------------------------------------------------------------
section "4. WIN auth (Scott)"

if [ -n "$CONTAINER_STATE" ]; then
  WHOAMI="$(docker exec "$CONTAINER" sh -c 'cd /win && win whoami' 2>/dev/null)"
  AUTH_STATE="$(echo "$WHOAMI" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authState","?"))' 2>/dev/null || echo unknown)"
  AUTH_EMAIL="$(echo "$WHOAMI" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("email","?"))' 2>/dev/null || echo unknown)"
  AUTH_REFRESHABLE="$(echo "$WHOAMI" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("refreshable","?"))' 2>/dev/null || echo unknown)"
  case "$AUTH_STATE" in
    oauth-active)
      ok "win whoami: $AUTH_EMAIL ($AUTH_STATE)"
      ;;
    oauth-expired)
      if [ "$AUTH_REFRESHABLE" = "True" ]; then
        warn "win whoami: $AUTH_EMAIL ($AUTH_STATE) — refresh on next call"
      else
        fail "win whoami: $AUTH_EMAIL ($AUTH_STATE) — refresh NOT possible, needs re-login"
      fi
      ;;
    *)
      fail "win whoami: $AUTH_STATE ($AUTH_EMAIL) — no auth"
      ;;
  esac
fi

# -----------------------------------------------------------------------------
section "5. Slack identity"

if [ -n "$CONTAINER_STATE" ]; then
  SLACK_AUTH="$(docker exec "$CONTAINER" sh -c 'curl -sS --max-time 5 -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test' 2>/dev/null)"
  if echo "$SLACK_AUTH" | grep -q '"ok":true'; then
    BOT_USER="$(echo "$SLACK_AUTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user","?"))')"
    TEAM="$(echo "$SLACK_AUTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("team","?"))')"
    ok "Slack auth: $BOT_USER @ $TEAM"
  else
    fail "Slack auth.test failed: $(echo "$SLACK_AUTH" | head -c 200)"
  fi
fi

# -----------------------------------------------------------------------------
section "6. win-live runtime (beta)"

# Public beta endpoint
BETA_HEALTH="$(curl -sS --max-time 5 https://bigwinbeta.olelabs.xyz/api/health 2>/dev/null)"
if echo "$BETA_HEALTH" | grep -q '"ok":true'; then
  DB="$(echo "$BETA_HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("db","?"))')"
  ok "https://bigwinbeta.olelabs.xyz/api/health: ok (db=$DB)"
else
  fail "https://bigwinbeta.olelabs.xyz/api/health: $(echo "$BETA_HEALTH" | head -c 200)"
fi

# Win-live containers
for svc in postgres redis minio server kernel daemon proxy dashboard; do
  STATUS="$(docker ps --filter name=win-live-${svc} --format '{{.Status}}' 2>/dev/null | head -1)"
  if [ -z "$STATUS" ]; then
    fail "win-live-${svc}-1: NOT running"
  elif echo "$STATUS" | grep -qi unhealthy; then
    warn "win-live-${svc}-1: $STATUS"
  else
    ok "win-live-${svc}-1: $STATUS"
  fi
done

# -----------------------------------------------------------------------------
section "7. deploy controller"

CTL_PID="$(lsof -nP -iTCP:9475 2>/dev/null | awk 'NR==2{print $2}')"
if [ -n "$CTL_PID" ]; then
  ok "deploy controller listening on :9475 (PID $CTL_PID)"
  # Authed probe (uses controller token from .env)
  TOKEN="$(grep '^WIN_DEPLOY_CONTROLLER_TOKEN=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2-)"
  if [ -n "$TOKEN" ]; then
    PROBE="$(curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" http://localhost:9475/status 2>/dev/null)"
    if echo "$PROBE" | grep -q '"ok":true'; then
      SHA_SHORT="$(echo "$PROBE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sha","?")[:8])' 2>/dev/null)"
      QUIESCENT="$(echo "$PROBE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("quiescent","?"))' 2>/dev/null)"
      ACTIVE="$(echo "$PROBE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("activeJobs","?"))' 2>/dev/null)"
      ok "controller /status: sha=$SHA_SHORT quiescent=$QUIESCENT activeJobs=$ACTIVE"
    else
      warn "controller /status got unexpected response: $(echo "$PROBE" | head -c 200)"
    fi
  fi
else
  fail "deploy controller NOT listening on :9475"
fi

# -----------------------------------------------------------------------------
section "summary"

if [ "$FAILURES" -eq 0 ]; then
  printf "${GREEN}all green${RESET}\n"
  exit 0
else
  printf "${RED}%d failure(s)${RESET}\n" "$FAILURES"
  exit 1
fi
