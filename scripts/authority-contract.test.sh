#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_contains() {
  local description="$1"
  local pattern="$2"
  local file="$3"
  if grep -Fq -- "$pattern" "$ROOT/$file"; then
    pass "$description"
  else
    fail "$description"
  fi
}

if [[ "$(grep -c '^GH_TOKEN=$' "$ROOT/.env.example")" -eq 1 ]]; then
  pass "environment contract declares one blank GH_TOKEN"
else
  fail "environment contract must declare exactly one blank GH_TOKEN"
fi

if git -C "$ROOT" grep -n -E 'GH_TOKEN=.+$' -- . ':(exclude)scripts/authority-contract.test.sh' >/dev/null 2>&1; then
  fail "tracked files contain a GH_TOKEN value"
else
  pass "tracked files contain no GH_TOKEN value"
fi

if git -C "$ROOT" grep -n -E '(github_pat_|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9]' -- . ':(exclude)scripts/authority-contract.test.sh' >/dev/null 2>&1; then
  fail "tracked files contain a GitHub token-shaped value"
else
  pass "tracked files contain no GitHub token-shaped value"
fi

assert_contains "image installs the GitHub CLI" "github-cli" "Dockerfile"
assert_contains "container health requires the GitHub CLI" 'command -v gh' "scripts/container-healthcheck.sh"
assert_contains "container health requires the token name" '[[ -n "${GH_TOKEN:-}" ]]' "scripts/container-healthcheck.sh"
assert_contains "operator audit checks GitHub auth" 'gh auth status --hostname github.com' "scripts/healthcheck.sh"
assert_contains "operator audit probes pull-request read access" 'repos/bigwinai/win/pulls' "scripts/healthcheck.sh"
assert_contains "operator audit probes Actions read access" 'repos/bigwinai/win/actions/runs' "scripts/healthcheck.sh"
assert_contains "runtime prompt documents repository scope" 'repository-scoped `GH_TOKEN`' "system-prompts/win-ops.md"

if grep -Fq 'Contents read' "$ROOT/.env.example"; then
  fail "environment contract grants unused Contents permission"
else
  pass "environment contract omits unused Contents permission"
fi

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
