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

# /usr/bin/python3 is a stub that forwards to whichever toolchain
# `xcode-select -p` names, and refuses to run until that toolchain's licence has
# been accepted — so installing Xcode can break it. Use the first interpreter
# that actually runs, not the first one that merely exists. The toolchain paths
# are the real framework binaries the stub forwards to, so they keep working
# while the licence gate is up. Keep this list in step with `pythonCandidates`
# in AgentSessionBookmark/Model.swift and the copy in install.sh:
# test_interpreter_candidates.py fails if the three drift apart.
ASB_PYTHON_CANDIDATES="/opt/homebrew/bin/python3
/usr/local/bin/python3
/Library/Developer/CommandLineTools/usr/bin/python3
/Applications/Xcode.app/Contents/Developer/usr/bin/python3
/usr/bin/python3"

PY=""
# ASB_PYTHON has to be an absolute path, because the app can only use one: a
# bare command name would work here and be silently ignored there.
if [ -n "${ASB_PYTHON:-}" ]; then
  case "$ASB_PYTHON" in
    /*) if "$ASB_PYTHON" -c "" >/dev/null 2>&1; then PY="$ASB_PYTHON"
        else echo "agent-session-bookmark: ASB_PYTHON=$ASB_PYTHON did not run; ignoring it." >&2; fi ;;
    *)  echo "agent-session-bookmark: ASB_PYTHON=$ASB_PYTHON ignored; give an absolute path." >&2 ;;
  esac
fi
if [ -z "$PY" ]; then
  for c in $ASB_PYTHON_CANDIDATES; do
    if "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
if [ -z "$PY" ]; then
  echo "agent-session-bookmark: no working python3 found." >&2
  echo "If you just installed Xcode, accept its licence: sudo xcodebuild -license accept" >&2
  echo "Otherwise install the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

case "${1:-}" in
  feed) shift; exec "$PY" "$RES/sessions_feed.py" "$@" ;;
  config) shift; exec "$PY" "$RES/asb_config.py" "$@" ;;
  handoff) shift; exec "$PY" "$RES/handoff.py" "$@" ;;
  open) exec open "$APP" ;;
  *)    exec "$PY" "$RES/flag.py" "$@" ;;
esac
