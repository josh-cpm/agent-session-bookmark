#!/usr/bin/env python3
"""Tests for sessions_feed.py against synthetic transcripts. Run: python3 -m unittest"""

import datetime as dt
import json
import os
import tempfile
import unittest

import flag as flagstore
import sessions_feed as sf
import transcripts


def write_jsonl(path, objs, mode="w"):
    with open(path, mode, encoding="utf-8") as handle:
        for obj in objs:
            handle.write(json.dumps(obj) + "\n")


def turn(kind, text, ts, **extra):
    obj = {
        "type": kind,
        "timestamp": ts,
        "message": {"content": [{"type": "text", "text": text}]},
        "cwd": "/Users/example/dev/proj",
    }
    obj.update(extra)
    return obj


NOW = dt.datetime(2026, 9, 3, 12, 0, tzinfo=dt.timezone.utc)
CUTOFF = NOW - dt.timedelta(days=7)


class Advance(unittest.TestCase):
    def test_incremental_parse_only_reads_appended_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.jsonl")
            write_jsonl(path, [
                {"type": "ai-title", "aiTitle": "First title"},
                turn("user", "hello", "2026-09-03T10:00:00Z"),
                turn("assistant", "hi there", "2026-09-03T10:00:05Z"),
            ])
            state = sf.advance(sf.fresh_state(), path)
            self.assertEqual(state["title"], "First title")
            self.assertEqual(state["n_user"], 1)
            self.assertEqual([t["role"] for t in state["turns"]], ["user", "assistant"])
            first_offset = state["offset"]
            self.assertEqual(first_offset, os.path.getsize(path))

            write_jsonl(path, [turn("user", "follow up", "2026-09-03T10:01:00Z")], mode="a")
            state = sf.advance(state, path)
            self.assertEqual(state["n_user"], 2)
            self.assertEqual(state["turns"][-1]["text"], "follow up")
            self.assertGreater(state["offset"], first_offset)

    def test_partial_trailing_line_is_not_consumed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.jsonl")
            write_jsonl(path, [turn("user", "done line", "2026-09-03T10:00:00Z")])
            with open(path, "a", encoding="utf-8") as handle:
                handle.write('{"type": "assistant", "timestamp": "2026-09-03T10:0')  # mid-write
            state = sf.advance(sf.fresh_state(), path)
            self.assertEqual(state["n_user"], 1)
            self.assertLess(state["offset"], os.path.getsize(path))
            # Finish the line; the next pass picks it up exactly once.
            with open(path, "a", encoding="utf-8") as handle:
                handle.write('1:00Z", "message": {"content": "second"}, "cwd": "/x"}\n')
            state = sf.advance(state, path)
            self.assertEqual(state["n_user"], 1)
            self.assertEqual([t["text"] for t in state["turns"]], ["done line", "second"])

    def test_truncated_file_restarts(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.jsonl")
            write_jsonl(path, [turn("user", "a" * 50, "2026-09-03T10:00:00Z"),
                               turn("user", "b" * 50, "2026-09-03T10:00:01Z")])
            state = sf.advance(sf.fresh_state(), path)
            self.assertEqual(state["n_user"], 2)
            write_jsonl(path, [turn("user", "short", "2026-09-03T11:00:00Z")])  # rewritten smaller
            state = sf.advance(state, path)
            self.assertEqual(state["n_user"], 1)
            self.assertEqual(state["turns"][-1]["text"], "short")

    def test_filters_sidechain_meta_and_noise(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.jsonl")
            write_jsonl(path, [
                turn("user", "real ask", "2026-09-03T10:00:00Z"),
                turn("user", "subagent chatter", "2026-09-03T10:00:01Z", isSidechain=True),
                turn("user", "meta", "2026-09-03T10:00:02Z", isMeta=True),
                turn("user", "<system-reminder>injected</system-reminder>", "2026-09-03T10:00:03Z"),
                turn("assistant", "reply", "2026-09-03T10:00:04Z"),
            ])
            state = sf.advance(sf.fresh_state(), path)
            self.assertEqual(state["n_user"], 1)
            self.assertEqual([t["text"] for t in state["turns"]], ["real ask", "reply"])

    def test_consecutive_assistant_blocks_keep_newest_and_turns_are_capped(self):
        objs = []
        for i in range(10):
            objs.append(turn("user", f"ask {i}", f"2026-09-03T10:{i:02d}:00Z"))
            objs.append(turn("assistant", f"part one {i}", f"2026-09-03T10:{i:02d}:10Z"))
            objs.append(turn("assistant", f"part two {i}", f"2026-09-03T10:{i:02d}:20Z"))
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.jsonl")
            write_jsonl(path, objs)
            state = sf.advance(sf.fresh_state(), path)
        self.assertEqual(len(state["turns"]), sf.MAX_TURNS)
        self.assertEqual(state["turns"][-1]["text"], "part two 9")
        self.assertEqual(state["turns"][-1]["ts"], "2026-09-03T10:09:20Z")


NO_CODEX = {"sessions_dir": "/nonexistent/codex", "imported": set(), "open_rollouts": set()}
NO_FLAGS = "/nonexistent/flags.json"


class BuildFeed(unittest.TestCase):
    def make_projects(self, tmp):
        projects = os.path.join(tmp, "projects")
        proj = os.path.join(projects, "-Users-example-dev-proj")
        os.makedirs(proj)
        return projects, proj

    def test_feed_shape_sorting_and_live_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects, proj = self.make_projects(tmp)
            write_jsonl(os.path.join(proj, "older.jsonl"), [
                {"type": "ai-title", "aiTitle": "Older session"},
                turn("user", "old ask", "2026-09-02T10:00:00Z"),
                turn("assistant", "old reply", "2026-09-02T10:00:05Z"),
            ])
            write_jsonl(os.path.join(proj, "newer.jsonl"), [
                turn("user", "new ask", "2026-09-03T11:00:00Z"),
                turn("assistant", "new reply", "2026-09-03T11:00:05Z"),
            ])
            write_jsonl(os.path.join(proj, "empty.jsonl"), [
                {"type": "ai-title", "aiTitle": "No turns"},
            ])
            live = {"newer": {"status": "busy", "name": "dev-ab"}}
            feed = sf.build_feed(NOW, CUTOFF, {}, live, {}, projects_dir=projects, codex_kwargs=NO_CODEX, flags_path=NO_FLAGS)

        ids = [s["id"] for s in feed["sessions"]]
        self.assertEqual(ids, ["newer", "older"])
        newer, older = feed["sessions"]
        self.assertEqual(newer["live"], "busy")
        self.assertEqual(newer["live_name"], "dev-ab")
        self.assertEqual(newer["title"], "new ask")           # goal fallback
        self.assertEqual(newer["agent"], "claude")
        self.assertIsNone(older["live"])
        self.assertEqual(older["title"], "Older session")
        self.assertEqual(older["project"], "/Users/example/dev/proj")
        self.assertEqual(older["resume_cmd"], "cd /Users/example/dev/proj && claude --resume older")
        self.assertEqual([t["role"] for t in older["turns"]], ["user", "assistant"])

    def test_live_sessions_sort_first_and_ignore_cutoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects, proj = self.make_projects(tmp)
            write_jsonl(os.path.join(proj, "recent-ended.jsonl"), [turn("user", "x", "2026-09-03T11:00:00Z")])
            write_jsonl(os.path.join(proj, "old-live.jsonl"), [turn("user", "x", "2026-08-01T11:00:00Z")])
            write_jsonl(os.path.join(proj, "old-ended.jsonl"), [turn("user", "x", "2026-08-01T12:00:00Z")])
            write_jsonl(os.path.join(proj, "newer-live.jsonl"), [turn("user", "x", "2026-09-02T11:00:00Z")])
            live = {"old-live": {"status": "idle", "name": None}, "newer-live": {"status": "busy", "name": None}}
            feed = sf.build_feed(NOW, CUTOFF, {}, live, {}, projects_dir=projects, codex_kwargs=NO_CODEX, flags_path=NO_FLAGS)
        self.assertEqual([s["id"] for s in feed["sessions"]], ["newer-live", "old-live", "recent-ended"])

    def test_desktop_title_wins_and_marks_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects, proj = self.make_projects(tmp)
            write_jsonl(os.path.join(proj, "abc.jsonl"), [
                {"type": "ai-title", "aiTitle": "CLI title"},
                turn("user", "ask", "2026-09-03T11:00:00Z"),
            ])
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {"abc": "Desktop title"}, projects_dir=projects, codex_kwargs=NO_CODEX, flags_path=NO_FLAGS)
        self.assertEqual(feed["sessions"][0]["title"], "Desktop title")
        self.assertEqual(feed["sessions"][0]["source"], "desktop")

    def test_cutoff_and_max_apply(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects, proj = self.make_projects(tmp)
            write_jsonl(os.path.join(proj, "ancient.jsonl"), [turn("user", "x", "2026-01-01T00:00:00Z")])
            for i in range(3):
                write_jsonl(os.path.join(proj, f"s{i}.jsonl"), [turn("user", "x", f"2026-09-03T0{i}:00:00Z")])
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {}, projects_dir=projects, max_sessions=2, codex_kwargs=NO_CODEX, flags_path=NO_FLAGS)
        self.assertEqual([s["id"] for s in feed["sessions"]], ["s2", "s1"])

    def test_resume_command_quotes_paths(self):
        self.assertEqual(sf.resume_command("/Users/x/My Dir", "id1"),
                         "cd '/Users/x/My Dir' && claude --resume id1")
        self.assertEqual(sf.resume_command("", "id1"), "claude --resume id1")


def codex_line(kind, payload, ts="2026-09-03T10:00:00Z"):
    return {"timestamp": ts, "type": kind, "payload": payload}


def codex_msg(role, text, ts):
    block_type = "input_text" if role == "user" else "output_text"
    return codex_line("response_item", {"type": "message", "role": role,
                                        "content": [{"type": block_type, "text": text}]}, ts)


def codex_meta(sid, **extra):
    payload = {"id": sid, "session_id": sid, "cwd": "/Users/example/dev/proj", "originator": "codex-tui"}
    payload.update(extra)
    return codex_line("session_meta", payload)


class Codex(unittest.TestCase):
    def rollout(self, root, sid, objs, day="2026/09/03"):
        folder = os.path.join(root, *day.split("/"))
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"rollout-2026-09-03T10-00-00-{sid}.jsonl")
        write_jsonl(path, objs)
        return path

    def test_genuine_session_parsed_with_turns_title_and_resume(self):
        sid = "01a06849-a0de-7613-9e3f-b9dd6aab6b53"
        with tempfile.TemporaryDirectory() as tmp:
            self.rollout(tmp, sid, [
                codex_meta(sid),
                codex_line("event_msg", {"type": "task_started"}),
                codex_msg("developer", "system-ish instructions", "2026-09-03T10:00:01Z"),
                codex_msg("user", "<environment_context>\n  <cwd>/x</cwd>", "2026-09-03T10:00:02Z"),
                codex_msg("user", "are we logged in?", "2026-09-03T10:00:03Z"),
                codex_msg("assistant", "Checking now.", "2026-09-03T10:00:04Z"),
                codex_line("event_msg", {"type": "task_complete"}),
            ])
            rows = sf.codex_sessions(NOW, CUTOFF, {}, sessions_dir=tmp, imported=set(), open_rollouts=set())
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["agent"], "codex")
        self.assertEqual(row["source"], "codex-cli")
        self.assertEqual(row["title"], "are we logged in?")
        self.assertEqual([t["text"] for t in row["turns"]], ["are we logged in?", "Checking now."])
        self.assertIsNone(row["live"])
        self.assertEqual(row["resume_cmd"], f"cd /Users/example/dev/proj && codex resume {sid}")

    def test_imports_forks_of_imports_and_subagents_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.rollout(tmp, "aaaaaaaa-0000-0000-0000-000000000001",
                         [codex_meta("aaaaaaaa-0000-0000-0000-000000000001"), codex_msg("user", "imported", "2026-09-03T10:00:03Z")])
            self.rollout(tmp, "aaaaaaaa-0000-0000-0000-000000000002",
                         [codex_meta("aaaaaaaa-0000-0000-0000-000000000002", forked_from_id="claude-session-id-not-a-rollout"),
                          codex_msg("user", "fork of import", "2026-09-03T10:00:03Z")])
            self.rollout(tmp, "aaaaaaaa-0000-0000-0000-000000000003",
                         [codex_meta("aaaaaaaa-0000-0000-0000-000000000003", parent_thread_id="aaaaaaaa-0000-0000-0000-000000000004"),
                          codex_msg("user", "subagent", "2026-09-03T10:00:03Z")])
            self.rollout(tmp, "aaaaaaaa-0000-0000-0000-000000000004",
                         [codex_meta("aaaaaaaa-0000-0000-0000-000000000004", originator="Codex Desktop"),
                          codex_msg("user", "genuine desktop", "2026-09-03T10:00:03Z")])
            self.rollout(tmp, "aaaaaaaa-0000-0000-0000-000000000005",
                         [codex_meta("aaaaaaaa-0000-0000-0000-000000000005", forked_from_id="aaaaaaaa-0000-0000-0000-000000000004"),
                          codex_msg("user", "fork of a real codex session", "2026-09-03T10:00:04Z")])
            rows = sf.codex_sessions(NOW, CUTOFF, {}, sessions_dir=tmp,
                                     imported={"aaaaaaaa-0000-0000-0000-000000000001"}, open_rollouts=set())
        self.assertEqual(sorted(r["title"] for r in rows), ["fork of a real codex session", "genuine desktop"])
        self.assertEqual({r["source"] for r in rows}, {"codex-desktop", "codex-cli"})

    def test_live_via_open_file_and_busy_from_events(self):
        sid = "bbbbbbbb-0000-0000-0000-000000000001"
        with tempfile.TemporaryDirectory() as tmp:
            path = self.rollout(tmp, sid, [
                codex_meta(sid),
                codex_msg("user", "old ask", "2026-08-01T10:00:03Z"),   # older than cutoff
                codex_line("event_msg", {"type": "task_started"}, "2026-08-01T10:00:04Z"),
            ])
            rows = sf.codex_sessions(NOW, CUTOFF, {}, sessions_dir=tmp, imported=set(),
                                     open_rollouts={os.path.realpath(path)})
            self.assertEqual([r["live"] for r in rows], ["busy"])
            rows = sf.codex_sessions(NOW, CUTOFF, {}, sessions_dir=tmp, imported=set(), open_rollouts=set())
            self.assertEqual(rows, [])  # not live and too old

    def test_build_feed_merges_codex_and_sorts(self):
        sid = "cccccccc-0000-0000-0000-000000000001"
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects", "-Users-example-dev-proj")
            os.makedirs(projects)
            write_jsonl(os.path.join(projects, "claude1.jsonl"), [turn("user", "claude ask", "2026-09-03T09:00:00Z")])
            codex_root = os.path.join(tmp, "codex")
            self.rollout(codex_root, sid, [codex_meta(sid), codex_msg("user", "codex ask", "2026-09-03T11:00:00Z")])
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {}, projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs={"sessions_dir": codex_root, "imported": set(), "open_rollouts": set()},
                                 flags_path=NO_FLAGS)
        self.assertEqual([(s["agent"], s["id"]) for s in feed["sessions"]], [("codex", sid), ("claude", "claude1")])


class Flags(unittest.TestCase):
    def test_add_remove_list_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "state", "flags.json")
            flagstore.add("s1", "finish parser", path=path)
            flagstore.add("s2", "", path=path)
            flags = flagstore.load(path)
            self.assertEqual(set(flags), {"s1", "s2"})
            self.assertEqual(flags["s1"]["note"], "finish parser")
            self.assertTrue(flagstore.remove("s1", path=path))
            self.assertFalse(flagstore.remove("s1", path=path))
            self.assertEqual(set(flagstore.load(path)), {"s2"})

    def test_current_session_id_from_cmux_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "4242.json"), "w") as handle:
                json.dump({"pid": 4242, "sessionId": "abc"}, handle)
            self.assertEqual(flagstore.current_session_id({"CMUX_CLAUDE_PID": "4242"}, live_dir=tmp), "abc")
            self.assertIsNone(flagstore.current_session_id({}, live_dir=tmp))
            self.assertIsNone(flagstore.current_session_id({"CMUX_CLAUDE_PID": "1"}, live_dir=tmp))

    def test_flagged_sessions_sort_first_bypass_cutoff_and_carry_note(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects", "-Users-example-dev-proj")
            os.makedirs(projects)
            write_jsonl(os.path.join(projects, "live1.jsonl"), [turn("user", "x", "2026-09-03T11:00:00Z")])
            write_jsonl(os.path.join(projects, "recent.jsonl"), [turn("user", "x", "2026-09-03T10:00:00Z")])
            write_jsonl(os.path.join(projects, "oldflag.jsonl"), [turn("user", "x", "2026-07-01T10:00:00Z")])
            flags_path = os.path.join(tmp, "flags.json")
            flagstore.add("oldflag", "come back to this", path=flags_path,
                          now=dt.datetime(2026, 9, 2, tzinfo=dt.timezone.utc))
            live = {"live1": {"status": "idle", "name": None, "started_at": 0}}
            feed = sf.build_feed(NOW, CUTOFF, {}, live, {}, projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs=NO_CODEX, flags_path=flags_path)
        ids = [s["id"] for s in feed["sessions"]]
        self.assertEqual(ids, ["oldflag", "live1", "recent"])
        self.assertEqual(feed["sessions"][0]["flag"]["note"], "come back to this")
        self.assertIsNone(feed["sessions"][1]["flag"])

    def test_flag_clears_when_a_new_process_resumes_the_session(self):
        flagged_at = dt.datetime(2026, 9, 2, 12, 0, tzinfo=dt.timezone.utc)
        before = int((flagged_at - dt.timedelta(hours=1)).timestamp() * 1000)
        after = int((flagged_at + dt.timedelta(hours=1)).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects", "-Users-example-dev-proj")
            os.makedirs(projects)
            write_jsonl(os.path.join(projects, "s.jsonl"), [turn("user", "x", "2026-09-03T11:00:00Z")])
            flags_path = os.path.join(tmp, "flags.json")
            flagstore.add("s", "", path=flags_path, now=flagged_at)

            # Still the same process that was running when flagged: flag stays.
            live = {"s": {"status": "busy", "name": None, "started_at": before}}
            feed = sf.build_feed(NOW, CUTOFF, {}, live, {}, projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs=NO_CODEX, flags_path=flags_path)
            self.assertIsNotNone(feed["sessions"][0]["flag"])
            # Ended: flag stays.
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {}, projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs=NO_CODEX, flags_path=flags_path)
            self.assertIsNotNone(feed["sessions"][0]["flag"])
            # Resumed in a process started after the flag: flag clears and is persisted as cleared.
            live = {"s": {"status": "idle", "name": None, "started_at": after}}
            feed = sf.build_feed(NOW, CUTOFF, {}, live, {}, projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs=NO_CODEX, flags_path=flags_path)
            self.assertIsNone(feed["sessions"][0]["flag"])
            self.assertEqual(flagstore.load(flags_path), {})

    def test_custom_title_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects", "-Users-example-dev-proj")
            os.makedirs(projects)
            write_jsonl(os.path.join(projects, "s.jsonl"), [
                {"type": "ai-title", "aiTitle": "AI title"},
                {"type": "custom-title", "customTitle": "My name", "sessionId": "s"},
                turn("user", "x", "2026-09-03T11:00:00Z"),
            ])
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {"s": "Desktop title"},
                                 projects_dir=os.path.join(tmp, "projects"),
                                 codex_kwargs=NO_CODEX, flags_path=NO_FLAGS)
        self.assertEqual(feed["sessions"][0]["title"], "My name")


class LiveSessions(unittest.TestCase):
    def test_dead_pid_is_dropped_and_own_pid_is_live(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "a.json"), "w") as handle:
                json.dump({"pid": os.getpid(), "sessionId": "me", "status": "idle", "name": "dev-01"}, handle)
            with open(os.path.join(tmp, "b.json"), "w") as handle:
                json.dump({"pid": 2**22 - 1, "sessionId": "ghost", "status": "busy"}, handle)
            with open(os.path.join(tmp, "c.json"), "w") as handle:
                handle.write("not json")
            live = sf.live_sessions(live_dir=tmp)
        self.assertEqual(set(live), {"me"})
        self.assertEqual(live["me"], {"status": "idle", "name": "dev-01", "started_at": None})



class IgnoreList(unittest.TestCase):
    def test_sessions_in_ignored_cwds_are_hidden(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects")
            os.makedirs(os.path.join(projects, "p"))
            write_jsonl(os.path.join(projects, "p", "keep.jsonl"), [turn("user", "hi", "2026-09-03T10:00:00Z")])
            bot = dict(turn("user", "cron run", "2026-09-03T10:00:00Z"), cwd="/Users/example/dev/bots/")
            write_jsonl(os.path.join(projects, "p", "bot.jsonl"), [bot])
            feed = sf.build_feed(NOW, CUTOFF, {}, {}, {}, projects_dir=projects, codex_kwargs=NO_CODEX,
                                 flags_path=os.path.join(tmp, "flags.json"),
                                 ignore_cwds=["/Users/example/dev/bots"])
            self.assertEqual([s["id"] for s in feed["sessions"]], ["keep"])


class Transcripts(unittest.TestCase):
    def test_noise_blocks_are_dropped(self):
        msg = {"content": [{"type": "text", "text": "<system-reminder>x</system-reminder>"},
                           {"type": "text", "text": "real words"}]}
        self.assertEqual(transcripts.extract_text(msg), "real words")
        self.assertEqual(transcripts.extract_text({"content": "  plain  "}), "plain")
        self.assertEqual(transcripts.one_line("a\n  b   c", 3), "a b…")
        self.assertIsNone(transcripts.parse_ts("nope"))
        self.assertEqual(transcripts.parse_ts("2026-09-03T10:00:00Z").tzinfo, dt.timezone.utc)

if __name__ == "__main__":
    unittest.main()
