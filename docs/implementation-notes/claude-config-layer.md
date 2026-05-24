---
spec: slack-cc-ops:settings assignment — Claude settings, hook, and system prompt
status: shipped
created: 2026-05-23
last_updated: 2026-05-24
related: []
---

# Claude Config Layer

## Summary
This workstream owns the in-container Claude configuration layer for the slack-cc-ops bot: root `settings.json`, the Bash `PreToolUse` hook, the principal `system-prompts/win-ops.md` prompt, and the Claude startup state needed for non-interactive container restarts. The v1 security model deliberately uses Claude `bypassPermissions` plus an external Bash hook gate that permits the `win` CLI and targeted shell recovery tools. Remote Mac mini rebuild validation is now complete, and the prompt has been tightened so the bot defaults to highly agreeable, persistent operator behavior: act on principal instructions, ask once when destructive confirmation is required, and keep driving recovery until the deploy or incident is actually resolved.

## Current open questions
- [ ] Should the Bash hook later reject shell metacharacter chaining after an allowed argv0, or is the brief's first-token gate intentionally enough for v1?
- [x] ~~Can a coordinator with SSH access run the fresh Mac mini rebuild validation and confirm the pane reaches the Claude REPL with channel loading and no prompts?~~ -> Yes. On 2026-05-24 the Mac mini rebuild/redeploy completed successfully, the container reconnected to Slack, and beta health verified on `build.commit = 5459614e`.

## Sessions

### 2026-05-24 — session `20260524-df0a559-oyc` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** ad-hoc operator-direction follow-up from `#win-ops`; see Summary above
**Files touched:** `system-prompts/win-ops.md`, `docs/implementation-notes/README.md`, `docs/implementation-notes/claude-config-layer.md`

#### Context loaded
I read the existing `claude-config-layer` note, the current `system-prompts/win-ops.md`, and the live runtime state after the Mac mini redeploy. The immediate user feedback was that the bot still sounded too hesitant and insufficiently action-oriented for a stand-in operator, especially around deploy requests and post-failure persistence.

#### Design decisions
- **Agreeable-by-default operator stance:** The system prompt now explicitly tells the bot to treat principal requests as marching orders, not conversation topics, unless a real safety gate or missing capability blocks execution.
- **Persist-through-failure rule:** The deploy-failure section now distinguishes between blind loops and purposeful recovery. The bot should not stop after one failed command; it should diagnose, take the next justified step, and only stop when a fresh confirmation or human-only action is truly required.
- **Mark the config layer shipped:** Remote Mac mini rebuild validation is no longer hypothetical. The bot container was rebuilt, reconnected to Slack, regained Docker access, and beta health was externally verified, so the old blocked status no longer reflects reality.

#### Deviations from spec
- **Behavioral prompt strengthening:** The original v1 prompt already covered confirmation and tooling, but the live operator expectation is stronger: high compliance, high persistence, and low conversational friction. The new wording reflects the real operating contract rather than the more tentative initial draft.

#### Tradeoffs considered
- **Agreeable vs. reckless:** I strengthened the bot toward direct action, but kept the explicit confirmation boundary for destructive operations. Removing that line entirely would reduce friction further, but it would also make accidental production-impacting commands too easy in a public Slack channel.

#### Open questions
- None.

#### Footguns and gotchas
- A stronger prompt does not replace the hook or OS-level permissions. The bot still needs the runtime capabilities to match the prompt, or it will sound confident while failing underneath.
- "Persist" should not mean hammering the same failing command forever. The prompt now frames persistence as active recovery, not repetition.

#### What shipped this session
- Updated `system-prompts/win-ops.md` so the bot defaults to agreeable, action-first behavior for principal requests.
- Tightened the deploy-failure guidance so the bot keeps driving recovery after the first failure instead of stopping prematurely.
- Marked the Claude config layer as shipped now that live Mac mini rebuild validation and hosted beta health proof have both been completed.

#### What's next
- Rebuild/redeploy `slack-cc-ops` so the new prompt is live in the running container, then spot-check the bot's tone and persistence in Slack.

### 2026-05-23 — session `20260523-aeaeeaf-p7q` (agent: codex)
**Branch / working tree:** `master`
**Spec ref:** slack-cc-ops:persistence — kill interactive prompts on container restart
**Files touched:** `settings.json`, `scripts/entrypoint.sh`, `docs/implementation-notes/README.md`, `docs/implementation-notes/claude-config-layer.md`

#### Context loaded
Read the existing `claude-config-layer` and `container-infrastructure` notes, then inspected `settings.json`, `scripts/entrypoint.sh`, local Claude Code 2.1.150 settings/schema strings, and the WIN tmux suggester's prior onboarding pre-seed pattern. The requested live Mac mini discovery path was attempted first, but this sandbox cannot resolve `mac-mini` and direct SSH to the known Tailscale address is blocked with `Operation not permitted`.

#### Design decisions
- **Trust key source:** Local Claude Code 2.1.150 binary strings showed the current project trust shape as `.claude.json.projects[resolvedProjectPath].hasTrustDialogAccepted`. The entrypoint should seed `/app` specifically, preserving any existing project object fields.
- **Bypass warning source:** Claude Code 2.1.150 settings schema documents `skipDangerousModePermissionPrompt` as "Whether the user has accepted the bypass permissions mode dialog"; prompt acceptance writes this to user settings. The entrypoint can also preserve/set legacy `.claude.json.bypassPermissionsModeAccepted` because the binary still contains a migration from that old key to the settings key.
- **Hook schema:** The repo's initial `settings.json` used the old flat hook command form. Current Claude hook schema expects a matcher entry with a nested `hooks` array of command hook objects.

#### Deviations from spec
- **Live mini diff unavailable:** The spec asked to pull the answered-through `.claude.json` from `superpea@mac-mini`. SSH/network access is blocked in this sandbox, so the key discovery used local Claude Code 2.1.150 strings and disposable config probing instead of the live mini file.

#### Tradeoffs considered
- **Settings-only bypass vs. dual seeding:** Current Claude uses `settings.json.skipDangerousModePermissionPrompt`; adding the legacy `.claude.json.bypassPermissionsModeAccepted` is redundant on 2.1.150 but cheap compatibility for nearby versions and does not overwrite tokens or unrelated config.

#### Open questions
- [ ] Remote validation still needs to be run from an environment that can SSH to `superpea@mac-mini`.

#### Footguns and gotchas
- Do not rewrite the Mac mini's `.win-ops/claude-config/.claude.json`; it contains working OAuth credentials. The entrypoint must merge keys into whatever file exists.
- `skipDangerousModePermissionPrompt` belongs in Claude settings, not only in `.claude.json`, for current Claude Code.

#### What shipped this session
- Updated `settings.json` to use Claude's nested command hook schema for `PreToolUse` and to set `skipDangerousModePermissionPrompt: true`.
- Updated `scripts/entrypoint.sh` to merge startup acknowledgement keys into `.claude.json`: `hasCompletedOnboarding: true`, legacy `bypassPermissionsModeAccepted: true`, and `projects["/app"].hasTrustDialogAccepted: true` while preserving existing project/config fields.
- Validated `settings.json` with `python3 -m json.tool`, `scripts/entrypoint.sh` with `bash -n`, and a disposable local Claude Code 2.1.150 config that reached the REPL with trust and bypass prompts suppressed for the exact trusted path.

#### What's next
- From a network-capable shell, pull these changes on the Mac mini, run `docker rm -f slack-cc-ops; docker compose up -d --build`, then inspect Docker logs and the `slackcc` tmux pane for the Claude REPL plus loaded Slack channels.

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
