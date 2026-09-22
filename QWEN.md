# QWEN.md — Qwen Code harness instructions

Short file by design. Canonical product/technical content = `SPEC.md`; operating rules =
`AGENTS.md`. Read first: `AGENTS.md`, then `SPEC.md`, then `.qwen/CHECKPOINT.md` if present,
then code.

## Model and tools
- Only the current corporate Qwen model + built-in Qwen Code features.
- Do NOT use Codex, Claude, or any external/paid models or APIs.
- Main builder/dev sessions use the corporate Qwen thinking route at MEDIUM effort with the
  project builder anti-churn profile.
- Normal project-local agents (`.qwen/agents/`) may use `model: inherit` unless the task says
  otherwise. Keep only `reviewer.md`; do not maintain many specialist profiles unless a future
  task truly needs one.
- Exception: `.qwen/agents/reviewer.md` pins `model: openai-responses:Qwen/Qwen3.8-Flash-Next`
  (independent, read-only, final-review role); it must never inherit the default no-thinking
  worker route.
- Final reviewer runs at MEDIUM effort with its own reviewer anti-churn instructions.
- Do not add task-specific acceptance rules to the persistent reviewer profile.
- XHIGH is manual-only; never use it automatically for builder or final-review flow.

## Environment
- Windows machine (PowerShell/cmd available); Qwen Code `run_shell_command` executes through
  cmd.exe — quoted arguments are fine, avoid a single `&` or `%` and quoted-exe-at-command-start.
- No Xcode/swift/xcodebuild locally — Swift compilation cannot be verified on this machine;
  build verification happens only through GitHub Actions.
- GitHub CLI: `C:\LIFE\gh.exe` — authenticated for `Kryptas531/IPAD_BLUETOOTH_MIRACLE`
  (fine-grained token, contents:write; verified working 2026-09-21). Example:
  `C:\LIFE\gh.exe run list --limit 5`.

## Mandatory git preflight (before touching anything)

```text
git fetch --prune origin
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
git log --oneline --decorate -10
```

Never assume local `main == origin/main`. If they diverge → STOP and report. No `reset --hard`,
`git clean -fd`, force-push, or published-history rewrite. Do not work directly on `main`. Do not
auto-add unknown untracked files.

## Branch / PR / review flow
1. Branch from verified `origin/main` (e.g. `cleanup/source-of-truth`).
2. If expected behavior, architecture, UX contract, acceptance criteria or scope changes →
   SPEC commit first (`spec(scope): define …`), then implementation referencing the spec SHA
   (`feat(scope): … [spec <sha>]`). Pure fixes restoring specified behavior need no spec commit.
3. Small commits: `type(scope): concrete outcome` (types: spec/feat/fix/test/docs/refactor/chore/
   ci); one concern per commit.
4. Builder verifies the task, pushes the branch (never `main`), and opens/updates the PR.
   PR title follows the commit naming rule; body uses:
   `SPEC / BASE / GOAL / CHANGED / VERIFIED / PHYSICAL TEST / RISKS`.
5. After implementation is complete, the builder session STOPS. Do not perform final review
   from the builder session.
6. Start a NEW Qwen Code session for final review. The fresh session must use MEDIUM effort and
   MUST invoke the named `reviewer` subagent. The parent session must not duplicate the review.
7. The reviewer independently inspects the committed PR diff, current task/canon, real files,
   relevant tests/CI, and exact reviewed HEAD, then returns:
   `REVIEW: PASS` or `REVIEW: CHANGES REQUIRED`.
8. If `CHANGES REQUIRED`: return to a builder session, fix with new commits, verify, push, then
   repeat final review from another fresh Qwen Code session.
9. Outside the explicit owner-invoked autopilot flow below, Qwen does NOT merge automatically.
   Stop and report the reviewed PR number and reviewed HEAD SHA to the owner.
10. In the manual flow, the owner sends the PASSed PR to ChatGPT for a second independent
    GitHub-state check and merge. ChatGPT verifies that the PR HEAD still matches the reviewed
    HEAD and checks relevant GitHub/CI state before merging.
11. After merge, local `main` may be synchronized by fast-forward only.

The final reviewer must not inherit builder-session context; fresh-session review is the default.
Builder summaries and reviewer summaries are not substitutes for real repository/GitHub evidence.

## Explicit `/autopilot` exception
When the owner explicitly invokes `/autopilot`, `tools/qwen-autopilot.ps1` is authorized to
orchestrate and merge the requested stages without returning to the owner between stages.

The autopilot must:
- use a fresh headless Qwen process for every builder, reviewer, and fixer pass;
- keep the parent/orchestrator read-only with respect to product code;
- run the reviewer as a fresh top-level Qwen process using `.qwen/agents/reviewer.md` as
  instruction text on the inherited project MEDIUM route; do not depend on the nested pinned
  reviewer route in this mode;
- merge only after `REVIEW: PASS` for the unchanged current PR HEAD, exact-HEAD GREEN
  `Build unsigned IPA` CI, a mergeable PR, and zero protected BLE/HID file changes;
- stop on a dirty tracked worktree, ambiguity, protected-boundary changes, stale review,
  failed exact-HEAD CI, or exhausted fixer loops;
- fast-forward local `main` after each merge before launching the next stage.

Invoking `/autopilot` is the owner's explicit merge authorization for that run only. Manual
`/build`, `/final-review`, and `/fix-review` keep the normal no-auto-merge behavior.

## Task checkpoint
`.qwen/CHECKPOINT.md` — temporary branch handoff, not truth. Create only on working branches;
commit on that branch; ≤30 lines; update at meaningful handoff points; delete before final merge;
never let it remain in `main`. Git/SPEC beat the checkpoint on conflict.

## Final report format (concise)
`STATUS / DONE / VERIFIED / NOT VERIFIED / BLOCKERS / NEXT`.

Never claim "build passes", "feature works", or an acceptance test passed without evidence
(a CI run URL, a downloaded artifact path, or the user's own hardware confirmation).
