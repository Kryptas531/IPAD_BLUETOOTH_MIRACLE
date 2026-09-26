# AGENTS.md — provider-neutral operating rules

Repository: `Kryptas531/IPAD_BLUETOOTH_MIRACLE` (iPad → BLE HID → Windows controller).
Single canonical spec: `SPEC.md` (versioned by Git SHA only). Git history is the archive —
no parallel roadmap/architecture/P2/layout docs.

## Read order
1. `AGENTS.md` → 2. `SPEC.md` → 3. provider file (`QWEN.md`) → 4. task checkpoint if present
(`.qwen/CHECKPOINT.md`) → 5. code.

## Rules
- Current Git + current `SPEC.md` beat old summaries and old docs.
- Inspect code/diff/CI before claiming status. CI does not prove physical behavior.
- No scope expansion without a preceding SPEC commit (e.g. `spec(game): define gyro aim behavior`,
  then implementation commits referencing that spec SHA). Pure fixes restoring already-specified
  behavior do not require a spec commit.
- Minimal diffs; reuse existing code; no rewriting working code for style; no new dependencies or
  abstractions without a concrete need.
- Protected BLE/HOGP code requires an explicit technical reason and focused review:
  `BTRemote/LowEnergy/`, `BTRemote/Classic/`, `BTRemote/HIDInput.swift`, `BTRemote/HIDReports.swift`.
- Do not continue superlatency work (PARKED, see `SPEC.md` §11) without a separate owner decision.
- Never commit credentials, downloaded IPA/ZIPs, SideStore data, probes (`rawprobe/`), temp
  folders (`.qwen/tmp`), or unrelated scratch.
- Never silently fix unrelated findings.

## Roles
- **Builder:** edits and commits.
- **Reviewer:** a separate Qwen agent/session; reviews the committed PR diff only; does not edit
  the builder's work; returns exactly `REVIEW: PASS` or `REVIEW: CHANGES REQUIRED` plus concrete
  findings.
- **Orchestrator:** may coordinate fresh builder/reviewer/fixer sessions but must not implement
  product code itself. It may merge only when the owner explicitly invokes an autopilot flow whose
  provider instructions define strict same-HEAD review, CI, mergeability and protected-file gates.
- Do not maintain many specialist agent profiles — keep only `.qwen/agents/reviewer.md` unless a
  future task truly needs more.

## Pi orchestration exception

For Pi-based autonomous development runs:

- The root/main Pi session may use `openai-codex/gpt-6-luna` as the orchestrator.
- Routine implementation and review must use the project Pi agents:
  - `qwen-builder` → corporate Qwen
  - `qwen-reviewer` → corporate Qwen
- The Luna orchestrator delegates implementation/review and should not act as the routine code writer.
- External CLI subagents such as `claude-code`, `codex-exec`, and `cursor-agent` remain prohibited.
- Qwen Code-specific rules in `QWEN.md` continue to apply when Qwen Code itself is used.

## Git workflow
1. fetch + preflight (never assume local `main == origin/main`; if diverged → STOP and report) →
2. branch from verified `origin/main` → 3. if contract/scope changes: SPEC commit first →
4. implementation in small commits → 5. verification → 6. push branch → 7. open PR →
8. separate Qwen reviewer reviews committed PR diff → 9. reviewer posts `REVIEW: PASS` /
`REVIEW: CHANGES REQUIRED` → 10. builder fixes findings with new commits → 11. owner or ChatGPT
merges only when explicitly requested; an explicitly owner-invoked provider autopilot may perform
that merge only under its documented strict gates → 12. after merge, local `main` updates by
fast-forward only.

Do not push feature work directly to `main`. No `reset --hard`, `git clean -fd`, force-push, or
published-history rewrites. Do not delete or commit unknown local scratch.

## Commit naming
`type(scope): concrete outcome` — allowed types: `spec`, `feat`, `fix`, `test`, `docs`, `refactor`,
`chore`, `ci`. One concern per commit. Good: `fix(keyboard): restore sticky modifier behavior`,
`docs(readme): explain project goal and upstream origin`. Bad: `update`, `changes`, `fix stuff`,
`p2`, `final`, `try again`.

## PR format
Title follows the commit naming rule. Body (short and factual):

```text
SPEC:
BASE:
GOAL:

CHANGED:
VERIFIED:
PHYSICAL TEST:
RISKS:
```

## Task checkpoint
`.qwen/CHECKPOINT.md` — a temporary branch handoff, not canonical truth. Create it only on a
working feature/cleanup branch; commit it on that branch so GitHub/ChatGPT can read it; keep it
≤30 lines; update only at meaningful handoff points; delete it before final merge; it must never
remain in `main`. Template fields: BRANCH / BASE_MAIN / HEAD / SPEC_COMMIT / GOAL / DONE /
VERIFIED / PENDING / NEXT / BLOCKERS. If checkpoint conflicts with Git/SPEC — Git/SPEC wins.
