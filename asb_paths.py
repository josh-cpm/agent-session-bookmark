"""asb_paths.py — where Agent Session Bookmark keeps its files, and the user config.

Everything user-specific lives under one folder so it is easy to find, back up,
or wipe:

  ~/Library/Application Support/Agent Session Bookmark/
      flags.json      "Return to" bookmarks (see flag.py)
      config.json     optional user settings (see DEFAULT_CONFIG)

The parse cache goes to ~/Library/Caches/dev.agent-session-bookmark/.

Override the folders with environment variables (used by the tests and by the
installer's self-check): ASB_HOME for the support folder, ASB_CACHE_DIR for the
cache. Stdlib only.
"""

import json
import os

HOME = os.path.expanduser("~")
APP_NAME = "Agent Session Bookmark"
BUNDLE_ID = "dev.agent-session-bookmark"

SUPPORT_DIR = os.environ.get("ASB_HOME") or os.path.join(HOME, "Library", "Application Support", APP_NAME)
CACHE_DIR = os.environ.get("ASB_CACHE_DIR") or os.path.join(HOME, "Library", "Caches", BUNDLE_ID)
FLAGS_PATH = os.path.join(SUPPORT_DIR, "flags.json")
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")

# Agent data stores this tool reads (never writes).
CLAUDE_DIR = os.path.join(HOME, ".claude")
CLAUDE_PROJECTS = os.path.join(CLAUDE_DIR, "projects")           # <cwd-slug>/<session-id>.jsonl
CLAUDE_LIVE = os.path.join(CLAUDE_DIR, "sessions")               # <pid>.json for running processes
CLAUDE_DESKTOP_SESSIONS = os.path.join(HOME, "Library", "Application Support", "Claude", "claude-code-sessions")
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
CODEX_SESSIONS = os.path.join(CODEX_HOME, "sessions")            # <y>/<m>/<d>/rollout-*.jsonl
CODEX_IMPORTS = os.path.join(CODEX_HOME, "external_agent_session_imports.json")

DEFAULT_CONFIG = {
    # Sessions whose working directory is one of these are hidden (automation,
    # scheduled jobs, anything that is not you). Paths may start with "~".
    "ignore_cwds": [],
    # How far back the "Recent" list reaches, in days. Bookmarked and live
    # sessions are always shown regardless.
    "days": 7,
    # Maximum rows in the feed.
    "max_sessions": 60,
}


def load_config(path=CONFIG_PATH):
    """DEFAULT_CONFIG overlaid with the user's config.json (missing or invalid = defaults)."""
    config = dict(DEFAULT_CONFIG)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            user = json.load(handle)
    except (OSError, ValueError):
        return config
    if isinstance(user, dict):
        for key in DEFAULT_CONFIG:
            if key in user:
                config[key] = user[key]
    config["ignore_cwds"] = [os.path.expanduser(str(p)).rstrip("/") for p in config.get("ignore_cwds") or []]
    return config
