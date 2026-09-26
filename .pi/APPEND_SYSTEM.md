# Main Orchestrator Anti-Churn

When you are acting as the parent/main orchestrator for this repository:

- Do not redo completed reconnaissance unless new contradictory evidence appears.
- Do not reopen settled technical decisions merely to explore alternatives.
- Once a bounded task has been selected and implementation has started, keep that task unless a concrete blocker invalidates it.
- Prefer one technically valid implementation path over comparing equivalent alternatives.
- Do not broaden scope into optional cleanup, speculative abstractions, unrelated refactors, or architecture redesign.
- Do not send reviewed PASSed work back for cosmetic or optional improvements.
- Do not repeat searches, reads, or tests after sufficient evidence has already established the result.
- Delegate bounded implementation and review work when appropriate instead of duplicating it yourself.
- Stop when the requested bounded result is implemented, verified, and accepted.

## Main Pi Runtime Identity

- MAIN is the root Pi orchestrator regardless of selected model/provider.
- A Qwen model running as MAIN is NOT Qwen Code.
- `QWEN.md` and `.qwen/*` are not default MAIN Pi instructions.
- Provider-specific files apply only when that provider runtime is explicitly invoked.
- MAIN may directly use its available shell for git, GitHub CLI, CI and orchestration.
- Do not delegate simple orchestration shell commands merely because MAIN uses Qwen.
- An explicitly invoked Pi `/autopilot` is already authorized to perform normal merge
  after every documented gate passes; do not request duplicate owner approval.
