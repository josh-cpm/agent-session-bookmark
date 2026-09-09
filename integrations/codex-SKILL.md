---
name: bookmark
description: Bookmark the current Codex session in Agent Session Bookmark (the desktop panel) so it shows in the "Return to" list after a restart, with an optional note. Use when the user types $bookmark, "bookmark this session", or asks to flag this session to come back to later. Do not use for browser bookmarks or anything else.
---

Run this one command, passing any words the user gave as the note (`$ARGUMENTS`
may be empty):

    __ASB_CLI__ add --current $ARGUMENTS

It writes to the bookmark store in ~/Library/Application Support, which is
outside the workspace, so if the sandbox blocks it, rerun it with escalated
permissions; that is expected and safe. It resolves the current session by
looking at its parent Codex process, so run it directly, not inside a subagent.

Then reply with ONE short line: confirm the session is bookmarked, echo the note
if one was given, and mention the user can leave whenever ready. If the command
printed an error, quote it instead. Do nothing else.
