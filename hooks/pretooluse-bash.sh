#!/usr/bin/env bash
set -u

input="$(cat)"

extract_command() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("command", ""))
except Exception:
    print("")' <<<"$input"
    return
  fi

  if command -v node >/dev/null 2>&1; then
    node -e 'let s="";
process.stdin.on("data", c => s += c);
process.stdin.on("end", () => {
  try {
    const data = JSON.parse(s);
    process.stdout.write(String((data.tool_input && data.tool_input.command) || ""));
  } catch (_) {}
});' <<<"$input"
    return
  fi

  # Last-resort parser for the expected compact hook payload shape.
  if [[ "$input" =~ \"command\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '\n'
  fi
}

trim_leading() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "$value"
}

command_text="$(extract_command)"
command_text="$(trim_leading "$command_text")"

# Preserve the full, pre-strip command for cross-cutting safety checks.
# The cd-strip below rewrites command_text to drop a leading `cd ... &&`,
# which would otherwise hide a `cd ~/dvl/win-live &&` prefix from both the
# hard-deny scan and the win-* scoping. Both must see the original text.
full_command="$command_text"

if [[ "$command_text" == cd[[:space:]]* ]] && [[ "$command_text" == *"&&"* ]]; then
  command_text="${command_text#*&&}"
  command_text="$(trim_leading "$command_text")"
fi

preview="${command_text//$'\n'/ }"
preview="${preview:0:200}"

verdict="denied"
allow=false

# ---------------------------------------------------------------------------
# HARD-DENY: the data-destruction class (the 2026-05-14 wipe line).
#
# This runs FIRST, against the full pre-strip command_text, and short-circuits
# before any allow logic. A deny here can never be undone by a later allow, and
# scanning the whole string (not just argv0/argv1) is what catches the verb when
# it is chained behind a benign command, e.g. `docker ps && docker volume rm x`.
#
# Refused outright — no allowlist verb rescues these:
#   - any `-v` / `--volume(s)` flag (covers clusters: -v, -vf, -fv, --volumes)
#   - docker volume rm | docker volume prune
#   - docker system prune ... --volumes
#   - dropdb
# `docker compose down -v` and `docker rm -v` are caught by the -v scan above.
# ---------------------------------------------------------------------------
hard_deny=false
case "$full_command" in
  *docker*" -v"*|*docker*" --volume"*|*docker*" --volumes"*) hard_deny=true ;;
esac
# Combined single-dash clusters that include `v` (e.g. -vf, -fv) after a docker
# subcommand: scan tokens for a single-dash flag cluster containing v.
if [[ "$full_command" == *docker* ]]; then
  for tok in $full_command; do
    if [[ "$tok" == -[!-]* && "$tok" != --* && "$tok" == *v* ]]; then
      hard_deny=true
    fi
  done
fi
case "$full_command" in
  *"docker volume rm"*|*"docker volume prune"*) hard_deny=true ;;
  *"volume rm"*|*"volume prune"*) hard_deny=true ;;
  *"system prune"*"--volumes"*) hard_deny=true ;;
  *dropdb*) hard_deny=true ;;
esac

if [[ "$hard_deny" == true ]]; then
  if [[ -d /state/inbox ]]; then
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "hard-denied" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
  fi
  printf '[hook] denied (data-destruction class refused): %s\n' "$preview" >&2
  exit 2
fi

read -r argv0 argv1 _ <<<"$command_text"

# True when the full (pre-strip) command targets a win-* container or compose
# project: win-staging-*, win-live-*, win-ops. Used to scope the newly-allowed
# stop/rm/down recovery verbs so the bot can only self-recover win stacks.
targets_win_scope() {
  # Matches both container names (win-live-server-1, win-staging-redis-1) and
  # compose project paths/dirs (~/dvl/win-live, win-live), plus the win-ops
  # container.
  case "$full_command" in
    *win-staging*|*win-live*|*win-ops*) return 0 ;;
    *) return 1 ;;
  esac
}

git_subcommand() {
  local rest="$command_text"
  local token next

  # strip leading `git`
  rest="${rest#git}"
  rest="$(trim_leading "$rest")"

  while [[ -n "$rest" ]]; do
    read -r token next _ <<<"$rest"
    case "$token" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)
        rest="${rest#"$token"}"
        rest="$(trim_leading "$rest")"
        if [[ -n "$next" ]]; then
          rest="${rest#"$next"}"
          rest="$(trim_leading "$rest")"
        fi
        ;;
      --*)
        rest="${rest#"$token"}"
        rest="$(trim_leading "$rest")"
        ;;
      *)
        printf '%s\n' "$token"
        return
        ;;
    esac
  done
}

case "$argv0" in
  # win CLI + read-only / safe utilities
  /opt/win-cli/bin/win|win|ls|cat|head|tail|grep|rg|fd|wc|find|stat|file|echo|printf|pwd|date|true|false|which|env|hostname|whoami|id|uname|uptime|df|du)
    allow=true
    ;;
  sleep)
    allow=true
    ;;
  # text / data manipulation for diagnostics
  sed|awk|jq|cut|sort|uniq|tr|xargs|tee|tail|column|diff|comm)
    allow=true
    ;;
  # network probes for triage (read-only)
  curl|wget|dig|nslookup|ping|host|ss|netstat|nc|openssl)
    allow=true
    ;;
  git)
    case "$(git_subcommand)" in
      status|log|diff|show|branch|remote|fetch|tag|describe|rev-parse|rev-list|ls-files|ls-tree|blame|reflog|shortlog|grep|stash)
        allow=true
        ;;
    esac
    ;;
  docker)
    # Read AND recovery verbs — bot needs to be able to restart/recover win
    # services during incidents. The data-destruction class (any -v/--volumes,
    # volume rm/prune, dropdb) is already hard-denied above, so anything that
    # reaches here is in the reversible "move production" class.
    case "$argv1" in
      ps|logs|inspect|stats|top|exec|images|version|info|network|history|events|port|cp)
        allow=true
        ;;
      # Recovery verbs that act on running containers/stacks — scoped to win-*
      # (win-staging-*, win-live-*, win-ops) so the bot can self-recover stuck
      # win stacks but cannot stop/remove unrelated containers.
      stop|rm)
        if targets_win_scope; then allow=true; fi
        ;;
      compose)
        # `docker compose down` (no -v) is reversible recovery; scope it to
        # win-* projects. All other compose subcommands (restart, up, ps, logs,
        # config, ...) keep their prior allow-all behavior.
        if [[ "$full_command" == *" down"* ]]; then
          if targets_win_scope; then allow=true; fi
        else
          allow=true
        fi
        ;;
    esac
    ;;
esac

if [[ "$allow" == true ]]; then
  verdict="allowed"
fi

if [[ -d /state/inbox ]]; then
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
fi

if [[ "$allow" == true ]]; then
  printf '{"continue": true}\n'
  exit 0
fi

printf '[hook] denied: %s\n' "$preview" >&2
exit 2
