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

CONTAINER_STATE="$(docker ps --filter name=slack-cc-ops --format '{{.Status}}' 2>/dev/null | head -1)"
if [ -z "$CONTAINER_STATE" ]; then
  fail "slack-cc-ops container is NOT running"
else
  ok "slack-cc-ops: $CONTAINER_STATE"
fi

# -----------------------------------------------------------------------------
section "2. bot internals (only if container is up)"

if [ -n "$CONTAINER_STATE" ]; then
  # claude process alive
  if docker exec slack-cc-ops pgrep -f "^claude " >/dev/null 2>&1; then
    ok "claude REPL process is running"
  else
    fail "claude REPL process is NOT running"
  fi

  # bun server.ts (channel MCP) alive
  if docker exec slack-cc-ops pgrep -f "bun.*server.ts" >/dev/null 2>&1; then
    ok "bun server.ts (channel MCP) is running"
  else
    fail "bun server.ts (channel MCP) is NOT running — bot can't receive Slack events"
  fi

  # Bolt reports connected
  BOLT_LAST="$(docker exec slack-cc-ops tail -50 /state/inbox/server.err 2>/dev/null | grep "slack channel:" | tail -1)"
  if echo "$BOLT_LAST" | grep -q "connected as"; then
    ok "Bolt last status: $(echo "$BOLT_LAST" | sed -E 's/^[^a-zA-Z]*//')"
  elif echo "$BOLT_LAST" | grep -q "shutting down"; then
    fail "Bolt last status: SHUT DOWN — $BOLT_LAST"
  elif [ -z "$BOLT_LAST" ]; then
    warn "no slack channel: log lines in server.err yet"
  else
    warn "Bolt last status: $BOLT_LAST"
  fi

  # health socket file exists
  if docker exec slack-cc-ops test -S /state/inbox/health.sock 2>/dev/null; then
    ok "health socket /state/inbox/health.sock exists"
  else
    fail "health socket /state/inbox/health.sock is MISSING"
  fi
fi

# -----------------------------------------------------------------------------
section "3. WIN auth (Scott)"

if [ -n "$CONTAINER_STATE" ]; then
  WHOAMI="$(docker exec slack-cc-ops sh -c 'cd /win && win whoami' 2>/dev/null)"
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
section "4. Slack identity"

if [ -n "$CONTAINER_STATE" ]; then
  SLACK_AUTH="$(docker exec slack-cc-ops sh -c 'curl -sS --max-time 5 -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test' 2>/dev/null)"
  if echo "$SLACK_AUTH" | grep -q '"ok":true'; then
    BOT_USER="$(echo "$SLACK_AUTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user","?"))')"
    TEAM="$(echo "$SLACK_AUTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("team","?"))')"
    ok "Slack auth: $BOT_USER @ $TEAM"
  else
    fail "Slack auth.test failed: $(echo "$SLACK_AUTH" | head -c 200)"
  fi
fi

# -----------------------------------------------------------------------------
section "5. win-live runtime (beta)"

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
section "6. deploy controller"

CTL_PID="$(lsof -nP -iTCP:9475 2>/dev/null | awk 'NR==2{print $2}')"
if [ -n "$CTL_PID" ]; then
  ok "deploy controller listening on :9475 (PID $CTL_PID)"
  # Authed probe (uses controller token from .env)
  TOKEN="$(grep '^WIN_DEPLOY_CONTROLLER_TOKEN=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d= -f2-)"
  if [ -n "$TOKEN" ]; then
    PROBE="$(curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" http://localhost:9475/api/deploy/runtime/status 2>/dev/null)"
    if echo "$PROBE" | grep -q "drain\|mode"; then
      ok "controller /api/deploy/runtime/status responding correctly"
    else
      warn "controller probe got unexpected response: $(echo "$PROBE" | head -c 200)"
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
