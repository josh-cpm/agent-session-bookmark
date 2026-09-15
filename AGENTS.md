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

- Python: stdlib only, must run on Python 3.9 (the oldest interpreter the
  resolver may pick). Do not hardcode `/usr/bin/python3` anywhere: it is a stub
  that a plain Xcode install can gate. The candidate list lives in three places
  that cannot import each other (`pythonCandidates` in `Model.swift`,
  `integrations/agent-session-bookmark.sh`, `install.sh`);
  `test_interpreter_candidates.py` fails if they drift apart. Tests:
  `python3 -m unittest`. Set `ASB_HOME` and `ASB_CACHE_DIR` to scratch folders
  when running the scripts by hand so you do not touch the user's bookmarks.
- Never wait on a subprocess without a deadline: use `runBounded` in
  `Model.swift`. A `waitUntilExit` or a blocking pipe read is unbounded, and one
  stuck child stops the panel refreshing for the rest of the process's life.
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
- There are no Swift tests. Check panel lifetime with `SW_PANEL_TRACE=1`, which
  logs `panels`, `windows` and `renders` once a second: `renders` must grow by
  `panels` per refresh, or a retired panel is still observing the feed. Retiring
  a panel means `retire()` in `main.swift`, not just dropping the reference.

## Decisions to keep

- Resume copies a command to the clipboard; it does not launch a terminal.
- Live sessions have no resume action.
- No third-party widget hosts or dependencies: the content is sensitive.
- Bookmark state lives in `~/Library/Application Support/Agent Session Bookmark/`,
  never in the repo.
