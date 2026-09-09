---
name: handoff
description: Hand the current Codex session off to another agent. Writes a paste-ready brief (transcript path, working folder, original goal, latest turns, and the user's note) and copies it to the clipboard. Use when the user types $handoff, "hand this off", "hand off to Claude", or wants to move this work to a new agent, optionally with a note.
---

Run this one command, passing any words the user gave as the note (`$ARGUMENTS`
may be empty):

    __ASB_CLI__ handoff --current --copy $ARGUMENTS

It reads this session's rollout to build the brief and copies it to the
clipboard with pbcopy. It resolves the current session by looking at recent
rollouts, so run it directly, not inside a subagent. If the sandbox blocks it,
rerun it with escalated permissions; that is expected and safe.

Then reply with exactly two things: one line saying the handoff brief is on the
clipboard, ready to paste into a new Claude Code or Codex session (mention the
note if one was given); then the command's output verbatim in a fenced code
block. If the command printed an error, quote it instead. Do nothing else.
