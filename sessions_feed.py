#!/usr/bin/env python3
"""sessions_feed.py — JSON feed of recent Claude Code and Codex sessions for the panel.

Reads Claude Code transcripts from ~/.claude/projects, keeps the last few
conversational turns of each session so the panel can show a preview, and marks
sessions that are live right now using the per-process records Claude Code
writes to ~/.claude/sessions/<pid>.json.

Also reads OpenAI Codex sessions from ~/.codex/sessions/**/rollout-*.jsonl.
Codex Desktop imports Claude transcripts into that store (and forks them), so
imported/forked/subagent rollouts are skipped. A Codex session counts as live
when a running codex process holds its rollout file open (lsof).

Output (stdout, one JSON document):
  {"generated": "<iso>", "sessions": [
     {"id", "title", "cwd", "project", "source", "first_ts", "last_ts",
      "agent": "claude" | "codex", "live": "busy" | "idle" | null, "live_name",
      "turns": [{"role","text","ts"}], "resume_cmd"}, ...]}   # live first, then newest

Transcripts are parsed incrementally: a cache in ~/Library/Caches remembers how
far into each file we have read, so a refresh only touches bytes appended since
the last run. Stdlib only, no network. Defaults for --days / --max and the
ignore list come from config.json (see asb_paths.py).

Usage:  sessions_feed.py [--days N] [--max N] [--no-cache]
"""

import argparse
import datetime as dt
import glob
import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asb_paths  # noqa: E402
import flag as flagstore  # noqa: E402  ("return to" flags, see flag.py)
import transcripts as uw  # noqa: E402  (transcript text helpers)

HOME = asb_paths.HOME
CC_PROJECTS = asb_paths.CLAUDE_PROJECTS
LIVE_DIR = asb_paths.CLAUDE_LIVE
CACHE_DIR = asb_paths.CACHE_DIR
CACHE_PATH = os.path.join(CACHE_DIR, "feed-cache.json")
CACHE_VERSION = 5

CODEX_SESSIONS = asb_paths.CODEX_SESSIONS
CODEX_IMPORTS = asb_paths.CODEX_IMPORTS
CODEX_NOISE_PREFIXES = uw.NOISE_PREFIXES + (
    "<environment_context>",
    "<uploaded_files>",
    "<claudeai_review_comments>",
    "<permissions instructions>",
    "[Request interrupted",
)

DEFAULT_DAYS = asb_paths.DEFAULT_CONFIG["days"]
DEFAULT_MAX = asb_paths.DEFAULT_CONFIG["max_sessions"]
MAX_TURNS = 6          # kept per session for the preview
TURN_CHARS = 700       # per-turn text cap in the feed
TITLE_CHARS = 80


def fresh_state(agent="claude"):
    return {
        "agent": agent,
        "mtime": None, "size": 0, "offset": 0,
        "title": None, "custom_title": None, "cwd": None, "goal": None,
        "first_ts": None, "last_ts": None, "n_user": 0,
        "turns": [],
        # codex only
        "id": None, "forked_from": None, "parent": None, "originator": None, "busy": False,
    }


def advance(state, path):
    """Parse bytes appended to `path` since state["offset"]; mutate state in place.

    Only complete lines (ending in a newline) are consumed, so a transcript
    that is mid-write is picked up cleanly on the next run.
    """
    try:
        stat = os.stat(path)
    except OSError:
        return state
    if stat.st_size < state["offset"]:      # truncated or rewritten: start over
        state = fresh_state(state.get("agent", "claude"))
    ingest_fn = ingest_codex if state.get("agent") == "codex" else ingest
    if stat.st_size == state["offset"] and state["mtime"] == stat.st_mtime:
        return state

    try:
        handle = open(path, "rb")
    except OSError:
        return state
    with handle:
        handle.seek(state["offset"])
        offset = state["offset"]
        for raw in handle:
            if not raw.endswith(b"\n"):
                break
            offset += len(raw)
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line.decode("utf-8", errors="replace"))
            except (ValueError, TypeError):
                continue
            ingest_fn(state, obj)
    state["offset"] = offset
    state["size"] = stat.st_size
    state["mtime"] = stat.st_mtime
    return state


def ingest(state, obj):
    kind = obj.get("type")
    if kind == "ai-title" and obj.get("aiTitle"):
        state["title"] = obj["aiTitle"]
        return
    if kind == "last-prompt" and not state["title"] and obj.get("lastPrompt"):
        state["title"] = obj["lastPrompt"][:TITLE_CHARS]
        return
    if kind == "custom-title" and obj.get("customTitle"):   # /rename
        state["custom_title"] = obj["customTitle"]
        return
    if kind not in ("user", "assistant"):
        return
    if obj.get("isSidechain") or obj.get("isMeta") or obj.get("parent_tool_use_id"):
        return
    text = uw.extract_text(obj.get("message"))
    if not text:
        return
    ts = obj.get("timestamp") if uw.parse_ts(obj.get("timestamp")) else None

    state["cwd"] = state["cwd"] or obj.get("cwd")
    if ts:
        state["first_ts"] = state["first_ts"] or ts
        state["last_ts"] = ts
    if kind == "user":
        state["n_user"] += 1
        state["goal"] = state["goal"] or text
    add_turn(state, kind, text, ts)


def add_turn(state, kind, text, ts):
    turns = state["turns"]
    if turns and turns[-1]["role"] == kind:
        # Consecutive same-role text blocks (assistant text between tool calls)
        # are one turn to the reader; keep the newest block, which for the
        # assistant is the wrap-up and always starts at a sentence boundary.
        turns[-1]["text"] = text[:TURN_CHARS * 2]
        turns[-1]["ts"] = ts or turns[-1]["ts"]
    else:
        turns.append({"role": kind, "text": text[:TURN_CHARS * 2], "ts": ts})
    del turns[:-MAX_TURNS]


def codex_text(content):
    parts = []
    for block in content or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") in ("input_text", "output_text"):
            text = block.get("text", "").strip()
            if text and not any(text.startswith(p) for p in CODEX_NOISE_PREFIXES):
                parts.append(text)
    return "\n".join(parts)


def ingest_codex(state, obj):
    kind = obj.get("type")
    payload = obj.get("payload") or {}
    if kind == "session_meta":
        state["id"] = payload.get("id") or payload.get("session_id")
        state["cwd"] = payload.get("cwd")
        state["forked_from"] = payload.get("forked_from_id")
        state["parent"] = payload.get("parent_thread_id")
        state["originator"] = payload.get("originator")
        return
    if kind == "event_msg":
        et = payload.get("type")
        if et == "task_started":
            state["busy"] = True
        elif et in ("task_complete", "turn_aborted"):
            state["busy"] = False
        return
    if kind != "response_item" or payload.get("type") != "message":
        return
    role = payload.get("role")
    if role not in ("user", "assistant"):
        return
    text = codex_text(payload.get("content"))
    if not text:
        return
    ts = obj.get("timestamp") if uw.parse_ts(obj.get("timestamp")) else None
    if ts:
        state["first_ts"] = state["first_ts"] or ts
        state["last_ts"] = ts
    if role == "user":
        state["n_user"] += 1
        state["goal"] = state["goal"] or text
    add_turn(state, role, text, ts)


def codex_imported_ids(path=CODEX_IMPORTS):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return set()
    return {r.get("imported_thread_id") for r in data.get("records", []) if r.get("imported_thread_id")}


def codex_open_rollouts():
    """Rollout paths held open by running codex processes (exact liveness)."""
    try:
        pids = subprocess.run(["pgrep", "-f", "codex"], capture_output=True, text=True, timeout=3).stdout.split()
        pids = [p for p in pids if p.isdigit() and int(p) != os.getpid()]
        if not pids:
            return set()
        out = subprocess.run(["lsof", "-p", ",".join(pids)], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    open_paths = set()
    for line in out.splitlines():
        idx = line.find("/")
        if idx > 0 and line[idx:].endswith(".jsonl") and "/sessions/" in line:
            open_paths.add(os.path.realpath(line[idx:]))
    return open_paths


def rollout_id(path):
    stem = os.path.basename(path)[: -len(".jsonl")]
    return stem[-36:] if len(stem) >= 36 else stem


def codex_sessions(now, cutoff, cache, sessions_dir=CODEX_SESSIONS, imported=None, open_rollouts=None,
                   flags=None, ignore_cwds=()):
    """Genuine Codex sessions with activity since cutoff (or live/flagged), as feed dicts."""
    flags = flags or {}
    imported = codex_imported_ids() if imported is None else imported
    open_rollouts = codex_open_rollouts() if open_rollouts is None else open_rollouts
    paths = glob.glob(os.path.join(sessions_dir, "*", "*", "*", "rollout-*.jsonl"))
    known_ids = {rollout_id(p) for p in paths}
    out = []
    for path in paths:
        try:
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
        except OSError:
            continue
        is_live = os.path.realpath(path) in open_rollouts
        keep = is_live or rollout_id(path) in flags
        if mtime < cutoff and not keep:
            continue
        state = cache.get(path) or fresh_state("codex")
        state = advance(state, path)
        cache[path] = state
        sid = state["id"] or rollout_id(path)
        if sid in imported or state["parent"]:
            continue
        if state["forked_from"] and state["forked_from"] not in known_ids:
            continue  # forked from a transcript that was never a Codex session: an import
        if state["n_user"] == 0 or not state["last_ts"]:
            continue
        last_ts = uw.parse_ts(state["last_ts"])
        if last_ts is None or (last_ts < cutoff and not (is_live or sid in flags)):
            continue
        cwd = state["cwd"] or ""
        if cwd.rstrip("/") in ignore_cwds:
            continue
        origin = (state["originator"] or "").lower()
        out.append({
            "id": sid,
            "title": uw.one_line(state["goal"] or "", TITLE_CHARS) or "(untitled)",
            "cwd": cwd,
            "project": cwd.replace(HOME, "~") if cwd else "",
            "source": "codex-cli" if origin.startswith("codex-tui") else "codex-desktop",
            "agent": "codex",
            "first_ts": state["first_ts"],
            "last_ts": state["last_ts"],
            "live": ("busy" if state["busy"] else "idle") if is_live else None,
            "live_name": None,
            "live_started_at": None,
            "turns": [{"role": t["role"], "text": trim(t["text"]), "ts": t["ts"]} for t in state["turns"]],
            "resume_cmd": resume_command(cwd, sid, "codex resume"),
        })
    return out


def load_cache():
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if data.get("version") == CACHE_VERSION:
            return data.get("files", {})
    except (OSError, ValueError):
        pass
    return {}


def save_cache(files):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = CACHE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"version": CACHE_VERSION, "files": files}, handle)
        os.replace(tmp, CACHE_PATH)
    except OSError:
        pass  # cache is an optimization only


def live_sessions(live_dir=LIVE_DIR):
    """sessionId -> {"status", "name"} for Claude Code processes still running."""
    out = {}
    for path in glob.glob(os.path.join(live_dir, "*.json")):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                rec = json.load(handle)
        except (OSError, ValueError):
            continue
        pid, sid = rec.get("pid"), rec.get("sessionId")
        if not isinstance(pid, int) or not sid:
            continue
        if not pid_alive(pid):
            continue
        out[sid] = {"status": rec.get("status") or "idle", "name": rec.get("name"),
                    "started_at": rec.get("startedAt")}   # ms epoch of this process
    return out


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def trim(text, limit=TURN_CHARS):
    text = text.strip()
    if len(text) > limit:
        return text[:limit].rstrip() + "…"
    return text


def build_feed(now, cutoff, cache, live, titles, projects_dir=CC_PROJECTS, max_sessions=DEFAULT_MAX,
               codex_kwargs=None, flags_path=flagstore.FLAGS_PATH, ignore_cwds=()):
    codex_kwargs = codex_kwargs if codex_kwargs is not None else {}
    ignore_cwds = tuple(p.rstrip("/") for p in ignore_cwds)
    flags = flagstore.load(flags_path)
    sessions = []
    seen = set()
    for path in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
        seen.add(path)
        sid = os.path.basename(path)[: -len(".jsonl")]
        try:
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
        except OSError:
            continue
        if mtime < cutoff and sid not in flags:
            continue
        state = advance(cache.get(path) or fresh_state(), path)
        cache[path] = state
        if state["n_user"] == 0 or not state["last_ts"]:
            continue
        live_rec = live.get(sid)
        last_ts = uw.parse_ts(state["last_ts"])
        # Live and flagged sessions are always listed, however long they have sat idle.
        if last_ts is None or (last_ts < cutoff and not (live_rec or sid in flags)):
            continue
        cwd = state["cwd"] or ""
        if cwd.rstrip("/") in ignore_cwds:
            continue

        title = (state["custom_title"] or titles.get(sid) or state["title"]
                 or uw.one_line(state["goal"] or "", TITLE_CHARS) or "(untitled)")
        sessions.append({
            "id": sid,
            "title": title,
            "cwd": cwd,
            "project": cwd.replace(HOME, "~") if cwd else "",
            "source": "desktop" if sid in titles else "cli",
            "agent": "claude",
            "first_ts": state["first_ts"],
            "last_ts": state["last_ts"],
            "live": live_rec["status"] if live_rec else None,
            "live_name": live_rec["name"] if live_rec else None,
            "live_started_at": live_rec.get("started_at") if live_rec else None,
            "turns": [{"role": t["role"], "text": trim(t["text"]), "ts": t["ts"]} for t in state["turns"]],
            "resume_cmd": resume_command(cwd, sid),
        })

    sessions.extend(codex_sessions(now, cutoff, cache, flags=flags, ignore_cwds=ignore_cwds, **codex_kwargs))
    seen.update(p for p in cache if p.startswith(CODEX_SESSIONS) or "/rollout-" in p)

    attach_flags(sessions, flags, flags_path)

    # Drop cache entries for files that no longer exist.
    for path in list(cache):
        if path not in seen and not os.path.exists(path):
            del cache[path]

    # Flagged first, then live, then newest first.
    sessions.sort(key=lambda s: (s["flag"] is None, s["live"] is None, -uw.parse_ts(s["last_ts"]).timestamp()))
    return {"generated": now.isoformat(), "sessions": sessions[:max_sessions]}


def attach_flags(sessions, flags, flags_path):
    """Add "flag" to each session; clear flags whose session has been resumed.

    A Claude flag clears once a *new* process (started after the flag) hosts the
    session: that is what "I came back to it" means. Codex has no per-process
    record, so its flag clears when the session is live with activity after the
    flag.
    """
    for s in sessions:
        entry = flags.get(s["id"])
        s["flag"] = None
        if not entry:
            continue
        flagged_at = uw.parse_ts(entry.get("flagged_at"))
        resumed = False
        if s["live"] and flagged_at:
            started = s.get("live_started_at")
            if started:
                resumed = dt.datetime.fromtimestamp(started / 1000, tz=dt.timezone.utc) > flagged_at
            else:
                last = uw.parse_ts(s["last_ts"])
                resumed = bool(last and last > flagged_at)
        if resumed:
            flagstore.remove(s["id"], flags_path)
            continue
        s["flag"] = {"note": entry.get("note", ""), "flagged_at": entry.get("flagged_at")}


def resume_command(cwd, sid, verb="claude --resume"):
    if cwd:
        return f"cd {shlex.quote(cwd)} && {verb} {sid}"
    return f"{verb} {sid}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    config = asb_paths.load_config()
    parser.add_argument("--days", type=int, default=config["days"])
    parser.add_argument("--max", type=int, default=config["max_sessions"])
    parser.add_argument("--no-cache", action="store_true", help="ignore and do not write the parse cache")
    args = parser.parse_args()

    now = dt.datetime.now().astimezone()
    cutoff = now - dt.timedelta(days=args.days)
    cache = {} if args.no_cache else load_cache()
    feed = build_feed(now, cutoff, cache, live_sessions(), uw.desktop_titles(), max_sessions=args.max,
                      ignore_cwds=config["ignore_cwds"])
    if not args.no_cache:
        save_cache(cache)
    json.dump(feed, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
