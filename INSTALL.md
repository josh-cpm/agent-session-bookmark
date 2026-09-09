# Installing Agent Session Bookmark (runbook for an agent or a person)

Follow these steps in order. Each has a way to verify it. Do not skip the
verification; report what you actually observed.

## 1. Pre-flight

```sh
./install.sh --check
```

Read the output. Lines marked `✗` block installation:

- **swiftc not found**: the Xcode Command Line Tools are missing. Tell the user
  to run `xcode-select --install` (it opens a system dialog; the download takes a
  few minutes) and rerun the check afterwards. Do not install full Xcode or any
  package manager for this.
- **macOS older than 14**: unsupported; stop and say so.

Lines marked `·` are informational. "no Claude Code data" or "no Codex data"
only means that agent has not been used on this Mac yet; the integration is still
installed if the agent's home folder exists.

If the check mentions the older "Session Bookmarker", the installer will import
its bookmarks, remove its login item, and move its app to the Trash.

## 2. Install

```sh
./install.sh
```

It builds the app (10 to 30 s), copies it to `/Applications` (or
`~/Applications` if `/Applications` is not writable), registers a LaunchAgent so
it starts at login, writes the CLI wrapper to `~/.local/bin`, and installs the
`/bookmark` command for Claude Code and the `$bookmark` skill for Codex. It ends
with a "verifying…" block and a summary of every path it touched.

Expected: every verifying line is `✓`, exit status 0, and the panel appears in
the top-right corner of the screen, sitting on the desktop behind other
windows. If the user has many windows open they may need to click the desktop
or hide windows to see it.

## 3. Verify the integrations

- **Claude Code**: in a new Claude Code session (existing sessions do not pick up
  new commands), type `/bookmark trying it out`. The reply should be one line
  confirming the bookmark, and the panel should show the session in a "Return
  to" group within a few seconds. Then clear it: click the bookmark icon on the
  row, or run `agent-session-bookmark remove <id>` with the id from
  `agent-session-bookmark list`.
- **Codex**: in a new Codex session, type `$bookmark trying it out`. Codex reads
  the skill and runs the command. Its sandbox may ask for approval because the
  bookmark store is outside the workspace; approve it. Verify in the panel the
  same way.
- **CLI**: `agent-session-bookmark current` from a shell inside either agent
  prints the session id and how it was found. Outside an agent it prints an
  error, which is correct.

If `~/.local/bin` is not on the user's PATH, the integrations still work (they
use the absolute path); only typing `agent-session-bookmark` by hand needs the
PATH entry. Mention it, do not edit shell profiles unasked.

## 4. Optional configuration

Ask whether the user wants any of these; if not, skip.

- Hide sessions run by automation: create
  `~/Library/Application Support/Agent Session Bookmark/config.json` with
  `{"ignore_cwds": ["~/path/to/automation"]}`.
- Change the window mode (desktop, floating, normal) from the panel's `⋯` menu.
- Avoid the Codex approval prompt for `$bookmark`: in `~/.codex/config.toml`,
  add the bookmark store to the writable roots of the workspace-write sandbox
  (`[sandbox_workspace_write] writable_roots = ["/Users/<name>/Library/Application Support/Agent Session Bookmark"]`).
  Only do this if the user asks; it widens the sandbox.

## Troubleshooting

- **Panel not visible after install**: `launchctl print gui/$(id -u)/dev.agent-session-bookmark`
  shows state and last exit status; `~/Library/Logs/Agent Session Bookmark/launchd.err`
  has the app's stderr. `open "/Applications/Agent Session Bookmark.app"` starts it by hand.
- **Panel shows an error instead of rows**: run `agent-session-bookmark feed --no-cache`
  and read the traceback. The feed reads `~/.claude/projects`, `~/.claude/sessions`,
  and `~/.codex/sessions`; a permissions problem on one of those is the usual cause.
- **`/bookmark` says it cannot determine the current session**: run
  `agent-session-bookmark current` from the agent's shell. In Claude Code, if
  `CLAUDE_CODE_SESSION_ID` is unset and no ancestor has a record in
  `~/.claude/sessions`, the Claude Code build is older than expected; report
  the version (`claude --version`). In Codex, resolution reads the newest
  rollouts under `~/.codex/sessions`; if that folder is elsewhere (custom
  `CODEX_HOME`), the CLI honors `CODEX_HOME` when it is set in the shell.
- **`/bookmark` not offered in Claude Code**: commands are read at session
  start; start a new session. Confirm `~/.claude/commands/bookmark.md` exists.
- **`$bookmark` not offered in Codex**: confirm `~/.codex/skills/bookmark/SKILL.md`
  exists and start a new session. `/skills` in Codex lists what it sees.
- **Build fails after a macOS or Xcode update**: `xcode-select -p` should point
  at a valid developer directory; `sudo xcode-select --reset` fixes a stale one
  (needs the user's approval, since it is sudo).

## Uninstall

```sh
./install.sh --remove
```

Removes the app, login item, CLI, command, and skill. Bookmarks and config in
`~/Library/Application Support/Agent Session Bookmark/` are kept; delete that
folder to remove them too.
