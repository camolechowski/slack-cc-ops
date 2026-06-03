# 001 — Autonomous PR authoring + deploy-approval enforcement

Status: **Proposed** (Gap A: ready to build, kept light; Gap B: design-only — do not build yet)
Last updated: 2026-06-03 · Owner: Cam

> Scope note. WinOps is deliberately separate from the WIN system and is, for now, "basically going to just be used by me and probably outside the context of the system." This spec keeps rules to the minimum that makes it *work* — it does not invent process. Anything heavier (roles, approver matrices, audit pipelines) is written down here as *future enforcement*, not as a gate on shipping Gap A.

## Current state (grounded)

The bot is the `slack-cc-ops` container on the Mac mini (`~/dvl/win-ops`), a persistent Claude REPL driven from #win-ops as **@winops**. What it can do today:

- Full `win` CLI as Scott super admin (`~/.win/auth.json` mounted writable from `./win-home`, ~90-day OAuth refresh).
- Deploy via the controller on `mac-mini:9475` — `win deploy beta|staging|cancel` (auth `WIN_DEPLOY_RUNTIME_TOKEN`).
- `docker compose restart` of `win-live-*` services; `curl` the mini's internal docker network.
- Read-only inspection of the win monorepo at `/win`.

What it **cannot** do — the single real gap:

- **Author a code fix and open a PR.** `/win` is mounted read-only (`docker-compose.yml`: `./win:/win:ro`, plus the two other `:ro` win mounts). The system prompt (`system-prompts/win-ops.md`, lines 115 and 141) tells the bot to *propose a diff in chat* and lets Cam apply it locally. So "message the bot to go fix an issue" stops one step short of a PR — a human is always in the edit loop.

## Gap A — let @winops author a fix + open a PR (ready to build, light)

**Design principle: add a writable scratch checkout; leave `/win` read-only.** `/win` is a worktree of `~/dvl/win-live`; making it `:rw` would let the bot mutate the live runtime checkout. Keep it `:ro` as the reference mount and give the bot a *separate, disposable* working copy it owns.

### Mechanism

1. **Writable work clone under `/state`.** Add a mount such as `./win-work:/state/work/win` (writable) and, on demand (or at container start), `git clone`/`fetch` the repo there. The bot edits, commits, and pushes a branch from `/state/work/win` — never from `/win`. `/win` stays the canonical read-only view.
2. **A GitHub push identity.** The bot needs a token with `repo` + PR scope. Two options:
   - **(A1) Cam PAT in `/state` env (light-now).** Fastest. Mutates show up as Cam. Acceptable while WinOps is just Cam/Scott. Store outside the image; never bake into the Dockerfile or commit it.
   - **(A2) Dedicated WinOps GitHub App / machine user (preferred-later).** Clean audit identity ("authored by winops-bot"), scoped install, revocable independently of Cam's account. More setup. Spec it now, adopt when WinOps outgrows "just me."
3. **PR open path.** Use `gh` (or `win gh` if/when the CLI exposes it) from the work clone: branch → commit → push → `gh pr create`. The bot posts the PR URL back to #win-ops.
4. **Unblock Write/Edit for the work clone only.** The Bash hook (`hooks/pretooluse-bash.sh`) and `settings.json` already allow `win <anything>` + read-only git on `/win`. Extend the allow-set to permit `git -C /state/work/win` write verbs and `gh pr ...`, and confirm `Write`/`Edit` are permitted under `/state/work/**`. Do **not** broaden write access to `/win`.

### Keep it light (per operator steer)

- **No approval gate to *open* a PR.** A PR is reviewable and non-destructive — opening one commits nothing to production. The bot opens it; Cam reviews and merges on GitHub as normal. Do not add a confirmation step here.
- Destructive actions stay gated exactly as today (the system prompt already requires confirm-first for `win deploy`, `win jobs kill`, `win api delete`, restores, etc.). Authoring a PR does not touch that list.

### Success criteria

- @winops, asked in #win-ops to fix a bug, edits files in `/state/work/win`, pushes a branch, and replies with a real PR URL against `camolechowski/win` (or the correct remote).
- `/win` remains read-only — an attempt to write under `/win` still fails (named test / manual check).
- The PR step **fails closed**: if the GitHub token is missing/invalid, the bot reports the failure and proposes the diff in chat (today's fallback) — it never silently swaps to another identity or writes to `/win`.
- No change to the deploy path: a PR does not deploy anything.

## Gap B — enforce deploy approval LATER (design only; do not build)

Today `win deploy beta` succeeds with only the controller token; @winops "confirms" in chat (an advisory, self-granted check). Operator decision: **keep it light now — no approval required.** This section only *lays out* how to enforce approval if/when that changes, so the path exists.

**Where the gate must live: the deploy controller (`mac-mini:9475`), not the bot.** A bot-side check is advisory and spoofable (the bot authors its own confirmations). Real enforcement belongs in the controller, which already holds the only credential that can move an environment.

**Shape of an enforced gate (future):**

- **Approver allowlist** in controller config (e.g. Cam + Scott principal IDs). A deploy request from an identity not on the list is refused server-side.
- **Two-party handshake (optional, strongest):** `win deploy beta` becomes *request* → controller records a pending deploy + token → a *second* listed principal must approve (a second command / signed call) before the controller executes. Single-party mode (requester self-approves) is the lighter setting; make the mode a config flag, defaulting to off (= today's behavior).
- **Safety preconditions enforced controller-side, independent of who approves:** a fresh backup point exists (`/Users/superpea/win-backups/`), active-job quiescence is verified, and `--force` is either refused or separately re-gated — per the 2026-05-14 wipe-incident protocols. These should hold *even in light mode*, because they protect data regardless of approval policy.
- **Audit line** per deploy: who requested, who approved, ref, reason, backup id.

None of Gap B blocks Gap A. Gap A (PR authoring) is requester-scoped and reviewable; Gap B (deploy enforcement) is the production-authz boundary and stays as-is (light) until the operator asks to tighten it.

## Non-goals (keep WinOps separate)

- Not a WIN workflow. Do **not** route this through the WIN kernel, router, subprocess spawn path, WIN roles, or the WIN `tokens` table.
- No new role system inside WinOps. Access stays the channel allowlist in `gate.ts` (principals: Cam, Scott).
- The corrected WIN-side note is `win/docs/specs/050-winops-chatops-slack-fix-dispatch.md` (Reference/pointer only). This repo is the source of truth.
