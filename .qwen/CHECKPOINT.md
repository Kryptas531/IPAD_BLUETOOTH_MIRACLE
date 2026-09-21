BRANCH: cleanup/source-of-truth (from verified origin/main; local main == origin == 7b8679d; no divergence)
BASE_MAIN: 7b8679de6543afb2451cb5913879bd8c1559d464
HEAD: tip of cleanup/source-of-truth (this checkpoint commit; previous: ebb5009)
SPEC_COMMIT: 3734cdf — docs(sot): consolidate canonical project specification (future behavior/scope
changes require a SPEC commit before implementation, referencing its SHA)

GOAL: Execute FINAL_QWEN_GIT_SOT_CLEANUP.md — one canonical SPEC.md (all still-valid facts from
docs/* migrated, docs then deleted; git history = archive), README.md rewritten, compact
AGENTS.md + QWEN.md, single .qwen/agents/reviewer.md, narrow .gitignore. No Swift behavior
changes. Do not merge to main.

DONE: preflight OK; docs audited; SPEC consolidated; §11 facts verified against code
(coalescedTouches TouchpadView.swift:222; setDesiredConnectionLatency(.low) HIDPeripheral.swift:542;
DirectInputController + Ctrl+Alt+Backspace chord; SFSpeech/CMMotion absent => gyro/dictation NOT
implemented); modifier regression after 0bccedc confirmed => recorded in SPEC §10 as active next
fix; upstream ad7a76c... verified via gh api; commits 3734cdf + 06b8985 + ebb5009 + this one;
branch pushed; PR #1 opened; independent Qwen reviewer finished: REVIEW: PASS — result posted
to PR #1 (issuecomment-5760068854).
VERIFIED: gh auth valid (Kryptas531); latest green CI run 35561610311 (head 7b8679d,
build-unsigned ✓); 7b8679d is docs-only over code HEAD 0bccedc (prior green 35511332912).
PENDING: user's physical acceptance tests (SPEC §9: Win tap→Start, Win+L→login→Alt+Tab→typing,
GAME metrics; full acceptance NOT run); modifier combined-keycap/sticky fix = next active
implementation work; merge only when explicitly requested; delete .qwen/CHECKPOINT.md before
merge.
NEXT: owner reviews PR #1 + reviewer comment, decides on merge; then implement the modifier fix.
BLOCKERS: none.
