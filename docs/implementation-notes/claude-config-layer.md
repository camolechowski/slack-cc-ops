---
spec: slack-cc-ops:settings assignment — Claude settings, hook, and system prompt
status: shipped
created: 2026-05-23
last_updated: 2026-05-23
related: []
---

# Claude Config Layer

## Summary
This workstream added the in-container Claude configuration layer for the slack-cc-ops bot: root `settings.json`, the Bash `PreToolUse` hook, and the principal `system-prompts/win-ops.md` prompt. The v1 security model deliberately uses Claude `bypassPermissions` plus an external Bash hook gate that only permits the `win` CLI and a small read-only safelist. The hook smoke tests passed for an allowed `win dev status` command and a denied `rm -rf /` command. The next obvious step is integration validation with the container entrypoint and Slack dispatch slices owned by the other panes.

## Current open questions
- [ ] Should the Bash hook later reject shell metacharacter chaining after an allowed argv0, or is the brief's first-token gate intentionally enough for v1?

## Sessions

### 2026-05-23 — session `20260523-f34ce10-c2x` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** slack-cc-ops:settings assignment in thread
**Files touched:** `settings.json`, `hooks/pretooluse-bash.sh`, `system-prompts/win-ops.md`, `docs/implementation-notes/README.md`, `docs/implementation-notes/claude-config-layer.md`

#### Context loaded
The repo did not yet have `docs/implementation-notes/`, `hooks/`, or `system-prompts/`. The assignment explicitly scoped this pane to Claude configuration, the PreToolUse Bash hook, and the win-ops system prompt, while reserving server, Docker, package, plugin, skill, and template files for other panes.

#### Design decisions
- **Minimal Claude settings:** Kept `settings.json` to the exact v1 shape from the brief: `bypassPermissions` plus one `PreToolUse` hook for Bash. This avoided coupling the config layer to future permission enumeration.
- **First-token hook policy:** Implemented the hook around the first non-whitespace token, with a special case for a leading `cd <dir> &&` prefix, because the brief explicitly rejected full shell parsing for v1. Git and Docker are narrowed by their first subcommand token.
- **Best-effort command extraction:** The hook parses the PreToolUse JSON with `python3` when available, then `node`, then a minimal Bash regex fallback. This keeps the hook usable in lean containers while still preferring a real JSON parser when present.

#### Deviations from spec
- **No intentional deviations:** The created repo-owned artifacts follow the brief. The implementation-notes files were added because the repository instructions require notes for non-trivial sessions.

#### Tradeoffs considered
- **Shell parser vs. simple gate:** Considered rejecting all shell metacharacters after an allowed command, but picked the requested first-token model to match the v1 brief. A stricter parser would reduce smuggling risk but could diverge from the expected contract other panes are building around.
- **JSON dependency choice:** Considered requiring `jq`, but avoided it because the prompt did not establish that the runtime image has `jq`. Python or Node are common enough to prefer, and the fallback keeps failure behavior predictable.

#### Open questions
- [ ] Should future versions reject shell chaining after allowed argv0 values, especially for bare `win`, `ls`, `cat`, and read-only git commands?

#### Footguns and gotchas
- The hook allows all `win` subcommands at the tool gate. The system prompt is responsible for requiring Slack confirmation before destructive `win` subcommands.
- The hook only strips a single leading `cd <dir> &&` prefix and does not attempt to understand quoted directories with `&&` inside them.
- `/state/inbox/hook.log` logging is best-effort and silently skipped when `/state/inbox` does not exist.

#### What shipped this session
- Created `settings.json` with Claude `bypassPermissions` and a Bash `PreToolUse` hook pointing at `/app/hooks/pretooluse-bash.sh`.
- Created executable `hooks/pretooluse-bash.sh` with the requested `win`, read-only utility, read-only git, read-only docker, and simple shell builtin safelist.
- Created `system-prompts/win-ops.md` with scoped bot identity, allowed operational entry points, destructive-command confirmation rules, Slack response style, permission relay behavior, threading note, and workspace assumptions.
- Validated `settings.json` with `python3 -m json.tool`.
- Validated the hook with `bash -n`, `win dev status` allow smoke test, `rm -rf /` deny smoke test, and a `cd /win && git status --short` prefix smoke test.

#### What's next
- Let the container/runtime pane verify that `/app/settings.json` is symlinked into `CLAUDE_CONFIG_DIR=/state/claude-config` and that Claude receives `system-prompts/win-ops.md` as intended.
