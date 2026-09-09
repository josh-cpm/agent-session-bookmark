#!/usr/bin/env python3
"""Tests for the settings CLI (asb_config.py) and validation in asb_paths. Run: python3 -m unittest"""

import contextlib
import io
import json
import os
import tempfile
import unittest

import asb_config
import asb_paths


def run(argv, path):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = asb_config.main(["asb_config.py"] + argv, path=path)
    return code, out.getvalue(), err.getvalue()


class Validate(unittest.TestCase):
    def test_numbers_and_ranges(self):
        self.assertEqual(asb_paths.validate("days", "14"), 14)
        self.assertEqual(asb_paths.validate("preview_turns", 6), 6)
        for key, bad in (("days", "0"), ("days", "abc"), ("max_sessions", 501), ("preview_turns", 7)):
            with self.assertRaises(ValueError):
                asb_paths.validate(key, bad)

    def test_enums_and_lists(self):
        self.assertEqual(asb_paths.validate("window", "floating"), "floating")
        self.assertEqual(asb_paths.validate("agent_tags", "never"), "never")
        self.assertEqual(asb_paths.validate("ignore_cwds", "~/a, ~/b ,"), ["~/a", "~/b"])
        self.assertEqual(asb_paths.validate("ignore_cwds", ["~/a"]), ["~/a"])
        for key, bad in (("window", "sideways"), ("agent_tags", "yes"), ("ignore_cwds", 3), ("nope", 1)):
            with self.assertRaises(ValueError):
                asb_paths.validate(key, bad)

    def test_load_config_ignores_invalid_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            asb_paths.write_config_file({"days": "lots", "window": "floating", "extra": 1}, path)
            config = asb_paths.load_config(path)
            self.assertEqual(config["days"], asb_paths.DEFAULT_CONFIG["days"])
            self.assertEqual(config["window"], "floating")
            self.assertNotIn("extra", config)


class CLI(unittest.TestCase):
    def test_set_get_unset_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "nested", "config.json")
            code, out, _ = run(["set", "days", "14"], path)
            self.assertEqual((code, out.strip()), (0, "days = 14"))
            code, out, _ = run(["get", "days"], path)
            self.assertEqual((code, out.strip()), (0, "14"))
            code, out, _ = run(["show"], path)
            self.assertEqual(json.loads(out)["days"], 14)
            self.assertEqual(json.loads(out)["window"], "desktop")
            code, out, _ = run(["unset", "days"], path)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(run(["show"], path)[1])["days"], 7)
            self.assertNotIn("days", asb_paths.read_config_file(path))

    def test_bad_values_exit_2_with_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            code, _, err = run(["set", "window", "sideways"], path)
            self.assertEqual(code, 2)
            self.assertIn("desktop", err)
            code, _, err = run(["set", "bogus", "1"], path)
            self.assertEqual(code, 2)
            self.assertIn("unknown setting", err)
            self.assertFalse(os.path.exists(path))

    def test_list_add_remove_keeps_paths_as_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            run(["add", "ignore_cwds", "~/dev/bots"], path)
            run(["add", "ignore_cwds", "~/dev/bots, ~/dev/cron"], path)
            self.assertEqual(json.loads(run(["get", "ignore_cwds"], path)[1]), ["~/dev/bots", "~/dev/cron"])
            run(["remove", "ignore_cwds", "~/dev/bots"], path)
            self.assertEqual(json.loads(run(["get", "ignore_cwds"], path)[1]), ["~/dev/cron"])
            self.assertEqual(asb_paths.load_config(path)["ignore_cwds"], [os.path.expanduser("~/dev/cron")])
            code, _, err = run(["add", "days", "3"], path)
            self.assertEqual(code, 2)

    def test_keys_and_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config.json")
            code, out, _ = run(["keys"], path)
            self.assertEqual(code, 0)
            for key in asb_paths.DEFAULT_CONFIG:
                self.assertIn(key, out)
            self.assertEqual(run(["path"], path)[1].strip(), path)
            self.assertEqual(run([], path)[0], 2)


if __name__ == "__main__":
    unittest.main()
