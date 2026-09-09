---
name: agent-session-bookmark
description: Change or inspect Agent Session Bookmark settings (the desktop panel of Claude Code and Codex sessions) - history range in days, row cap, hidden folders, window mode (desktop / floating / normal), agent tags, preview length - and troubleshoot the panel. Use when the user mentions the session panel, session widget, Agent Session Bookmark, or asks to change how many days it shows, make it float, hide a folder's sessions, or asks why it is not showing something.
---
Agent Session Bookmark is a macOS desktop panel listing recent Claude Code and
Codex sessions. All of its settings live in one JSON file and are changed with
this CLI; the panel applies changes within a second or two, no restart needed.

CLI: `__ASB_CLI__`

The CLI writes to ~/Library/Application Support, outside the workspace, so if
the sandbox blocks a `config set`, rerun it with escalated permissions; that is
expected and safe.

Settings (`__ASB_CLI__ config keys` prints this list with defaults):

| key | meaning | values |
| --- | --- | --- |
| `days` | history shown in the Recent list | 1-365, default 7 |
| `max_sessions` | maximum rows | 1-500, default 60 |
| `ignore_cwds` | folders whose sessions are hidden | list of paths, `~` allowed |
| `window` | how the panel sits | `desktop` (below windows, like a widget), `floating` (always on top), `normal` |
| `agent_tags` | Claude / Codex tags on rows | `auto` (only when both appear), `always`, `never` |
| `preview_turns` | turns shown when a row is expanded | 1-6, default 3 |

Commands:

    __ASB_CLI__ config show                      # effective settings as JSON
    __ASB_CLI__ config set days 14
    __ASB_CLI__ config set window floating
    __ASB_CLI__ config add ignore_cwds ~/dev/bots  # append to the list
    __ASB_CLI__ config remove ignore_cwds ~/dev/bots
    __ASB_CLI__ config unset days                # back to the default

How to work:
1. Map the request to a key and value from the table. If the request is
   ambiguous (for example "show more"), ask which setting they mean, or pick the
   obvious one and say what you chose.
2. Run the `config set` (or add/remove/unset) command. A bad value exits 2 with
   the reason on stderr; relay it and fix the value.
3. Run `config show` and confirm in one or two sentences what changed and that
   the panel updates on its own.

Other useful commands for questions about the panel:

    __ASB_CLI__ list            # current bookmarks (JSON)
    __ASB_CLI__ feed            # the JSON the panel renders (what it "sees")
    __ASB_CLI__ add --current   # bookmark this session (the $bookmark skill does this)
    __ASB_CLI__ open            # reopen the panel if it was quit

Do not edit config.json by hand when the CLI can do it; the CLI validates values.
