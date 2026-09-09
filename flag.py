#!/usr/bin/env python3
"""flag.py — mark agent sessions to return to after a restart.

Flags live in flags.json inside the support folder (see asb_paths.py):
  {"<session-id>": {"note": "...", "flagged_at": "<iso>"}}

Usage:
  flag.py add <session-id> [note...]     flag a session
  flag.py add --current [note...]        flag the Claude Code / Codex session this shell runs in
  flag.py remove <session-id>            unflag
  flag.py list                           print flags as JSON
  flag.py current                        print the current session id (diagnostic)

How --current finds the session, in order:
  1. CLAUDE_CODE_SESSION_ID, which Claude Code exports to the commands it runs.
  2. CLAUDE_PID (or CMUX_CLAUDE_PID) -> ~/.claude/sessions/<pid>.json -> sessionId.
  3. Walk up the parent processes of this script (ps). A Claude Code ancestor has
     a ~/.claude/sessions/<pid>.json record; a Codex ancestor holds its rollout
     file open (lsof).
  4. Codex from inside its sandbox, where ps and lsof are not permitted: pick the
     rollout in ~/.codex/sessions written in the last few minutes whose tail
     records this very command (Codex logs the tool call before running it),
     else the one whose cwd is this shell's cwd, else the only recent one.
Stdlib only.
"""

import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asb_paths  # noqa: E402

FLAGS_PATH = asb_paths.FLAGS_PATH
LIVE_DIR = asb_paths.CLAUDE_LIVE
CODEX_SESSIONS = asb_paths.CODEX_SESSIONS
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
RECENT_ROLLOUT = dt.timedelta(minutes=5)


def load(path=FLAGS_PATH):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(flags, path=FLAGS_PATH):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(flags, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def add(sid, note="", path=FLAGS_PATH, now=None):
    flags = load(path)
    now = now or dt.datetime.now().astimezone()
    entry = flags.get(sid, {})
    entry["note"] = note.strip() or entry.get("note", "")
    entry["flagged_at"] = now.isoformat()
    flags[sid] = entry
    save(flags, path)
    return entry


def remove(sid, path=FLAGS_PATH):
    flags = load(path)
    existed = flags.pop(sid, None) is not None
    save(flags, path)
    return existed


# --- resolving "the session this shell belongs to" ---------------------------

def claude_session_for_pid(pid, live_dir=LIVE_DIR):
    try:
        with open(os.path.join(live_dir, f"{pid}.json"), "r", encoding="utf-8") as handle:
            return json.load(handle).get("sessionId") or None
    except (OSError, ValueError):
        return None


def ancestors(pid=None):
    """[(pid, command), ...] from this process up to launchd, using ps."""
    out = []
    pid = pid or os.getpid()
    for _ in range(30):
        if pid <= 1:
            break
        try:
            info = subprocess.run(["ps", "-o", "ppid=,command=", "-p", str(pid)],
                                  capture_output=True, text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            break
        if not info:
            break
        parent, _, command = info.partition(" ")
        out.append((pid, command.strip()))
        try:
            pid = int(parent)
        except ValueError:
            break
    return out


def looks_like_codex(command):
    exe = command.split()[0] if command else ""
    return os.path.basename(exe) == "codex" or exe.endswith("/codex")


def rollout_id(path):
    match = UUID_RE.findall(os.path.basename(path))
    return match[-1] if match else None


def codex_session_for_pid(pid, sessions_dir=CODEX_SESSIONS):
    """Rollout id held open by the codex process `pid`, via lsof."""
    try:
        out = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        idx = line.find("/")
        if idx > 0 and line[idx:].endswith(".jsonl") and "/rollout-" in line[idx:]:
            return rollout_id(line[idx:])
    return None


def same_dir(a, b):
    """True if two paths name the same directory (handles /tmp vs /private/tmp)."""
    if not a or not b:
        return False
    return os.path.realpath(a) == os.path.realpath(b)


COMMAND_MARK = "add --current"   # what the Codex tool call for this command contains
TAIL_BYTES = 16_000


def tail_mentions(path, needle, size=TAIL_BYTES):
    """True if the last `size` bytes of `path` contain `needle`."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            end = handle.tell()
            handle.seek(max(0, end - size))
            return needle.encode("utf-8") in handle.read()
    except OSError:
        return False


def recent_codex_rollout(cwd, sessions_dir=CODEX_SESSIONS, now=None, mark=COMMAND_MARK):
    """Id of the Codex session most likely running this command, from the rollouts alone.

    Among rollouts written in the last few minutes (newest first): the one whose
    tail already records this command's tool call, else the one whose session cwd
    is `cwd`, else the only one there is.
    """
    now = now or dt.datetime.now()
    candidates = []
    for path in glob.glob(os.path.join(sessions_dir, "*", "*", "*", "rollout-*.jsonl")):
        try:
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(path))
        except OSError:
            continue
        if now - mtime <= RECENT_ROLLOUT:
            candidates.append((mtime, path))
    metas = []
    for _, path in sorted(candidates, reverse=True):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                first = json.loads(handle.readline())
        except (OSError, ValueError):
            continue
        payload = first.get("payload") or {}
        if first.get("type") != "session_meta":
            continue
        sid = payload.get("id") or payload.get("session_id") or rollout_id(path)
        metas.append((path, payload.get("cwd") or "", sid))
    if mark:
        for path, _, sid in metas:
            if tail_mentions(path, mark):
                return sid
    for _, meta_cwd, sid in metas:
        if same_dir(meta_cwd, cwd):
            return sid
    if len(metas) == 1:
        return metas[0][2]
    return None


def inside_codex_sandbox(env=os.environ):
    return bool(env.get("CODEX_SANDBOX") or env.get("CODEX_SANDBOX_NETWORK_DISABLED"))


def current_session(env=os.environ, live_dir=LIVE_DIR, sessions_dir=CODEX_SESSIONS, cwd=None):
    """(agent, session-id, how) for the agent process this shell belongs to, or None."""
    sid = env.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        return ("claude", sid, "CLAUDE_CODE_SESSION_ID")
    for var in ("CLAUDE_PID", "CMUX_CLAUDE_PID"):
        pid = env.get(var)
        if pid:
            sid = claude_session_for_pid(pid, live_dir)
            if sid:
                return ("claude", sid, var)
    chain = ancestors()
    for pid, command in chain:
        sid = claude_session_for_pid(pid, live_dir)
        if sid:
            return ("claude", sid, f"ancestor pid {pid}")
        if looks_like_codex(command):
            sid = codex_session_for_pid(pid, sessions_dir)
            if sid:
                return ("codex", sid, f"codex pid {pid} (lsof)")
            sid = recent_codex_rollout(cwd or os.getcwd(), sessions_dir)
            if sid:
                return ("codex", sid, f"codex pid {pid} (recent rollout)")
    # Inside Codex's sandbox, ps is not permitted (the chain comes back empty)
    # and CODEX_SANDBOX is set. The rollouts are still readable.
    if (inside_codex_sandbox(env) or not chain) and os.path.isdir(sessions_dir):
        sid = recent_codex_rollout(cwd or os.getcwd(), sessions_dir)
        if sid:
            return ("codex", sid, "recent rollout (sandboxed, no process info)")
    return None


def current_session_id(env=os.environ, live_dir=LIVE_DIR):
    found = current_session(env, live_dir)
    return found[1] if found else None


NOT_FOUND = ("could not determine the current session: not running inside Claude Code or Codex, "
             "or the agent's live record is missing; pass the session id explicitly")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("add", "remove", "list", "current"):
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "list":
        json.dump(load(), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if cmd == "current":
        found = current_session()
        if not found:
            sys.stderr.write(NOT_FOUND + "\n")
            return 1
        print(f"{found[1]}  ({found[0]}, via {found[2]})")
        return 0
    if len(argv) < 3:
        sys.stderr.write("session id required\n")
        return 2
    sid = argv[2]
    if sid == "--current":
        found = current_session()
        if not found:
            sys.stderr.write(NOT_FOUND + "\n")
            return 1
        sid = found[1]
    if cmd == "add":
        note = " ".join(argv[3:])
        add(sid, note)
        print(f"flagged {sid}" + (f": {note}" if note else ""))
        return 0
    print(("unflagged " if remove(sid) else "was not flagged: ") + sid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
