"""transcripts.py — small helpers for reading Claude Code transcript files.

Claude Code stores each session as ~/.claude/projects/<cwd-slug>/<id>.jsonl, one
JSON object per line. These helpers pull the human-readable text out of a line
and skip the injected context (system reminders, command output caveats) that
is not part of the conversation. Stdlib only.
"""

import datetime as dt
import glob
import json
import os

import asb_paths

# Text blocks that Claude Code injects into the transcript but that a reader
# would not consider part of the conversation.
NOISE_PREFIXES = (
    "<local-command-caveat>",
    "<local-command-stdout>",
    "<command-name>",
    "<system-reminder>",
    "<task-notification>",
    "Caveat: The messages below were generated",
)


def parse_ts(value):
    """ISO-8601 string (with Z or offset) -> aware datetime, or None."""
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def clean(text):
    text = text.strip()
    if not text:
        return ""
    for prefix in NOISE_PREFIXES:
        if text.startswith(prefix):
            return ""
    return text


def extract_text(message):
    """Visible text of a transcript `message` (string content or text blocks)."""
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return clean(content)
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            piece = clean(block.get("text", ""))
            if piece:
                parts.append(piece)
    return "\n".join(parts)


def one_line(text, limit):
    text = " ".join(text.split())
    if len(text) > limit:
        text = text[:limit].rstrip() + "…"
    return text


def desktop_titles(sessions_dir=asb_paths.CLAUDE_DESKTOP_SESSIONS):
    """cliSessionId -> title for sessions started from the Claude desktop app."""
    mapping = {}
    for path in glob.glob(os.path.join(sessions_dir, "*", "*", "local_*.json")):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        if data.get("cliSessionId"):
            mapping[data["cliSessionId"]] = data.get("title")
    return mapping
