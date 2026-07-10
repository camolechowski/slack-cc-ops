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
working_dir=""

if [[ "$command_text" == cd[[:space:]]* ]] && [[ "$command_text" == *"&&"* ]]; then
  cd_prefix="${command_text%%&&*}"
  read -r cd_word cd_dir cd_extra <<<"$cd_prefix"
  if [[ "$cd_word" == "cd" && -n "$cd_dir" && -z "${cd_extra:-}" ]]; then
    working_dir="$cd_dir"
  fi
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

has_shell_control() {
  case "$command_text" in
    *$'\n'*|*';'*|*'&'*|*'||'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('* ) return 0 ;;
    *) return 1 ;;
  esac
}

privileged_family_is_wrapped() {
  case "$argv0" in
    docker|gh) return 1 ;;
    env|xargs|find|awk|rg|fd)
      case "$command_text" in
        *docker*|*gh*) return 0 ;;
      esac
      ;;
  esac
  case "$command_text" in
    *"/var/run/docker.sock"*) return 0 ;;
  esac
  return 1
}

named_sidecar_restart_allowed() {
  local words=()
  read -r -a words <<<"$command_text"
  [[ "${#words[@]}" -eq 3 ]] || return 1
  case "${words[2]}" in
    bigwinstaging-cloudflared|bigwinbeta-cloudflared) return 0 ;;
    *) return 1 ;;
  esac
}

compose_subcommand_allowed() {
  local words=()
  local index=2
  local project=""
  local token=""
  local verb=""
  local service_count=0
  local saw_detach=false
  local saw_no_build=false
  local saw_no_recreate=false
  local saw_no_deps=false
  local saw_pull_never=false
  local saw_force=false

  read -r -a words <<<"$command_text"
  while [[ "$index" -lt "${#words[@]}" ]]; do
    token="${words[$index]}"
    case "$token" in
      -p|--project-name)
        index=$((index + 1))
        [[ "$index" -lt "${#words[@]}" ]] || return 1
        project="${words[$index]}"
        ;;
      --project-name=*)
        project="${token#*=}"
        ;;
      -*)
        # A compose-file or environment override could redirect an otherwise
        # allowed recovery verb to an attacker-controlled stack.
        return 1
        ;;
      *)
        verb="$token"
        break
        ;;
    esac
    index=$((index + 1))
  done

  case "$verb" in
    ps|logs|config|images|top|events|ls|version|port)
      return 0
      ;;
    up|stop|rm)
      [[ "$working_dir" == "/win" ]] || return 1
      case "$project" in
        win-live|win-staging) ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac

  index=$((index + 1))
  while [[ "$index" -lt "${#words[@]}" ]]; do
    token="${words[$index]}"
    case "$verb:$token" in
      up:-d|up:--detach) saw_detach=true ;;
      up:--no-build) saw_no_build=true ;;
      up:--no-recreate) saw_no_recreate=true ;;
      up:--no-deps) saw_no_deps=true ;;
      up:--pull)
        index=$((index + 1))
        [[ "$index" -lt "${#words[@]}" && "${words[$index]}" == "never" ]] || return 1
        saw_pull_never=true
        ;;
      up:--pull=never) saw_pull_never=true ;;
      stop:-t|stop:--timeout)
        index=$((index + 1))
        [[ "$index" -lt "${#words[@]}" && "${words[$index]}" =~ ^[0-9]+$ ]] || return 1
        ;;
      rm:-f|rm:--force) saw_force=true ;;
      rm:-s|rm:--stop) ;;
      *:postgres|*:redis|*:minio|*:minio-init|*:server|*:kernel|*:daemon|*:proxy|*:dashboard)
        service_count=$((service_count + 1))
        ;;
      *) return 1 ;;
    esac
    index=$((index + 1))
  done

  [[ "$service_count" -gt 0 ]] || return 1
  case "$verb" in
    up)
      [[ "$saw_detach" == true && "$saw_no_build" == true && "$saw_no_recreate" == true && "$saw_no_deps" == true && "$saw_pull_never" == true ]]
      ;;
    stop) return 0 ;;
    rm) [[ "$saw_force" == true ]] ;;
  esac
}

gh_read_allowed() {
  local words=()
  local index=3
  local repo_count=0
  local token=""
  read -r -a words <<<"$command_text"
  [[ "${#words[@]}" -ge 3 ]] || return 1

  case "${words[1]}:${words[2]:-}" in
    auth:status)
      [[ "${#words[@]}" -eq 5 && "${words[3]}" == "--hostname" && "${words[4]}" == "github.com" ]]
      return
      ;;
    pr:list|pr:view|pr:status|pr:checks|pr:diff|run:list|run:view|run:watch|workflow:list|workflow:view|repo:view)
      ;;
    *) return 1 ;;
  esac

  while [[ "$index" -lt "${#words[@]}" ]]; do
    token="${words[$index]}"
    case "$token" in
      -R|--repo)
        index=$((index + 1))
        [[ "$index" -lt "${#words[@]}" && "${words[$index]}" == "bigwinai/win" ]] || return 1
        repo_count=$((repo_count + 1))
        ;;
      -Rbigwinai/win|--repo=bigwinai/win)
        repo_count=$((repo_count + 1))
        ;;
      -R*|--repo=*) return 1 ;;
    esac
    index=$((index + 1))
  done
  [[ "$repo_count" -eq 1 ]]
}

docker_network_read_allowed() {
  local words=()
  read -r -a words <<<"$command_text"
  [[ "${#words[@]}" -ge 3 ]] || return 1
  case "${words[2]}" in
    ls|inspect) return 0 ;;
    *) return 1 ;;
  esac
}

if has_shell_control; then
  if [[ -d /state/inbox ]]; then
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "denied" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
  fi
  printf '[hook] denied (shell composition refused): %s\n' "$preview" >&2
  exit 2
fi

if privileged_family_is_wrapped; then
  if [[ -d /state/inbox ]]; then
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "denied" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
  fi
  printf '[hook] denied (privileged command wrapper refused): %s\n' "$preview" >&2
  exit 2
fi

if [[ "$argv0" == "/opt/win-cli/bin/win" || "$argv0" == "win" ]]; then
  case "$argv1" in
    gh)
      if [[ -d /state/inbox ]]; then
        printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "denied" "$preview" >>/state/inbox/hook.log 2>/dev/null || true
      fi
      printf '[hook] denied (use scoped read-only gh commands directly): %s\n' "$preview" >&2
      exit 2
      ;;
  esac
fi

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
  gh)
    # Direct GitHub access uses the repository-scoped read-only GH_TOKEN.
    # Keep the command surface read-only too; writes remain denied even if the
    # token is ever mis-scoped by an operator.
    if ! has_shell_control && gh_read_allowed; then
      allow=true
    fi
    ;;
  docker)
    if ! has_shell_control; then
      case "$argv1" in
        ps|logs|inspect|stats|top|images|version|info|history|events|port)
          allow=true
          ;;
        network)
          if docker_network_read_allowed; then allow=true; fi
          ;;
        restart)
          if named_sidecar_restart_allowed; then allow=true; fi
          ;;
        compose)
          if compose_subcommand_allowed; then allow=true; fi
          ;;
      esac
    fi
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
