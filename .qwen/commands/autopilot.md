---
description: Run the autonomous fresh-session builder/reviewer/merge conveyor for the next usability stages
---

You are the ORCHESTRATOR only. Do not implement product code yourself.

Run from the repository root:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\qwen-autopilot.ps1

The script owns the workflow:
- sync main by fast-forward only;
- start a fresh headless Qwen builder for each stage;
- require exact-HEAD GREEN iOS CI;
- start a separate fresh headless reviewer session using the repository reviewer protocol;
- if CHANGES REQUIRED, start a fresh fixer and then another fresh reviewer;
- merge only after PASS on the unchanged PR HEAD, exact-HEAD GREEN CI, mergeable PR state, and no protected BLE/HID file changes;
- sync main, clean the finished stage branch, then start the next builder;
- stop immediately on ambiguity, protected-boundary changes, dirty tracked worktree, failed gates, or exhausted fix loops.

Default stage order:
TRACKPAD -> GAME -> Direct Input -> DECK.

Do not duplicate the child builder/reviewer work in this parent session.
Do not edit unrelated files.
When the script exits, report only whether AUTOPILOT COMPLETE or the exact blocker/log path.
