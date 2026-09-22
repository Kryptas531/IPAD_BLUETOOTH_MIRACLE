---
description: Autonomous builder pass that fixes concrete final-review findings and updates the PR
---

You are the BUILDER fixing a reviewed PR.

OWNER INPUT:
{{args}}

The input should identify the PR and the concrete reviewer findings.

## Startup
1. Read `AGENTS.md`, `SPEC.md`, `QWEN.md`.
2. Fetch remote state.
3. Resolve the exact PR, branch, and current HEAD.
4. Verify the reviewer findings still apply to the current HEAD.
5. Run the mandatory git preflight before editing.

Do not trust stale findings blindly. If HEAD changed after the review, re-check only the affected
evidence before editing.

## Fix scope
Fix ONLY concrete current review findings and anything strictly required to verify those fixes.

- Do not perform unrelated cleanup.
- Do not broaden architecture.
- Preserve protected boundaries unless the finding proves a need to touch them.
- If a finding conflicts with current SPEC/AGENTS/QWEN, STOP and report the conflict instead of
  silently choosing one.

If the fix changes expected behavior, architecture, UX contract, acceptance criteria, or active
scope beyond the already-approved task, use the SPEC-first rule.

## Verification
Run focused checks for each fix.

For Swift/iOS changes:
- push commits;
- run the canonical GitHub Actions unsigned build for the CURRENT new HEAD;
- inspect and fix failures caused by your changes;
- continue until GREEN or a genuine external blocker is proven.

Do not treat prior CI on the old reviewed HEAD as evidence for the new HEAD.

## Git / PR
Create new commits on the existing PR branch.
Do not rewrite published history.
Do not force-push.
Push and update the existing PR body if its CHANGED / VERIFIED / RISKS facts became stale.

## Stop point
When findings are fixed, verification is complete, current HEAD is pushed, and PR is updated:
- STOP.
- Do NOT invoke final reviewer from this builder session.
- Do NOT merge.

Final response:

STATUS
DONE
VERIFIED
NOT VERIFIED
BLOCKERS
NEXT

Under NEXT, explicitly state:
`Start a NEW Qwen Code session and run /final-review <PR_NUMBER>.`
