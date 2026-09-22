---
description: Fresh-session independent final review using the pinned named reviewer subagent
---

This command is ONLY for a fresh Qwen Code session.

PR TO REVIEW:
{{args}}

## Fresh-session gate
If this conversation contains builder/implementation work for the PR being reviewed, STOP.
Do not perform the review here. Tell the owner to open a NEW Qwen Code session and run this
command there.

The final review must use MEDIUM reasoning effort.

## Required action
MUST invoke the named `reviewer` subagent.

Do not perform or duplicate the review in the parent session.
Do not replace the named reviewer with built-in `/review`.
Do not edit repository files.

The reviewer must independently inspect the live committed PR state, including:
- exact PR number;
- exact current HEAD SHA;
- current task/PR instructions;
- current `SPEC.md`;
- current `AGENTS.md` / `QWEN.md`;
- real changed-file list and diff;
- relevant files;
- relevant tests;
- CI for the exact reviewed implementation SHA when CI is acceptance evidence;
- history only when a material claim depends on it.

Builder summaries and PR prose are indexes, not proof.

## Result
Wait for the named reviewer to finish.

Return its verdict and concrete findings without inventing a second review.

If verdict is `REVIEW: PASS`, also report:
- PR number;
- exact reviewed HEAD SHA;
- any explicitly NOT VERIFIED physical evidence.

Do NOT merge.
Do NOT modify the PR unless the task explicitly asks to post the review.

If verdict is `REVIEW: CHANGES REQUIRED`, state that the next step is a builder run using:
`/fix-review <PR_NUMBER> <findings>`
