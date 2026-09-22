# QWEN.md — Qwen Code harness instructions

Short file by design. Canonical product/technical content = `SPEC.md`; operating rules =
`AGENTS.md`. Read first: `AGENTS.md`, then `SPEC.md`, then `.qwen/CHECKPOINT.md` if present,
then code.

## Model and tools
- Only the current corporate Qwen model + built-in Qwen Code features.
- Do NOT use Codex, Claude, or any external/paid models or APIs.
- Normal project-local agents (`.qwen/agents/`) may use `model: inherit` unless the task says
  otherwise. Keep only `reviewer.md`; do not maintain many specialist profiles unless a future
  task truly needs one.
- Exception: `.qwen/agents/reviewer.md` pins `model: openai-responses:Qwen/Qwen3.8-Flash-Next`
  (independent, read-only, final-review role); it must never inherit the default no-thinking
  worker route.
- Do not add task-specific acceptance rules to the persistent reviewer profile.

## Environment
- Windows machine (PowerShell/cmd available); Qwen Code `run_shell_command` executes through
  cmd.exe — quoted arguments are fine, avoid a single `&` or `%` and quoted-exe-at-command-start.
- No Xcode/swift/xcodebuild locally — Swift compilation cannot be verified on this machine;
  build verification happens only through GitHub Actions.
- GitHub CLI: `C:\LIFE\gh.exe` — authenticated for `Kryptas531/IPAD_BLUETOOTH_MIRACLE`
  (fine-grained token, contents:write; verified working 2026-09-21). Example:
  `C:\LIFE\gh.exe run list --limit 5`.

## Mandatory git preflight (before touching anything)
```
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
4. Verify → push branch (never to `main`) → open PR (title follows the commit naming rule;
   body: SPEC/BASE/GOAL/CHANGED/VERIFIED/PHYSICAL TEST/RISKS).
5. Independent Qwen reviewer (separate agent/session, read-only) reviews the committed PR diff
   and posts the verdict.
6. Builder fixes findings with new commits. Owner or ChatGPT merges only when explicitly
   requested; after merge, local `main` by fast-forward only.

## Task checkpoint
`.qwen/CHECKPOINT.md` — temporary branch handoff, not truth. Create only on working branches;
commit on that branch; ≤30 lines; update at meaningful handoff points; delete before final merge;
never let it remain in `main`. Git/SPEC beat the checkpoint on conflict.

## Final report format (concise)
`STATUS / DONE / VERIFIED / NOT VERIFIED / BLOCKERS / NEXT`.
Never claim "build passes", "feature works", or an acceptance test passed without evidence (a CI
run URL, a downloaded artifact path, or the user's own hardware confirmation).
