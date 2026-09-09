#!/bin/zsh
# Agent Session Bookmark installer.
#
#   ./install.sh            build, install the app, start it at login, and add the
#                           /bookmark and /handoff commands (Claude Code), the $bookmark
#                           and $handoff skills (Codex), and a settings skill for both
#   ./install.sh --check    report what is present and what is missing; change nothing
#   ./install.sh --remove   undo everything the installer did (bookmarks are kept)
#
# Everything the installer touches is listed at the end of a run. Locations can be
# overridden with environment variables, which the self-test uses to install into a
# scratch folder:
#   ASB_APP_DIR         where the .app goes           (default /Applications, else ~/Applications)
#   ASB_BIN_DIR         where the CLI wrapper goes    (default ~/.local/bin)
#   ASB_LAUNCH_AGENTS   LaunchAgents folder           (default ~/Library/LaunchAgents)
#   ASB_LOG_DIR         launchd log folder            (default ~/Library/Logs/Agent Session Bookmark)
#   ASB_CLAUDE_DIR      Claude Code home              (default ~/.claude)
#   ASB_CODEX_DIR       Codex home                    (default $CODEX_HOME or ~/.codex)
#   ASB_HOME            bookmark store                (default ~/Library/Application Support/Agent Session Bookmark)
#   ASB_NO_LAUNCHCTL=1  skip launchctl calls (self-test)
set -euo pipefail

HERE="${0:A:h}"
APP_NAME="Agent Session Bookmark"
LABEL="dev.agent-session-bookmark"
CLI_NAME="agent-session-bookmark"
BIN_NAME="AgentSessionBookmark"

APP_DIR="${ASB_APP_DIR:-}"
if [[ -z "$APP_DIR" ]]; then
  if [[ -w /Applications ]]; then APP_DIR=/Applications; else APP_DIR="$HOME/Applications"; fi
fi
APP="$APP_DIR/$APP_NAME.app"
BIN_DIR="${ASB_BIN_DIR:-$HOME/.local/bin}"
CLI="$BIN_DIR/$CLI_NAME"
LAUNCH_AGENTS="${ASB_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
LOG_DIR="${ASB_LOG_DIR:-$HOME/Library/Logs/$APP_NAME}"
CLAUDE_DIR="${ASB_CLAUDE_DIR:-$HOME/.claude}"
CODEX_DIR="${ASB_CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
SUPPORT_DIR="${ASB_HOME:-$HOME/Library/Application Support/$APP_NAME}"
CLAUDE_CMD="$CLAUDE_DIR/commands/bookmark.md"
CLAUDE_HANDOFF="$CLAUDE_DIR/commands/handoff.md"
CODEX_HANDOFF="$CODEX_DIR/skills/handoff/SKILL.md"
CLAUDE_SETTINGS_SKILL="$CLAUDE_DIR/skills/agent-session-bookmark/SKILL.md"
CODEX_SKILL="$CODEX_DIR/skills/bookmark/SKILL.md"
CODEX_SETTINGS_SKILL="$CODEX_DIR/skills/agent-session-bookmark/SKILL.md"
UID_="$(id -u)"

ok()   { print -r -- "  ✓ $1"; }
miss() { print -r -- "  ✗ $1"; }
note() { print -r -- "  · $1"; }
lctl() { [[ "${ASB_NO_LAUNCHCTL:-}" == "1" ]] || launchctl "$@"; }
quit() { [[ "${ASB_NO_LAUNCHCTL:-}" == "1" ]] || pkill -x "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------ check
check() {
  local problems=0
  echo "Requirements"
  local osv; osv="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  if [[ "${osv%%.*}" -ge 14 ]]; then ok "macOS $osv (14 or newer needed)"; else miss "macOS $osv: needs 14 or newer"; problems=1; fi
  if command -v swiftc >/dev/null 2>&1; then ok "Swift compiler: $(swiftc --version 2>&1 | head -1)"
  else miss "swiftc not found: run  xcode-select --install  (Xcode Command Line Tools)"; problems=1; fi
  if [[ -x /usr/bin/python3 ]]; then ok "/usr/bin/python3: $(/usr/bin/python3 --version 2>&1)"
  else miss "/usr/bin/python3 missing (comes with the Command Line Tools)"; problems=1; fi

  echo "Agent data on this Mac"
  if [[ -d "$CLAUDE_DIR/projects" ]]; then
    ok "Claude Code transcripts: $(find "$CLAUDE_DIR/projects" -name '*.jsonl' -mtime -7 2>/dev/null | wc -l | tr -d ' ') sessions in the last 7 days"
  else note "no Claude Code data at $CLAUDE_DIR/projects (the /bookmark command will still be installed if $CLAUDE_DIR exists)"; fi
  if [[ -d "$CODEX_DIR/sessions" ]]; then
    ok "Codex rollouts: $(find "$CODEX_DIR/sessions" -name 'rollout-*.jsonl' -mtime -7 2>/dev/null | wc -l | tr -d ' ') in the last 7 days"
  else note "no Codex data at $CODEX_DIR/sessions"; fi

  echo "Installed pieces"
  [[ -d "$APP" ]] && ok "app: $APP" || note "app not installed ($APP)"
  [[ -x "$CLI" ]] && ok "CLI: $CLI" || note "CLI not installed ($CLI)"
  if [[ -f "$PLIST" ]]; then
    local state; state="$(launchctl print "gui/$UID_/$LABEL" 2>/dev/null | awk '/state =/{print $3}' || true)"
    ok "login item: $PLIST (${state:-not loaded})"
  else note "login item not installed"; fi
  [[ -f "$CLAUDE_CMD" ]] && grep -q "$CLI_NAME" "$CLAUDE_CMD" && ok "Claude Code /bookmark: $CLAUDE_CMD" || note "Claude Code /bookmark not installed"
  [[ -f "$CLAUDE_HANDOFF" ]] && grep -q "$CLI_NAME" "$CLAUDE_HANDOFF" && ok "Claude Code /handoff: $CLAUDE_HANDOFF" || note "Claude Code /handoff not installed"
  [[ -f "$CLAUDE_SETTINGS_SKILL" ]] && ok "Claude Code settings skill: $CLAUDE_SETTINGS_SKILL" || note "Claude Code settings skill not installed"
  [[ -f "$CODEX_SKILL" ]] && ok "Codex \$bookmark skill: $CODEX_SKILL" || note "Codex \$bookmark skill not installed"
  [[ -f "$CODEX_HANDOFF" ]] && ok "Codex \$handoff skill: $CODEX_HANDOFF" || note "Codex \$handoff skill not installed"
  [[ -f "$CODEX_SETTINGS_SKILL" ]] && ok "Codex settings skill: $CODEX_SETTINGS_SKILL" || note "Codex settings skill not installed"
  [[ -f "$SUPPORT_DIR/flags.json" ]] && ok "bookmarks: $SUPPORT_DIR/flags.json" || note "no bookmarks yet ($SUPPORT_DIR/flags.json)"
  return $problems
}

# ------------------------------------------------------------------ remove
remove() {
  lctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  quit "$BIN_NAME"
  rm -rf "$APP"
  rm -f "$CLI"
  for cmd in "$CLAUDE_CMD" "$CLAUDE_HANDOFF"; do
    if [[ -f "$cmd" ]] && grep -q "$CLI_NAME" "$cmd"; then rm -f "$cmd"; fi
  done
  for skill in "$CLAUDE_SETTINGS_SKILL" "$CODEX_SKILL" "$CODEX_HANDOFF" "$CODEX_SETTINGS_SKILL"; do
    if [[ -f "$skill" ]] && grep -q "$CLI_NAME" "$skill"; then rm -rf "$(dirname "$skill")"; fi
  done
  echo "removed $APP_NAME (app, login item, CLI, /bookmark command, skills)."
  echo "kept your bookmarks and config in: $SUPPORT_DIR"
}

# ------------------------------------------------------------------ install
render() {  # render <template> <dest>
  sed -e "s|__ASB_APP__|$APP|g" -e "s|__ASB_CLI__|$CLI|g" -e "s|__ASB_LOG_DIR__|$LOG_DIR|g" "$1" > "$2"
}

install_all() {
  echo "Checking requirements…"
  if ! check; then
    echo; echo "fix the items marked ✗ above, then run ./install.sh again" >&2
    exit 1
  fi
  echo
  "$HERE/build.sh"

  echo "installing…"
  quit "$BIN_NAME"
  mkdir -p "$APP_DIR" "$BIN_DIR" "$LAUNCH_AGENTS" "$LOG_DIR" "$SUPPORT_DIR"
  rsync -a --delete "$HERE/build/$APP_NAME.app/" "$APP/"
  ok "app: $APP"

  render "$HERE/integrations/agent-session-bookmark.sh" "$CLI"
  chmod +x "$CLI"
  ok "CLI: $CLI"

  render "$HERE/integrations/launchd.plist" "$PLIST"
  lctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  lctl bootstrap "gui/$UID_" "$PLIST"
  lctl kickstart "gui/$UID_/$LABEL" 2>/dev/null || true   # RunAtLoad alone does not start it on bootstrap
  ok "login item: $PLIST"

  if [[ -d "$CLAUDE_DIR" ]] || command -v claude >/dev/null 2>&1; then
    mkdir -p "$(dirname "$CLAUDE_CMD")"
    if [[ -f "$CLAUDE_CMD" ]] && ! grep -q "$CLI_NAME" "$CLAUDE_CMD"; then
      mv "$CLAUDE_CMD" "$CLAUDE_CMD.bak"; note "kept your previous bookmark.md as bookmark.md.bak"
    fi
    render "$HERE/integrations/claude-bookmark.md" "$CLAUDE_CMD"
    ok "Claude Code: /bookmark  ($CLAUDE_CMD)"
    if [[ -f "$CLAUDE_HANDOFF" ]] && ! grep -q "$CLI_NAME" "$CLAUDE_HANDOFF"; then
      mv "$CLAUDE_HANDOFF" "$CLAUDE_HANDOFF.bak"; note "kept your previous handoff.md as handoff.md.bak"
    fi
    render "$HERE/integrations/claude-handoff.md" "$CLAUDE_HANDOFF"
    ok "Claude Code: /handoff  ($CLAUDE_HANDOFF)"
    mkdir -p "$(dirname "$CLAUDE_SETTINGS_SKILL")"
    render "$HERE/integrations/claude-settings-SKILL.md" "$CLAUDE_SETTINGS_SKILL"
    ok "Claude Code: settings skill  ($CLAUDE_SETTINGS_SKILL)"
  else
    note "Claude Code not found ($CLAUDE_DIR); skipped /bookmark"
  fi

  if [[ -d "$CODEX_DIR" ]] || command -v codex >/dev/null 2>&1; then
    mkdir -p "$(dirname "$CODEX_SKILL")"
    render "$HERE/integrations/codex-SKILL.md" "$CODEX_SKILL"
    ok "Codex: \$bookmark  ($CODEX_SKILL)"
    mkdir -p "$(dirname "$CODEX_HANDOFF")"
    render "$HERE/integrations/codex-handoff-SKILL.md" "$CODEX_HANDOFF"
    ok "Codex: \$handoff  ($CODEX_HANDOFF)"
    mkdir -p "$(dirname "$CODEX_SETTINGS_SKILL")"
    render "$HERE/integrations/codex-settings-SKILL.md" "$CODEX_SETTINGS_SKILL"
    ok "Codex: settings skill  ($CODEX_SETTINGS_SKILL)"
  else
    note "Codex not found ($CODEX_DIR); skipped \$bookmark"
  fi

  echo
  echo "verifying…"
  local failed=0
  if [[ "${ASB_NO_LAUNCHCTL:-}" != "1" ]]; then
    # Give it time to load the feed and receive its first file events; a crash
    # loop shows up as a changing pid or no process at all.
    sleep 6
    local pid1; pid1="$(pgrep -x "$BIN_NAME" | head -1)"
    sleep 2
    local pid2; pid2="$(pgrep -x "$BIN_NAME" | head -1)"
    if [[ -n "$pid1" && "$pid1" == "$pid2" ]]; then ok "app is running (pid $pid1, stable for 8 s)"
    elif [[ -n "$pid2" ]]; then miss "app is restarting (pid changed $pid1 -> $pid2); check ~/Library/Logs/DiagnosticReports for AgentSessionBookmark-*.ips"; failed=1
    else miss "app is not running; see $LOG_DIR/launchd.err and ~/Library/Logs/DiagnosticReports"; failed=1; fi
  fi
  if "$CLI" list >/dev/null 2>&1; then ok "CLI works: $CLI list"; else miss "CLI failed: $CLI list"; failed=1; fi
  if "$CLI" config show >/dev/null 2>&1; then ok "settings work: $CLI config show"; else miss "settings failed: $CLI config show"; failed=1; fi
  if ASB_CACHE_DIR="$(mktemp -d)" "$CLI" feed --no-cache >/dev/null 2>&1; then ok "feed works: $CLI feed"
  else miss "feed failed: run  $CLI feed  to see the error"; failed=1; fi

  echo
  echo "Installed. Summary:"
  echo "  app          $APP"
  echo "  login item   $PLIST"
  echo "  CLI          $CLI"
  echo "  bookmarks    $SUPPORT_DIR/flags.json"
  echo "  config       $SUPPORT_DIR/config.json (optional; see README)"
  [[ -f "$CLAUDE_CMD" ]] && echo "  Claude Code  /bookmark [note] and /handoff [note] inside any session; ask Claude to change panel settings"
  [[ -f "$CODEX_SKILL" ]] && echo "  Codex        \$bookmark [note] and \$handoff [note] inside any session; ask Codex to change panel settings"
  echo "  settings     $CLI config keys"
  echo "  logs         $LOG_DIR"
  echo "  uninstall    $HERE/install.sh --remove"
  return $failed
}

case "${1:-}" in
  --check)  check ;;
  --remove) remove ;;
  "")       install_all ;;
  *) echo "usage: install.sh [--check|--remove]" >&2; exit 2 ;;
esac
