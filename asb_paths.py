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

# Every user-facing setting, with its default. config.json may override any of
# them; the panel, the feed, and the `agent-session-bookmark config` CLI all read
# this one file, and the panel applies changes as soon as the file is saved.
DEFAULT_CONFIG = {
    # How far back the "Recent" list reaches, in days. Bookmarked and live
    # sessions are always shown regardless.
    "days": 7,
    # Maximum rows in the list.
    "max_sessions": 60,
    # Sessions whose working directory is one of these are hidden (automation,
    # scheduled jobs, anything that is not you). Paths may start with "~".
    "ignore_cwds": [],
    # Window behaviour: "desktop" (sits above the wallpaper, below windows, like
    # a widget), "floating" (always on top) or "normal".
    "window": "desktop",
    # Claude / Codex tags on rows: "auto" (only when both agents appear),
    # "always" or "never".
    "agent_tags": "auto",
    # How many of the latest turns an expanded row shows (1-6).
    "preview_turns": 3,
}

SETTING_HELP = {
    "days": "days of history in the Recent list (1-365)",
    "max_sessions": "maximum rows (1-500)",
    "ignore_cwds": "folders whose sessions are hidden (list of paths, ~ allowed)",
    "window": "desktop | floating | normal",
    "agent_tags": "auto | always | never",
    "preview_turns": "turns shown in an expanded row (1-6)",
}

WINDOW_MODES = ("desktop", "floating", "normal")
TAG_MODES = ("auto", "always", "never")


def validate(key, value):
    """Return the normalized value for `key`, or raise ValueError with a readable reason."""
    if key not in DEFAULT_CONFIG:
        raise ValueError(f"unknown setting {key!r}; known: {', '.join(DEFAULT_CONFIG)}")
    if key in ("days", "max_sessions", "preview_turns"):
        lo, hi = {"days": (1, 365), "max_sessions": (1, 500), "preview_turns": (1, 6)}[key]
        try:
            number = int(value)
        except (TypeError, ValueError):
            raise ValueError(f"{key} must be a whole number between {lo} and {hi}")
        if not lo <= number <= hi:
            raise ValueError(f"{key} must be between {lo} and {hi}")
        return number
    if key == "window":
        if value not in WINDOW_MODES:
            raise ValueError(f"window must be one of {', '.join(WINDOW_MODES)}")
        return value
    if key == "agent_tags":
        if value not in TAG_MODES:
            raise ValueError(f"agent_tags must be one of {', '.join(TAG_MODES)}")
        return value
    if key == "ignore_cwds":
        if isinstance(value, str):
            value = [p for p in value.split(",")]
        if not isinstance(value, list) or not all(isinstance(p, str) for p in value):
            raise ValueError("ignore_cwds must be a list of paths")
        return [p.strip() for p in value if p.strip()]
    return value


def read_config_file(path=CONFIG_PATH):
    """The raw user config.json as a dict ({} if missing or invalid)."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            user = json.load(handle)
    except (OSError, ValueError):
        return {}
    return user if isinstance(user, dict) else {}


def write_config_file(user, path=CONFIG_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(user, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def load_config(path=CONFIG_PATH):
    """DEFAULT_CONFIG overlaid with the valid entries of the user's config.json.

    Invalid values fall back to the default rather than breaking the feed.
    ignore_cwds comes back expanded (~ resolved, trailing slash removed).
    """
    config = dict(DEFAULT_CONFIG)
    for key, value in read_config_file(path).items():
        if key not in DEFAULT_CONFIG:
            continue
        try:
            config[key] = validate(key, value)
        except ValueError:
            continue
    config["ignore_cwds"] = [os.path.expanduser(str(p)).rstrip("/") for p in config.get("ignore_cwds") or []]
    return config
