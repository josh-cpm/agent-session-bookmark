#!/bin/sh
# agent-session-bookmark — command-line entry point, written by install.sh.
#
#   agent-session-bookmark add --current [note]   bookmark the session this shell runs in
#   agent-session-bookmark add <id> [note]        bookmark a session by id
#   agent-session-bookmark remove <id>            remove a bookmark
#   agent-session-bookmark list                   bookmarks as JSON
#   agent-session-bookmark current                which session this shell belongs to
#   agent-session-bookmark feed [--no-cache]      the JSON feed the panel shows
#   agent-session-bookmark config show|get|set|add|remove|unset|keys|path   settings
#   agent-session-bookmark handoff <id>|--current [--copy] [note]   brief for handing a session to another agent
#   agent-session-bookmark open                   open (or re-open) the panel
APP="__ASB_APP__"
RES="$APP/Contents/Resources"
case "${1:-}" in
  feed) shift; exec /usr/bin/python3 "$RES/sessions_feed.py" "$@" ;;
  config) shift; exec /usr/bin/python3 "$RES/asb_config.py" "$@" ;;
  handoff) shift; exec /usr/bin/python3 "$RES/handoff.py" "$@" ;;
  open) exec open "$APP" ;;
  *)    exec /usr/bin/python3 "$RES/flag.py" "$@" ;;
esac
