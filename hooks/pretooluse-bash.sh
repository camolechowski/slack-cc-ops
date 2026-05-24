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

if [[ "$command_text" == cd[[:space:]]* ]] && [[ "$command_text" == *"&&"* ]]; then
  command_text="${command_text#*&&}"
  command_text="$(trim_leading "$command_text")"
fi

preview="${command_text//$'\n'/ }"
preview="${preview:0:200}"

verdict="denied"
allow=false

read -r argv0 argv1 _ <<<"$command_text"

case "$argv0" in
  # win CLI + read-only / safe utilities
  /opt/win-cli/bin/win|win|ls|cat|head|tail|grep|rg|fd|wc|find|stat|file|echo|printf|pwd|date|true|false|which|env|hostname|whoami|id|uname|uptime|df|du)
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
    case "$argv1" in
      status|log|diff|show|branch|remote|fetch|tag|describe|rev-parse|rev-list|ls-files|ls-tree|blame|reflog|shortlog|grep|stash)
        allow=true
        ;;
    esac
    ;;
  docker)
    # Read AND recovery verbs — bot needs to be able to restart win services
    # during incidents. Hook still denies destructive volume removal etc.
    case "$argv1" in
      ps|logs|inspect|stats|top|exec|compose|images|version|info|network|history|events|port|cp)
        allow=true
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
