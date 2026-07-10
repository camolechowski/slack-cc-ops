---
spec: bigwinai/win issue #711 - WS-STAB Slice 3 WinOps authority pack
status: in-progress
created: 2026-07-10
last_updated: 2026-07-10
related: [claude-config-layer, container-infrastructure]
---

# WinOps Authority Pack

## Summary
This workstream narrows the slops Bash gate to the exact WIN self-heal authority approved in issue #711 and declares the read-only `GH_TOKEN` contract needed for GitHub deploy/PR diagnostics. Final operator direction limits recovery to two named sidecar restarts plus Compose `stop`/`start` of existing WIN containers; `up` and `rm` are operator-gated. The implementation is local-only on `uat/stab-win-ops-authority`; no token value, host access, container create/recreate, deploy, merge, or live validation is part of this slice.

## Current open questions
- [x] ~~Does the operator accept the exact pre-PR-ready security diff after local gates, or require a narrower command spelling/project set?~~ → Narrow to direct named-sidecar restart plus Compose `stop`/`start`; deny `up`/`rm`, decided 2026-07-10.

## Sessions

### 2026-07-10 - session `20260710-c11a1cc-s3d` (agent: codex)
**Branch / working tree:** `uat/stab-win-ops-authority` / fresh isolated clone `scratchpad/clone-stab-s3-slops`
**Spec ref:** bigwinai/win issue #711, Slice 3 CTO security ruling after L2
**Files touched:** `hooks/pretooluse-bash.sh`, `hooks/pretooluse-bash.test.sh`, `system-prompts/win-ops.md`, `AGENTS.md`, this note

#### Context loaded
Read the final issue #711 ruling after capped cross-family L2 passed at `c11a1cc`. The ruling rejects both accepting stale-config creation risk and building a broker: self-heal may stop/start existing WIN containers only; `up` and `rm` stay operator-gated.

#### Design decisions
- **Existing-container verbs only:** Compose mutation is exactly `stop` and `start`, with the existing `/win`, project, and known-service checks. `start` does not create a missing container.
- **Creation/removal escalates:** Compose `up` and `rm` are denied regardless of flags/project. A rare wedged-container repair that needs `rm` + `up` is a human escalation, not bot self-heal.
- **Preserve the reviewed surrounding boundary:** Named sidecars, read-only GitHub grammar, global shell-composition denial, project/service pinning, and catastrophic hard-denies remain unchanged.

#### Deviations from spec
- **Final verb set is narrower than the original issue shorthand:** The earlier `up/stop/rm` shorthand was superseded by the operator's explicit post-review ruling because `up` can create from stale `/win` config.

#### Tradeoffs considered
- **Manual rare recovery vs silent stale resurrection:** Accept the human escalation for wedged containers. It costs a manual rescue only when removal/recreation is truly needed and prevents the bot from silently instantiating stale protected-production config.

#### Open questions
- None for implementation; operator must review the final diff before PR #5 leaves draft.

#### Footguns and gotchas
- `docker compose start` requires the target container to exist; failure is the intended escalation signal, not a reason to fall back to `up`.
- The bot must never translate a failed `start` into `rm`/`up`; the prompt now says to report the exact service/state and escalate.

#### What shipped this session
- Hook/parser and runtime prompt now grant only named-sidecar restart plus project/service-scoped Compose `stop`/`start`; Compose `up` and `rm` are denied for every project/flag combination.
- `bun run check` exits 0 at the working diff: 19 existing Bun tests, 64 hook cases, 11 authority-contract checks, and Bash syntax for every hook/operator script.
- Focused adversarial re-review returned PASS after directly reproducing allowed start/stop (including multi-service/timeout) and denied old/new `up`, `rm`, unknown service/project/flag, and WIN-app restart forms.
- `git diff --check` is clean. Final draft packaging/operator diff review remain.

#### What's next
- Commit/push the final ruled verb set, update the PR body and WIN tracking PR, and show the exact PR #5 diff while keeping it draft for operator review.

### 2026-07-10 - session `20260710-1ab2128-s3a` (agent: codex)
**Branch / working tree:** `uat/stab-win-ops-authority` / fresh isolated clone `scratchpad/clone-stab-s3-slops`
**Spec ref:** bigwinai/win issue #711, Slice 3; CTO ruling comment 4937840235
**Files touched:** `.env.example`, `package.json`, `hooks/pretooluse-bash.sh`, `hooks/pretooluse-bash.test.sh`, `scripts/container-healthcheck.sh`, `scripts/healthcheck.sh`, `scripts/authority-contract.test.sh`, `system-prompts/win-ops.md`, `AGENTS.md`, `CLAUDE.md`, implementation notes

#### Context loaded
Read the CTO's five rails, this repo's `AGENTS.md` and `CLAUDE.md`, the current config/container notes, runtime prompt, Bash hook, Dockerfile, Compose file, environment example, and capability healthchecks. The fresh clone starts clean at `origin/master` `1ab2128e96fc819e45d334ee29c97c7bda6a6f76`; the protected Mac mini and the user's other local checkout are untouched.

#### Design decisions
- **Two direct-restart targets only:** Permit `docker restart bigwinstaging-cloudflared` and `docker restart bigwinbeta-cloudflared`. Do not generalize by prefix/glob and do not grant direct `docker stop` or `docker rm`.
- **Explicit Compose project and restricted `up` grammar:** Permit mutating Compose verbs `up`, `stop`, and `rm` only from `/win` when global `-p`/`--project-name` identifies `win-live` or `win-staging` and every service is from the known WIN set. `up` requires `-d --no-build --no-recreate --no-deps --pull never`; this cannot build, pull, or recreate an existing container, but may create a missing one from stale `/win` config.
- **Deny other Compose mutations:** Preserve a small read-only Compose set, but deny `down`, `restart`, `kill`, `start`, `create`, `build`, `pull`, and other mutations even on a WIN project because they are outside the ratified self-heal set.
- **Reject wrappers and composition on privileged paths:** A Docker or GitHub command containing wrapper, shell control, redirection, or substitution syntax is denied. The sole leading `cd /win &&` exception exists only for project-scoped Compose parsing.
- **Reject shell composition globally:** Cross-family L2 reproduced a P0 by prefixing privileged commands with allowed benign verbs (`true && gh auth token`, `echo x && docker stop ...`). The corrected hook rejects shell control/redirection/substitution after normalizing the sole `cd /win &&` exception, before any argv0 allow decision.
- **Named token contract, never material:** Declare only `GH_TOKEN=` and its fine-grained, repository-scoped read permissions: Metadata, Pull requests, and Actions for `bigwinai/win`. Contents permission was considered and removed because the approved diagnostics do not need it. The value is operator-owned and must never appear in source, tests, logs, diffs, or PR text.
- **Defense-in-depth GitHub grammar:** Direct `gh` access is limited to read verbs, one exact `bigwinai/win` repository flag, and exact token-redacted auth status. Raw API, write verbs, `--show-token`, other repositories, and the broad `win gh` wrapper are denied even though the token itself must also be read-only.
- **Separate cheap liveness from live scope proof:** The recurring container healthcheck will require the env name and `gh` binary without a network dependency. The operator-run host healthcheck will validate `gh auth status` plus read-only PR/Actions API calls after activation.

#### Deviations from spec
- **Pre-existing diagnostics narrowed:** Exact lifecycle authorization was bypassable through `docker exec`, `docker cp`, unrestricted Docker network verbs, wrapper utilities, raw Docker-socket `curl`, and `win gh`. These pre-existing surfaces were narrowed or denied in the same gate change because leaving them open would make the stated specific-set boundary false.
- **Compose activation proof deferred:** The task explicitly forbids host access, and `/win` is a reference worktree rather than either active runtime checkout. Local tests prove the parser and denial boundary only. `--no-recreate` does not stop Compose from creating an absent container (including after allowed `rm -f`), so operator disposition is required before activation rather than treating the flags as a complete runtime boundary.

#### Tradeoffs considered
- **Project flag plus trusted reference directory:** A project flag alone can retarget an attacker-supplied Compose file. The policy requires both exact `/win` working directory and exact project identity and rejects all Compose file/env overrides. The remaining missing-container creation risk is explicit and unresolved; it is not mislabeled as start-only.
- **Continuous GitHub API health vs operator audit:** A 30-second Docker healthcheck that depends on GitHub availability would restart a healthy Slack operator during an external outage. Contract presence belongs in liveness; token validity/scope belongs in the deeper manual audit.

#### Open questions
- [ ] Should either named cloudflared sidecar be removed from the exact set during operator diff review?
- [ ] Does the operator accept `/win` plus the mandatory no-build/no-recreate/no-pull grammar for the activation drill, or require a separately brokered runtime-config path before merge?

#### Footguns and gotchas
- Canonical PR #2 previously made all Compose subcommands except `down` allow-all. This slice intentionally removes that overbroad behavior; preserving it would not satisfy #711's specific-set acceptance.
- `/win` is a stale reference worktree, not either active host runtime checkout. The mandatory `--no-build --no-recreate --pull never` grammar blocks build/pull/recreation of an existing container, but an absent service may still be created from stale config. A mount of runtime `.env` or other credential-bearing paths was explicitly rejected; a brokered active-runtime path is the safer unresolved alternative.
- `env_file: .env` already passes `GH_TOKEN` into the container, so no Compose interpolation or secret value belongs in `docker-compose.yml`.
- `docker compose rm` may use `-f`/`--stop`; those flags are permitted, but all volume flags remain hard-denied before allow logic.
- No local test may call Docker, GitHub, Slack, or the Mac mini. Hook tests feed synthetic Claude PreToolUse JSON to the script.

#### What shipped this session
- Implemented an exact two-sidecar restart allowlist and project/service/flag-aware Compose parser; all other lifecycle mutations fail closed.
- Added repository-pinned read-only `gh` verbs, exact token-redacted auth status, and explicit denials for writes, raw API, other repositories, `win gh`, and common wrapper/chaining bypasses.
- Added the blank `GH_TOKEN` least-privilege contract, cheap container presence checks, and operator-only live PR/Actions access probes without exposing a value.
- Added one repo-local `bun run check` gate covering 19 existing Bun tests, 62 synthetic hook cases, 11 authority-contract checks, and Bash syntax for every hook/operator script. The gate exits 0 locally.
- Cross-family L2 Round 1 returned BLOCK on benign-lead compound-command bypasses. The global composition gate and six direct regressions close that specific P0; Round 2 re-review is required before PR-ready.
- Cross-family L2 Round 2 found the same P0 class still reachable through a lone background `&`. The global predicate now rejects any `&`, and three regressions cover token display, direct Docker restart, and Compose mutation behind that separator. Round 3 is the gate-contract cap.
- An exploratory ad-hoc TypeScript command was not green: this repo has no `tsconfig`, typecheck script, or lockfile, and the resolver selected TypeScript 7.0.2 plus current caret dependencies; diagnostics are in unchanged `gate.test.ts`/`server.ts`. This is recorded as non-gate evidence rather than misreported as a passing check.

#### What's next
- Commit/push the review draft, present the exact compare/PR diff and `/win` caveat to the operator, and remain draft until operator gate review plus cross-family L2 both pass. Then complete the separate WIN spec 050/051 tracking PR; activation remains operator-only.
