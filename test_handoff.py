#!/usr/bin/env python3
"""Tests for handoff.py. Run: python3 -m unittest"""

import contextlib
import datetime as dt
import io
import json
import os
import tempfile
import unittest
from unittest import mock

import handoff


def write_jsonl(path, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for obj in objs:
            handle.write(json.dumps(obj) + "\n")


def claude_turn(kind, text, ts):
    return {"type": kind, "timestamp": ts, "cwd": "/Users/example/dev/proj",
            "message": {"content": [{"type": "text", "text": text}]}}


NOW = dt.datetime(2026, 9, 9, 15, 0, tzinfo=dt.timezone.utc)


class Handoff(unittest.TestCase):
    def test_claude_brief_has_path_cwd_goal_turns_note_and_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            projects = os.path.join(tmp, "projects")
            path = os.path.join(projects, "-Users-example-dev-proj", "abc-123.jsonl")
            write_jsonl(path, [
                {"type": "ai-title", "aiTitle": "Fix the flaky test"},
                claude_turn("user", "the CI test is flaky, find out why", "2026-09-09T14:00:00Z"),
                claude_turn("assistant", "Looking at the test now.", "2026-09-09T14:00:05Z"),
                {"type": "user", "isMeta": True, "timestamp": "2026-09-09T14:00:06Z",
                 "message": {"content": "<system-reminder>ignored</system-reminder>"}},
                claude_turn("user", "focus on the retry logic", "2026-09-09T14:10:00Z"),
                claude_turn("assistant", "The retry wrapper swallows the timeout.", "2026-09-09T14:10:30Z"),
            ])
            agent, found = handoff.find_transcript("abc-123", projects_dir=projects, codex_dir=os.path.join(tmp, "none"))
            self.assertEqual((agent, found), ("claude", path))
            info = handoff.describe("abc-123", agent, found, titles={})
            text = handoff.render(info, note="I need to step away; keep going", now=NOW)
        self.assertTrue(text.startswith(f"I want you to resume the session found at {path}\n"))
        self.assertIn('Claude Code session titled "Fix the flaky test"', text)
        self.assertIn("working in /Users/example/dev/proj", text)
        self.assertIn("Handoff note from me: I need to step away; keep going", text)
        self.assertIn("> the CI test is flaky, find out why", text)
        self.assertIn("Me: focus on the retry logic", text)
        self.assertIn("Claude Code: The retry wrapper swallows the timeout.", text)
        self.assertNotIn("ignored", text)
        self.assertIn("cd /Users/example/dev/proj && claude --resume abc-123", text)

    def test_codex_brief_uses_rollout_format_and_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            codex = os.path.join(tmp, "codex")
            path = os.path.join(codex, "2026", "09", "09", "rollout-2026-09-09T10-00-00-0000aaaa-1111-2222-3333-444444444444.jsonl")
            write_jsonl(path, [
                {"type": "session_meta", "payload": {"id": "0000aaaa-1111-2222-3333-444444444444", "cwd": "/w", "originator": "codex-tui"}},
                {"type": "response_item", "timestamp": "2026-09-09T10:00:01Z", "payload": {"type": "message", "role": "user",
                 "content": [{"type": "input_text", "text": "<environment_context>x</environment_context>"}]}},
                {"type": "response_item", "timestamp": "2026-09-09T10:00:02Z", "payload": {"type": "message", "role": "user",
                 "content": [{"type": "input_text", "text": "rename the module"}]}},
                {"type": "response_item", "timestamp": "2026-09-09T10:00:09Z", "payload": {"type": "message", "role": "assistant",
                 "content": [{"type": "output_text", "text": "Renamed; tests pass."}]}},
            ])
            agent, found = handoff.find_transcript("0000aaaa-1111-2222-3333-444444444444",
                                                   projects_dir=os.path.join(tmp, "none"), codex_dir=codex)
            self.assertEqual(agent, "codex")
            text = handoff.render(handoff.describe("0000aaaa-1111-2222-3333-444444444444", agent, found), now=NOW)
        self.assertIn('Codex session titled "rename the module"', text)
        self.assertIn("Codex rollout", text)
        self.assertIn("Codex: Renamed; tests pass.", text)
        self.assertNotIn("environment_context>x", text)
        self.assertIn("cd /w && codex resume 0000aaaa-1111-2222-3333-444444444444", text)

    def test_when_formats_today_and_other_days(self):
        self.assertTrue(handoff.when("2026-09-09T14:00:00Z", now=NOW.astimezone()).startswith("today at "))
        self.assertIn("2026", handoff.when("2026-09-01T14:00:00Z", now=NOW.astimezone()))
        self.assertEqual(handoff.when(None), "unknown time")

    def test_main_reports_missing_session_and_copies_when_asked(self):
        err = io.StringIO()
        with mock.patch.object(handoff, "find_transcript", return_value=(None, None)), \
             contextlib.redirect_stderr(err):
            self.assertEqual(handoff.main(["handoff.py", "nope"]), 1)
        self.assertIn("no Claude Code or Codex transcript found", err.getvalue())
        info = {"id": "s", "agent": "claude", "path": "/p", "title": "t", "cwd": "", "goal": "", "turns": [],
                "last_ts": None, "resume_cmd": "claude --resume s"}
        out = io.StringIO()
        with mock.patch.object(handoff, "find_transcript", return_value=("claude", "/p")), \
             mock.patch.object(handoff, "describe", return_value=info), \
             mock.patch.object(handoff, "copy_to_clipboard", return_value=True) as copy, \
             contextlib.redirect_stdout(out):
            self.assertEqual(handoff.main(["handoff.py", "s", "--copy", "a", "note"]), 0)
        copy.assert_called_once()
        self.assertIn("Handoff note from me: a note", out.getvalue())
        self.assertIn("resume the session found at /p", out.getvalue())


if __name__ == "__main__":
    unittest.main()
