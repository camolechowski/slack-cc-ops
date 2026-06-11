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
# HARD-DENY: the catastrophic class.
#
# These blocks run FIRST, against the full pre-strip command_text, and
# short-circuit before any allow logic. A deny here can never be undone by a
# later allow, and scanning the whole string (not just argv0/argv1) is what
# catches the verb when it is chained behind a benign command, e.g.
# `docker ps && docker volume rm x`.
#
# This is the second guard layer; settings.json `permissions.deny` is the first
# (it fires even in bypassPermissions mode). Both intentionally cover the same
# catastrophic set, so neither alone is load-bearing.
#
# The classes, each in its own block below:
#   1. data-destruction (the 2026-05-14 wipe line): docker -v/--volume(s),
#      volume rm|prune, system prune --volumes, dropdb
#   2. filesystem-destruction: rm -rf on /, $HOME/~, or the dvl service roots
#   3. destructive DB + trunk force-push: DROP DATABASE/TABLE, force-push or
#      branch-delete of main/master
#   4. secret-exfiltration: reading a credential/.env/key file straight into a
#      network egress tool in one command
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

# ---------------------------------------------------------------------------
# HARD-DENY: filesystem-destruction class.
#
# `rm -rf` (any flag order: -rf, -fr, -r -f) aimed at a host root — `/`,
# `$HOME`/`~`, or the dvl service roots — is the irrecoverable case. Anything
# narrower (a scratch dir, a build artifact) is left to the allowlist, since
# `rm` is not an allowed argv0 anyway and would be denied by default.
# ---------------------------------------------------------------------------
if [[ "$full_command" == *rm* ]]; then
  recursive_force=false
  for tok in $full_command; do
    if [[ "$tok" == -[!-]* && "$tok" != --* && "$tok" == *r* && "$tok" == *f* ]]; then
      recursive_force=true
    fi
  done
  case "$full_command" in
    *"-r "*"-f "*|*"-f "*"-r "*|*"--recursive"*"--force"*|*"--force"*"--recursive"*) recursive_force=true ;;
  esac
  if [[ "$recursive_force" == true ]]; then
    # Strip quotes/tabs/newlines and collapse whitespace runs so a quoted or
    # space-padded root target reduces to plain ` rm ... / ` tokens we can
    # match without quote gymnastics. The deleted set is built via printf to
    # keep the quoting unambiguous.
    strip_set="$(printf '\t\n"%s' "'")"
    normalized=" $(printf '%s' "$full_command" | tr -d "$strip_set") "
    while [[ "$normalized" == *"  "* ]]; do normalized="${normalized//  / }"; done
    case "$normalized" in
      *" rm "*" / "|*" rm "*" /Users "*) hard_deny=true ;;
    esac
    # shellcheck disable=SC2016  # literal `$HOME`/`~` match is intended, no expansion
    case "$normalized" in
      *" rm "*' $HOME '*|*" rm "*' ~ '*|*" rm "*' ~/ '*|*" rm "*' $HOME/ '*) hard_deny=true ;;
    esac
    case "$full_command" in
      *"/Users/superpea/dvl/win"*|*"/Users/superpea/dvl/traefik"*) hard_deny=true ;;
      *"/Users/superpea/.seerr"*|*"/Users/superpea/.win"*) hard_deny=true ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# HARD-DENY: destructive DB and force-push class.
#   - DROP DATABASE (any casing) issued through psql/sql one-liners
#   - git push --force / -f / --force-with-lease onto main or master
#   - git push origin --delete main|master (branch deletion of trunk)
# A non-trunk feature-branch force-push stays allowed by the allowlist's
# git verbs (push is not in the read-verb list, so it is denied by default
# anyway — this block exists to make trunk force-push catastrophic, not just
# unlisted).
# ---------------------------------------------------------------------------
case "$full_command" in
  *"DROP DATABASE"*|*"drop database"*|*"DROP TABLE"*|*"drop table"*) hard_deny=true ;;
esac
if [[ "$full_command" == *"push"* && "$full_command" == *git* ]]; then
  case "$full_command" in
    *--force*|*" -f "*)
      case "$full_command" in
        *" main"*|*" master"*|*:main*|*:master*|*main:*|*master:*|*origin*) hard_deny=true ;;
      esac
      ;;
  esac
  case "$full_command" in
    *"push"*--delete*main*|*"push"*--delete*master*|*"push"*:main|*"push"*:master) hard_deny=true ;;
  esac
fi

# ---------------------------------------------------------------------------
# HARD-DENY: secret-exfiltration class.
#
# Reading the contents of a credential / .env / private-key file and feeding
# it to a network egress tool (curl/wget/nc/scp/...) in the SAME command is
# the exfiltration shape we refuse. Inspecting a secret file on its own stays
# allowed — the bot legitimately reads config — so the deny requires both a
# local secret read (cat/grep/< redirect on a secret path) AND egress in the
# one pipeline.
# ---------------------------------------------------------------------------
reads_secret=false
case "$full_command" in
  *"cat "*.env*|*"cat "*credential*|*"cat "*auth.json*|*"cat "*id_rsa*|*"cat "*id_ed25519*) reads_secret=true ;;
  *"<"*.env*|*"<"*credential*|*"<"*auth.json*) reads_secret=true ;;
  *"/.win/auth.json"*) reads_secret=true ;;
esac
if [[ "$reads_secret" == true ]]; then
  case "$full_command" in
    *curl*|*wget*|*" nc "*|*netcat*|*"/dev/tcp/"*|*scp*|*rsync*|*ncat*)
      hard_deny=true
      ;;
  esac
fi

if [[ "$hard_deny" == true ]]; then
  if [[ -d /state/inbox ]]; then
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "hard-denied" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
  fi
  printf '[hook] denied (catastrophic class refused): %s\n' "$preview" >&2
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
