#!/usr/bin/env python3
"""Tests for flag.py (bookmark store and current-session resolution) and asb_paths config.
Run: python3 -m unittest"""

import datetime as dt
import json
import os
import tempfile
import unittest
from unittest import mock

import asb_paths
import flag


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(obj, handle)


class Store(unittest.TestCase):
    def test_add_keeps_note_when_reflagged_without_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "nested", "flags.json")
            flag.add("s1", "finish the report", path=path)
            flag.add("s1", "", path=path)
            self.assertEqual(flag.load(path)["s1"]["note"], "finish the report")
            self.assertTrue(flag.remove("s1", path=path))
            self.assertFalse(flag.remove("s1", path=path))
            self.assertEqual(flag.load(path), {})

    def test_load_tolerates_missing_or_garbage(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(flag.load(os.path.join(tmp, "none.json")), {})
            bad = os.path.join(tmp, "bad.json")
            with open(bad, "w") as h:
                h.write("[not a dict]")
            self.assertEqual(flag.load(bad), {})


class CurrentSession(unittest.TestCase):
    def test_env_session_id_wins(self):
        found = flag.current_session(env={"CLAUDE_CODE_SESSION_ID": "abc"}, live_dir="/nonexistent")
        self.assertEqual(found, ("claude", "abc", "CLAUDE_CODE_SESSION_ID"))

    def test_claude_pid_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_json(os.path.join(tmp, "4242.json"), {"pid": 4242, "sessionId": "sid-4242"})
            found = flag.current_session(env={"CLAUDE_PID": "4242"}, live_dir=tmp)
            self.assertEqual(found[:2], ("claude", "sid-4242"))
            found = flag.current_session(env={"CMUX_CLAUDE_PID": "4242"}, live_dir=tmp)
            self.assertEqual(found[:2], ("claude", "sid-4242"))

    def test_ancestor_walk_finds_claude_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_json(os.path.join(tmp, "77.json"), {"pid": 77, "sessionId": "sid-77"})
            chain = [(900, "/bin/zsh -c x"), (77, "/usr/local/bin/claude"), (1, "/sbin/launchd")]
            with mock.patch.object(flag, "ancestors", return_value=chain):
                found = flag.current_session(env={}, live_dir=tmp)
            self.assertEqual(found, ("claude", "sid-77", "ancestor pid 77"))

    def test_ancestor_walk_finds_codex_via_lsof(self):
        chain = [(900, "/bin/zsh -c x"), (55, "/Users/me/.codex/bin/codex"), (1, "/sbin/launchd")]
        with mock.patch.object(flag, "ancestors", return_value=chain), \
             mock.patch.object(flag, "codex_session_for_pid", return_value="c0dex-id") as lsof:
            found = flag.current_session(env={}, live_dir="/nonexistent")
        self.assertEqual(found, ("codex", "c0dex-id", "codex pid 55 (lsof)"))
        lsof.assert_called_once()

    def test_codex_recent_rollout_fallback_matches_cwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            day = os.path.join(tmp, "2026", "09", "09")
            os.makedirs(day)
            meta = {"type": "session_meta", "payload": {"id": "roll-1", "cwd": "/work/here"}}
            other = {"type": "session_meta", "payload": {"id": "roll-2", "cwd": "/elsewhere"}}
            with open(os.path.join(day, "rollout-2026-09-09T10-00-00-roll-1.jsonl"), "w") as h:
                h.write(json.dumps(meta) + "\n")
            with open(os.path.join(day, "rollout-2026-09-09T10-00-01-roll-2.jsonl"), "w") as h:
                h.write(json.dumps(other) + "\n")
            self.assertEqual(flag.recent_codex_rollout("/work/here", sessions_dir=tmp), "roll-1")
            self.assertIsNone(flag.recent_codex_rollout("/nowhere", sessions_dir=tmp))  # two candidates, no match
            os.remove(os.path.join(day, "rollout-2026-09-09T10-00-01-roll-2.jsonl"))
            self.assertEqual(flag.recent_codex_rollout("/nowhere", sessions_dir=tmp), "roll-1")  # lone candidate
            chain = [(55, "codex"), (1, "launchd")]
            with mock.patch.object(flag, "ancestors", return_value=chain), \
                 mock.patch.object(flag, "codex_session_for_pid", return_value=None):
                found = flag.current_session(env={}, live_dir="/nonexistent", sessions_dir=tmp, cwd="/work/here")
            self.assertEqual(found[:2], ("codex", "roll-1"))

    def test_sandboxed_codex_uses_rollout_that_logged_this_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            day = os.path.join(tmp, "2026", "09", "09")
            os.makedirs(day)
            def rollout(name, sid, cwd, extra=None):
                with open(os.path.join(day, f"rollout-2026-09-09T10-00-00-{name}.jsonl"), "w") as h:
                    h.write(json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd}}) + "\n")
                    if extra:
                        h.write(json.dumps(extra) + "\n")
            rollout("a", "sess-a", "/same/cwd")
            rollout("b", "sess-b", "/same/cwd", {"type": "response_item", "payload": {
                "type": "function_call", "arguments": "{\"command\": \"asb add --current note\"}"}})
            # ps blocked: ancestors() returns only ourselves; CODEX_SANDBOX marks the sandbox.
            with mock.patch.object(flag, "ancestors", return_value=[(os.getpid(), "python3")]):
                found = flag.current_session(env={"CODEX_SANDBOX": "seatbelt"}, live_dir="/nonexistent",
                                             sessions_dir=tmp, cwd="/same/cwd")
            self.assertEqual(found[:2], ("codex", "sess-b"))
            # Without the sandbox marker and with a working ps that shows no agent: nothing.
            with mock.patch.object(flag, "ancestors", return_value=[(os.getpid(), "python3"), (1, "launchd")]):
                self.assertIsNone(flag.current_session(env={}, live_dir="/nonexistent", sessions_dir=tmp, cwd="/x"))

    def test_same_dir_resolves_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "real"); os.makedirs(real)
            link = os.path.join(tmp, "link"); os.symlink(real, link)
            self.assertTrue(flag.same_dir(link, real + "/"))
            self.assertFalse(flag.same_dir(real, tmp))
            self.assertFalse(flag.same_dir("", real))

    def test_nothing_found(self):
        with mock.patch.object(flag, "ancestors", return_value=[(os.getpid(), "python3"), (1, "launchd")]):
            self.assertIsNone(flag.current_session(env={}, live_dir="/nonexistent", sessions_dir="/nonexistent"))
        # ps blocked (empty chain) but no Codex data on this machine: still nothing.
        with mock.patch.object(flag, "ancestors", return_value=[]):
            self.assertIsNone(flag.current_session(env={}, live_dir="/nonexistent", sessions_dir="/nonexistent"))

    def test_real_ancestor_walk_runs(self):
        # Smoke test against the real process tree: must not raise, must include this pid.
        chain = flag.ancestors()
        self.assertTrue(chain)
        self.assertEqual(chain[0][0], os.getpid())

    def test_rollout_id_extracts_uuid(self):
        path = "/x/rollout-2026-09-03T13-20-50-01a06849-a0de-7613-9e3f-b9dd6aab6b53.jsonl"
        self.assertEqual(flag.rollout_id(path), "01a06849-a0de-7613-9e3f-b9dd6aab6b53")


class Config(unittest.TestCase):
    def test_defaults_when_missing_or_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(asb_paths.load_config(os.path.join(tmp, "none.json")), asb_paths.DEFAULT_CONFIG)
            bad = os.path.join(tmp, "bad.json")
            with open(bad, "w") as h:
                h.write("{")
            self.assertEqual(asb_paths.load_config(bad), asb_paths.DEFAULT_CONFIG)

    def test_user_values_overlay_and_expand(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            write_json(path, {"ignore_cwds": ["~/dev/bots/"], "days": 14, "unknown": 1})
            config = asb_paths.load_config(path)
            self.assertEqual(config["days"], 14)
            self.assertEqual(config["max_sessions"], asb_paths.DEFAULT_CONFIG["max_sessions"])
            self.assertEqual(config["ignore_cwds"], [os.path.expanduser("~/dev/bots")])
            self.assertNotIn("unknown", config)


if __name__ == "__main__":
    unittest.main()
