# AGENTS.md — provider-neutral operating rules

Repository: `Kryptas531/IPAD_BLUETOOTH_MIRACLE` (iPad → BLE HID → Windows controller).
Single canonical spec: `SPEC.md` (versioned by Git SHA only). Git history is the archive —
no parallel roadmap/architecture/P2/layout docs.

## Read order
1. `AGENTS.md` → 2. `SPEC.md` → 3. active task / active `.pi/` prompt →
4. directly relevant code and repository state.

Provider-specific files are NOT part of the default MAIN Pi read order.

- `QWEN.md` and `.qwen/*` apply only when Qwen Code itself is explicitly being used.
- A Pi MAIN session using a Qwen model must NOT treat `QWEN.md` as its runtime instructions.
- Model family/name does not determine runtime role.

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
- **Builder:** implementation role. In Pi autonomous runs this is `qwen-builder`.
- **Reviewer:** independent read-only review role. In Pi autonomous runs this is `qwen-reviewer`.
- **Orchestrator:** the root/main Pi session. Its role comes from the active Pi session and prompt,
  NOT from model family or provider name.
- MAIN may run on Qwen, Luna, Sol, or another configured model without changing its role.
- MAIN coordinates implementation/review and does not act as the routine product-code writer.
- External CLI subagents such as `claude-code`, `codex-exec`, and `cursor-agent` remain prohibited.
- `QWEN.md` and `.qwen/*` are Qwen Code runtime material only.

## Merge authorization
There are two distinct delivery modes:

1. **Manual flow**
   - builder/reviewer may prepare a PASSed PR;
   - merge requires a separate explicit owner/ChatGPT merge request.

2. **Owner-invoked Pi `/autopilot`**
   - invoking `/autopilot` is explicit authorization for that autonomous run;
   - MAIN may push, create/update PRs, wait for CI, repair repository-fixable failures,
     and merge automatically once every gate in the active Pi autopilot prompt passes;
   - no additional owner confirmation is required between PASS, CI GREEN, and normal merge.

Do not reinterpret an active owner-invoked Pi autopilot as manual mode merely because
the MAIN model is Qwen.

## Git workflow
1. fetch + preflight (never assume local `main == origin/main`; if diverged → STOP and report) →
2. branch from verified `origin/main` → 3. if contract/scope changes: SPEC commit first →
4. implementation in small commits → 5. verification → 6. push branch → 7. open PR →
8. independent reviewer reviews committed exact HEAD → 9. reviewer returns PASS /
CHANGES REQUIRED → 10. builder fixes concrete findings when required →
11. delivery follows the active mode:
   - manual flow: stop before merge and wait for explicit merge instruction;
   - owner-invoked Pi `/autopilot`: merge automatically after all documented review,
     exact-HEAD CI, mergeability, protection, and manual/hardware gates pass →
12. after merge, local `main` updates by fast-forward only.

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
Provider-specific checkpoints are not canonical repository truth.

- MAIN Pi does not read `.qwen/CHECKPOINT.md` by default.
- `.qwen/CHECKPOINT.md` is relevant only to an explicitly running Qwen Code workflow.
- Git state and `SPEC.md` always beat any temporary provider-specific checkpoint.
