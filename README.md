# Agent Session Bookmark

A small native macOS desktop panel that lists your recent **Claude Code** and
**Codex** sessions, shows which are live right now, previews the last few turns,
and copies a resume command for any ended session. Bookmark a session you want
to come back to after a reboot, from the panel or from inside the session itself
with `/bookmark` (Claude Code) or `$bookmark` (Codex).

No third-party dependencies: a SwiftUI app compiled with the Xcode Command Line
Tools plus a stdlib-only Python feed. Everything is read from the transcript
files the agents already keep on disk. Nothing leaves your Mac.

## Install

Requirements: macOS 14 or newer, the Xcode Command Line Tools
(`xcode-select --install`, which provides `swiftc` and `/usr/bin/python3`), and
Claude Code and/or Codex installed for the user.

### With Claude Code or Codex doing the install

Clone this repository, open Claude Code or Codex in the cloned folder, and say:

> Install Agent Session Bookmark for me. Follow INSTALL.md.

The agent reads `INSTALL.md`, runs the pre-flight check, fixes anything missing
(usually just the Command Line Tools), runs the installer, and verifies the
result. It can also adjust the optional config for you.

### By hand

```sh
git clone https://github.com/josh-cpm/agent-session-bookmark.git agent-session-bookmark
cd agent-session-bookmark
./install.sh --check     # what is present, what is missing; changes nothing
./install.sh             # build, install, start at login, add /bookmark and $bookmark
```

`./install.sh --remove` undoes everything except your bookmarks.

## What you get

| Piece | Where |
| --- | --- |
| The panel | `/Applications/Agent Session Bookmark.app`, started at login by a LaunchAgent (`dev.agent-session-bookmark`) |
| `/bookmark [note]` in Claude Code | `~/.claude/commands/bookmark.md` |
| `$bookmark [note]` in Codex | `~/.codex/skills/bookmark/SKILL.md` (Codex has no user-defined `/` commands; `$name` is how it invokes a skill) |
| CLI | `~/.local/bin/agent-session-bookmark` (`add --current [note]`, `add <id> [note]`, `remove <id>`, `list`, `current`, `feed`, `open`) |
| Bookmarks and config | `~/Library/Application Support/Agent Session Bookmark/` |
| Logs | `~/Library/Logs/Agent Session Bookmark/` |

## Using the panel

- One row per session from the last 7 days, live sessions first, then newest
  first: title, project folder, time of the last message. Codex rows carry a
  teal "Codex" tag.
- Status dot: **green** = live and idle (waiting for you), **orange** = live and
  working, **grey** = ended.
- Click a row to expand it: the last three turns, then either "Copy resume
  command" (ended sessions) or a live-status line. The copied command is
  `cd <project> && claude --resume <id>` or `codex resume <id>`; paste it into
  any terminal.
- **Return to**: hover a row and click its bookmark icon, or type `/bookmark`
  (Claude Code) or `$bookmark` (Codex) inside the session, optionally with a
  note. Bookmarked sessions sit in a pinned group at the top and stay listed
  however old they get. A Claude bookmark clears itself once you resume the
  session in a new process; a Codex bookmark clears when the session is live
  again with new activity. Click the bookmark icon to clear one by hand.
- The `⋯` menu (or right-click) switches window mode: **Sit on the desktop**
  (default, like a widget: above the wallpaper, below other windows), **Float
  above windows**, or **Normal window**. Position, size, and mode persist.
- Quit from the `⋯` menu. Reopen from Launchpad or Spotlight, or with
  `agent-session-bookmark open`.

## Config (optional)

Create `~/Library/Application Support/Agent Session Bookmark/config.json`:

```json
{
  "ignore_cwds": ["~/dev/scheduled-jobs"],
  "days": 7,
  "max_sessions": 60
}
```

- `ignore_cwds`: hide sessions whose working directory is one of these (for
  example folders where automation runs agents on your behalf).
- `days`: how far back the Recent list reaches. Live and bookmarked sessions are
  always shown.
- `max_sessions`: cap on rows.

The panel picks up changes on its next refresh (within a minute).

## How it works

- **Claude Code sessions** are `~/.claude/projects/<cwd>/<id>.jsonl`. Title comes
  from a `/rename` custom title, the desktop app's session metadata, the
  transcript's AI title, or the first prompt. Subagent and injected-context
  lines are skipped.
- **Live status** comes from `~/.claude/sessions/<pid>.json`, which Claude Code
  writes for each running process with the session id and a `busy`/`idle`
  status. The feed checks the pid is still alive, so stale records do not count.
- **Codex sessions** are `~/.codex/sessions/<y>/<m>/<d>/rollout-*.jsonl`. Codex
  Desktop imports Claude transcripts into that store and forks them, so
  imported, forked-from-import, and subagent rollouts are skipped. A Codex
  session is live when a running codex process holds its rollout open.
- **Which session am I in?** The `/bookmark` command runs
  `agent-session-bookmark add --current`. In Claude Code it reads the
  `CLAUDE_CODE_SESSION_ID` variable Claude Code exports, falling back to the
  live record of the parent process. In Codex, whose sandbox blocks `ps` and
  `lsof`, it reads the rollouts directly: Codex logs the tool call before
  running it, so the rollout whose tail contains this command is the current
  session (then: same working directory, then the only recent rollout).
  `agent-session-bookmark current` shows what it finds and how.
- **Refresh**: the panel watches the transcript folders with FSEvents (debounced
  to at most every 8 s) and also refreshes every 60 s. Transcripts are parsed
  incrementally with a cache in `~/Library/Caches/dev.agent-session-bookmark/`.

## Development

```sh
python3 -m unittest            # feed, flags, config, session resolution
./build.sh --run               # build into ./build and relaunch
```

Snapshot the panel to a PNG without screen-recording permission:

```sh
SW_SNAPSHOT=/tmp/panel.png SW_HEIGHT=700 "build/Agent Session Bookmark.app/Contents/MacOS/AgentSessionBookmark"
```

Add `SW_EXPAND=<row index>` to open a row first. `ASB_HOME=<dir>` points the
scripts at a different bookmark store; `ASB_CACHE_DIR` moves the cache.

| Path | Role |
| --- | --- |
| `sessions_feed.py` | Emits the JSON feed the panel renders. |
| `flag.py` | Bookmark store and current-session resolution. |
| `transcripts.py`, `asb_paths.py` | Transcript text helpers; paths and config. |
| `AgentSessionBookmark/` | Swift sources (`Model.swift` feed runner + watcher, `Views.swift` UI, `main.swift` panel) and `Info.plist`. |
| `integrations/` | Templates the installer renders: the Claude command, the Codex skill, the LaunchAgent, the CLI wrapper. |
| `build.sh`, `install.sh` | Build the bundle (scripts ship inside it); install, check, remove. |
| `INSTALL.md` | The runbook an installing agent follows. |

## Known limits

- Claude Code and Codex only. Cowork and claude.ai chats are not shown (the
  latter are not on disk at all).
- Resume copies a command to the clipboard by design; it does not open a
  terminal.
- Codex's sandbox may ask you to approve the `$bookmark` command once per
  session, because it writes outside the workspace. Approving is expected.
- No signed binary is distributed. Clone and build; the Command Line Tools
  compile it in a few seconds.
