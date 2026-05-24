---
spec: "Codex worker assignment: slack-cc-ops:metadata"
status: shipped
created: 2026-05-24
last_updated: 2026-05-24
related: []
---

# Repo Customization Layer

## Summary

This workstream covers the repository-level customization for Cam's slack-cc-ops fork of retrodigio/claude-channel-slack. The fork keeps the upstream Slack channel plugin mechanics intact while adding project identity, attribution, repo-local Claude notes, README fork context, and state template files for the Mac mini BigWin/win ops deployment. The current session completed the metadata and scaffold layer without changing upstream TypeScript, skills, Docker, hook, prompt, or template files.

## Current open questions

- [x] ~~Should this session lift odfalik/slack-channel-plugin threading code?~~ -> No, decided 2026-05-24 after the brief and existing `skills/threads/SKILL.md` confirmed retrodigio already handles thread to agent mapping at the application layer.

## Sessions

### 2026-05-24 — session `20260524-nogit-cod` (agent: codex)
**Branch / working tree:** `unknown; git commands intentionally avoided per brief`
**Spec ref:** User assignment "slack-cc-ops:metadata" plus `/Users/cameronolechowski/.claude/plans/that-sounds-write-jaunty-pascal.md`
**Files touched:** `package.json`, `NOTICE`, `CLAUDE.md`, `README.md`, `state/routes.example.json`, `state/access.example.json`, `docs/implementation-notes/README.md`, `docs/implementation-notes/repo-customization-layer.md`

#### Context loaded

Read the upstream `server.ts` opening section to confirm the root-level MCP/Bolt server, state directory defaults, access file, inbox, and singleton PID lock. Read `routes.example.json`, `ACCESS.md`, `README.md`, and `skills/threads/SKILL.md` to confirm the existing routing and thread-dispatch model before editing metadata. Read the canonical Mac mini plan doc for deployment context, then followed the user's updated discovery that no odfalik code lift belongs in this pane.

#### Design decisions

- **Keep upstream code untouched:** The assignment explicitly scoped this pane to repo metadata and scaffold files, so `server.ts`, `gate.ts`, tests, skills, templates, root `routes.example.json`, and access docs were left unchanged.
- **Use `NOTICE` without `.md`:** The current assignment requested root `NOTICE`; the older plan mentioned `NOTICE.md`, but the pane brief is newer and more specific.
- **Document the no-lift discovery:** The note resolves the open question about odfalik because the existing `skills/threads/SKILL.md` already documents thread to agent routing via Claude's native `Agent` and `SendMessage` tools.
- **Scaffold implementation notes despite pane file ownership:** The repo-level AGENTS protocol required notes for non-trivial sessions. This created `docs/implementation-notes/` even though the pane's owned-file list otherwise focused on metadata and state templates.

#### Deviations from spec

- **Implementation notes added:** The pane brief said to create or modify exactly the listed owned files, but the pasted AGENTS instructions required implementation notes at session start and end. The implementation notes are the only intentional extra repo files.
- **No native Codex run ID available:** No native session identifier was exposed in the tool context. To avoid touching git, the session ID uses `20260524-nogit-cod` instead of a short git SHA.

#### Tradeoffs considered

- **README insertion only:** Considered rewriting more of the README for the fork, but the assignment explicitly said not to overwrite the comprehensive upstream README. A top section keeps upstream docs intact while making the fork context visible first.
- **CLAUDE.md specificity:** Included files from the target deployment layout even when some were owned by other panes, because future Claude sessions need the intended layout map. Did not create or inspect those pane-owned files beyond naming them.

#### Open questions

- [ ] Confirm whether future sessions should treat implementation notes as exempt from pane-owned-file lists when both instructions appear together.

#### Footguns and gotchas

- The plan doc still contains older references to lifting odfalik/session-start code, but the assignment supersedes that for this pane.
- The state examples under `state/` are templates only. The human still needs to copy/fill `state/routes.json` and `state/access.json` with real Slack channel and user IDs during bootstrap.
- `state/` is intended to be gitignored and bind-mounted. These example files are intentionally templates, not live secrets or runtime state.

#### What shipped this session

- Renamed the package to `slack-cc-ops`, bumped version to `0.1.0`, and added the repository URL while preserving scripts and dependency versions.
- Added root `NOTICE` attribution for the retrodigio fork and Anthropic official channel plugin structural pattern.
- Added root `CLAUDE.md` with project purpose, layout, state, bootstrap, upstream remote, don't-touch guidance, and plan link.
- Added the README fork preface without replacing upstream content.
- Added `state/routes.example.json` and `state/access.example.json` templates.
- Added this implementation-notes index and workstream note.

#### What's next

- Pane 1 and pane 2 should finish their owned Docker, script, settings, hook, and prompt files, then the human can fill real Slack IDs into `state/routes.json` and `state/access.json` during Mac mini bootstrap.
