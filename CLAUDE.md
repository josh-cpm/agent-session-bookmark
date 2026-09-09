# Agent Session Bookmark: notes for agents working in this repo

**If the user asked you to install this tool, follow `INSTALL.md` step by step
and report what you verified.** Do not improvise an install: the script handles
build, LaunchAgent, CLI, migration, and the Claude Code / Codex integrations.

## What this is

A macOS desktop panel (SwiftUI, no dependencies) listing recent Claude Code and
Codex sessions with live status, previews, resume commands, and "Return to"
bookmarks. `README.md` describes behavior and layout; `INSTALL.md` is the
install runbook.

## Working on it

- Python: stdlib only, must run on `/usr/bin/python3` (3.9). Tests:
  `python3 -m unittest`. Set `ASB_HOME` and `ASB_CACHE_DIR` to scratch folders
  when running the scripts by hand so you do not touch the user's bookmarks.
- Swift: edit `AgentSessionBookmark/*.swift`, then `./build.sh --run`. Verify
  visually with `SW_SNAPSHOT=/tmp/x.png SW_HEIGHT=700 "build/Agent Session Bookmark.app/Contents/MacOS/AgentSessionBookmark"`
  (renders a PNG and quits; no screen-recording permission needed).
- The Python scripts are copied into the app bundle by `build.sh`; the
  installed app and CLI use the bundled copies, not the checkout. After changing
  a script, rerun `./install.sh` (or `./build.sh --run` for a dev run).
- Bump `CACHE_VERSION` in `sessions_feed.py` if the parse-state shape or
  semantics change.
- Templates in `integrations/` use `__ASB_APP__`, `__ASB_CLI__`, and
  `__ASB_LOG_DIR__` placeholders that `install.sh` renders.
- Do not track row visibility with `onAppear`/`onDisappear` inside the SwiftUI
  list: it caused a layout loop (100% CPU) in an early build.

## Decisions to keep

- Resume copies a command to the clipboard; it does not launch a terminal.
- Live sessions have no resume action.
- No third-party widget hosts or dependencies: the content is sensitive.
- Bookmark state lives in `~/Library/Application Support/Agent Session Bookmark/`,
  never in the repo.
