BRANCH: cleanup/source-of-truth (branched from verified origin/main; local main == origin == 7b8679d; no divergence)
BASE_MAIN: 7b8679de6543afb2451cb5913879bd8c1559d464
HEAD: tip of cleanup/source-of-truth (chore(agents) commit, on top of 06b8985)
SPEC_COMMIT: 3734cdf — docs(sot): consolidate canonical project specification (future behavior/scope changes require a SPEC commit before implementation, referencing its SHA)

GOAL: Execute FINAL_QWEN_GIT_SOT_CLEANUP.md — one canonical SPEC.md (all still-valid facts from
docs/MVP|P2|BUILD|PHYSICAL_TEST|ARCHITECTURE|CANON LAYOUT|LAYOT PATCH migrated, docs then deleted;
git history = archive), README.md rewritten (goal + upstream origin), compact AGENTS.md + QWEN.md,
single .qwen/agents/reviewer.md profile, narrow .gitignore. No Swift behavior changes. Do not
merge to main.

DONE: git preflight OK; docs audited; SPEC consolidated; §11 facts verified against code
(coalescedTouches TouchpadView.swift:222; pendingMouseDX/drainPendingMouse/
setDesiredConnectionLatency(.low) HIDPeripheral.swift; GCKeyboard/GCMouse + Ctrl+Alt+Backspace
release chord DirectInputController.swift:384/391/507; SFSpeech/CMMotion absent => gyro/dictation
NOT implemented); modifier regression after 0bccedc confirmed in diff => recorded in SPEC §10 as
active next fix; upstream commit ad7a76c... verified to exist on GitHub (gh api);
commits: 3734cdf + 06b8985 + this one.
VERIFIED: gh auth valid (Kryptas531); latest green CI run 35561610311 (head 7b8679d, build-unsigned
✓, via gh run list); 7b8679d is docs-only over code HEAD 0bccedc (prior green 35511332912).
PENDING: user's physical acceptance tests (SPEC §9: Win tap→Start, Win+L→login→Alt+Tab→typing,
GAME metrics; full acceptance NOT run); independent Qwen reviewer on committed PR diff;
CHANGES-REQUIRED fixes if any; merge only when explicitly requested; delete .qwen/CHECKPOINT.md
before merge; modifier combined-keycap/sticky fix = next active implementation work.
NEXT: push branch → PR "docs(sot): consolidate canonical project specification" → independent
Qwen reviewer (read-only, model: inherit) → post result to PR.
BLOCKERS: none. (First git fetch attempt failed on network; retry succeeded.)
