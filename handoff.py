#!/usr/bin/env python3
"""handoff.py — write a paste-ready brief so another agent can pick up a session.

Given a Claude Code or Codex session, prints instructions a person can paste
into a fresh agent (Claude Code, Codex, or anything else that can read a file):
where the transcript is, the working folder, the goal, the latest turns, and an
optional note from the person handing it off.

Usage:
  handoff.py <session-id> [--copy] [note...]
  handoff.py --current   [--copy] [note...]     the session this shell runs in
  --copy also puts the text on the clipboard (pbcopy).

Exit status 1 with a message on stderr if the session cannot be found. Stdlib only.
"""

import datetime as dt
import glob
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asb_paths  # noqa: E402
import flag  # noqa: E402
import sessions_feed as feed  # noqa: E402
import transcripts as uw  # noqa: E402

GOAL_CHARS = 600
TURN_CHARS = 900
LAST_TURNS = 4


def find_transcript(sid, projects_dir=asb_paths.CLAUDE_PROJECTS, codex_dir=asb_paths.CODEX_SESSIONS):
    """(agent, path) for a session id, or (None, None)."""
    claude = glob.glob(os.path.join(projects_dir, "*", f"{sid}.jsonl"))
    if claude:
        return "claude", claude[0]
    codex = glob.glob(os.path.join(codex_dir, "*", "*", "*", f"rollout-*{sid}.jsonl"))
    if codex:
        return "codex", codex[0]
    return None, None


def describe(sid, agent, path, titles=None):
    """Parse the transcript and return the facts the brief needs."""
    state = feed.advance(feed.fresh_state(agent), path)
    titles = titles if titles is not None else (uw.desktop_titles() if agent == "claude" else {})
    if agent == "claude":
        title = (state["custom_title"] or titles.get(sid) or state["title"]
                 or uw.one_line(state["goal"] or "", feed.TITLE_CHARS) or "(untitled)")
    else:
        title = uw.one_line(state["goal"] or "", feed.TITLE_CHARS) or "(untitled)"
    return {
        "id": sid,
        "agent": agent,
        "path": path,
        "title": title,
        "cwd": state["cwd"] or "",
        "goal": (state["goal"] or "").strip(),
        "turns": state["turns"][-LAST_TURNS:],
        "last_ts": state["last_ts"],
        "resume_cmd": feed.resume_command(state["cwd"] or "", sid, "codex resume" if agent == "codex" else "claude --resume"),
    }


def when(ts, now=None):
    parsed = uw.parse_ts(ts)
    if not parsed:
        return "unknown time"
    local = parsed.astimezone()
    now = now or dt.datetime.now().astimezone()
    if local.date() == now.date():
        return "today at " + local.strftime("%-I:%M %p")
    return local.strftime("%b %-d, %Y at %-I:%M %p")


def render(info, note="", now=None):
    agent_name = "Codex" if info["agent"] == "codex" else "Claude Code"
    if info["agent"] == "codex":
        fmt = ("It is a Codex rollout: JSONL, one event per line. The conversation is in "
               "`response_item` lines whose payload is a `message` with role `user` or `assistant`; "
               "ignore `<environment_context>` and other injected blocks.")
    else:
        fmt = ("It is a Claude Code transcript: JSONL, one message per line with `type` `user` or "
               "`assistant`. Skip lines marked `isSidechain` or `isMeta`, and skip text that starts "
               "with `<system-reminder>` or `<local-command-`.")
    lines = [
        f"I want you to resume the session found at {info['path']}",
        "",
        f"That is a {agent_name} session titled \"{info['title']}\", last active {when(info['last_ts'], now)}"
        + (f", working in {info['cwd']}." if info["cwd"] else "."),
        fmt,
        "",
        "Read the whole transcript first so you have the full context: the goal, what was tried, "
        "what was decided, and what was left unfinished. Then summarize in a few sentences where "
        "things stand and continue the work from there"
        + (f", working in {info['cwd']}." if info["cwd"] else "."),
    ]
    if note.strip():
        lines += ["", f"Handoff note from me: {note.strip()}"]
    if info["goal"]:
        lines += ["", "The original ask, from the first prompt:", quote(uw.one_line(info["goal"], GOAL_CHARS))]
    if info["turns"]:
        lines += ["", f"Where it left off (last {len(info['turns'])} turns):"]
        for turn in info["turns"]:
            who = "Me" if turn["role"] == "user" else agent_name
            lines.append(f"{who}: {uw.one_line(turn['text'], TURN_CHARS)}")
    lines += ["", f"If you are {agent_name} yourself, you can instead resume the session in place with:",
              f"    {info['resume_cmd']}"]
    return "\n".join(lines) + "\n"


def quote(text):
    return "> " + text


def copy_to_clipboard(text):
    try:
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True, timeout=5)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def main(argv):
    args = [a for a in argv[1:] if a != "--copy"]
    copy = "--copy" in argv[1:]
    if not args:
        sys.stderr.write(__doc__)
        return 2
    sid = args[0]
    if sid == "--current":
        found = flag.current_session()
        if not found:
            sys.stderr.write(flag.NOT_FOUND + "\n")
            return 1
        sid = found[1]
    note = " ".join(args[1:])
    agent, path = find_transcript(sid)
    if not path:
        sys.stderr.write(f"no Claude Code or Codex transcript found for session {sid}\n")
        return 1
    text = render(describe(sid, agent, path), note)
    if copy:
        copy_to_clipboard(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
