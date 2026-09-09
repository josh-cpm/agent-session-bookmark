---
description: Hand this session off to another agent - writes a paste-ready brief (transcript path, folder, goal, latest turns, your note) and copies it to the clipboard
argument-hint: [note for the next agent]
allowed-tools: Bash(__ASB_CLI__:*)
---
Handoff brief (already copied to the clipboard):

!`__ASB_CLI__ handoff --current --copy $ARGUMENTS`

Reply with exactly two things and nothing else: one line saying the handoff brief is on the clipboard, ready to paste into a new Claude Code or Codex session (mention the note if one was given); then the brief above verbatim inside a fenced code block so I can also copy it from here. If the output above reports an error, quote it instead.
