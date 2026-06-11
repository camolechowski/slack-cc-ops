#!/usr/bin/env bash
# PostToolUse audit hook.
#
# Appends one JSON line per tool call to /state/inbox/audit.jsonl so there is a
# structured, greppable record of what the bot did — independent of the
# ANSI-polluted tmux pane mirror in claude.log. The /state mount maps to
# .win-ops/ on the host, so the trail survives container restarts.
#
# Each line: { ts, tool, summary, decision }
#   - tool:    the tool name (Bash, Read, Write, ...)
#   - summary: the Bash command, else a compact preview of tool_input
#   - decision: "ok" when tool_response carries no error, else "error"
#
# The hook never blocks: any failure here must not break a tool call, so it
# exits 0 unconditionally.
set -u

input="$(cat)"
AUDIT_DIR=/state/inbox
AUDIT_FILE="$AUDIT_DIR/audit.jsonl"

emit() {
  [[ -d "$AUDIT_DIR" ]] || return 0
  printf '%s\n' "$1" >>"$AUDIT_FILE" 2>/dev/null || true
}

if command -v python3 >/dev/null 2>&1; then
  line="$(python3 -c '
import json, sys, datetime

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    tool = d.get("tool_name", "") or ""
    ti = d.get("tool_input", {}) or {}
    if isinstance(ti, dict) and ti.get("command"):
        summary = str(ti["command"])
    elif isinstance(ti, dict):
        summary = " ".join(f"{k}={v}" for k, v in ti.items())
    else:
        summary = str(ti)
    summary = summary.replace("\n", " ")[:500]
    tr = d.get("tool_response", {})
    err = False
    if isinstance(tr, dict):
        err = bool(tr.get("error")) or tr.get("is_error") is True or tr.get("success") is False
    decision = "error" if err else "ok"
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps({"ts": ts, "tool": tool, "summary": summary, "decision": decision}))

main()
' <<<"$input" 2>/dev/null)"
  emit "$line"
  exit 0
fi

if command -v node >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # JS template literals, deliberately not shell-expanded
  line="$(node -e '
let s = "";
process.stdin.on("data", (c) => (s += c));
process.stdin.on("end", () => {
  let d = {};
  try { d = JSON.parse(s); } catch (_) {}
  const ti = (d && d.tool_input) || {};
  let summary = "";
  if (ti && ti.command) summary = String(ti.command);
  else if (ti && typeof ti === "object") summary = Object.entries(ti).map(([k, v]) => `${k}=${v}`).join(" ");
  else summary = String(ti);
  summary = summary.replace(/\n/g, " ").slice(0, 500);
  const tr = (d && d.tool_response) || {};
  const err = !!(tr && (tr.error || tr.is_error === true || tr.success === false));
  const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  process.stdout.write(JSON.stringify({ ts, tool: (d && d.tool_name) || "", summary, decision: err ? "error" : "ok" }));
});
' <<<"$input" 2>/dev/null)"
  emit "$line"
  exit 0
fi

# Last-resort: no JSON runtime. Record a minimal, escaped preview so the trail
# is never empty even on a stripped image.
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
preview="${input//$'\n'/ }"
preview="${preview//\\/\\\\}"
preview="${preview//\"/\\\"}"
preview="${preview:0:500}"
emit "{\"ts\": \"$ts\", \"tool\": \"unknown\", \"summary\": \"$preview\", \"decision\": \"ok\"}"
exit 0
