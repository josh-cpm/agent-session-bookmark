#!/usr/bin/env python3
"""The Python interpreter candidate list exists in three places that cannot
import each other: the app (Swift), the CLI wrapper (sh) and the installer's
pre-flight (bash). Nothing at runtime notices when they drift apart, and the
symptom of drift is the panel working while the CLI does not, or vice versa.
These tests fail instead. Run: python3 -m unittest"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

# The stub is always last: it is the one that a plain Xcode install can gate.
STUB = "/usr/bin/python3"


def read(*parts):
    with open(os.path.join(HERE, *parts), encoding="utf-8") as fh:
        return fh.read()


def swift_candidates():
    """The `pythonCandidates` array literal in Model.swift."""
    src = read("AgentSessionBookmark", "Model.swift")
    match = re.search(r"^let pythonCandidates = \[(.*?)^\]", src, re.S | re.M)
    assert match, "pythonCandidates array not found in Model.swift"
    return re.findall(r'"([^"]+)"', match.group(1))


def wrapper_candidates():
    """The ASB_PYTHON_CANDIDATES heredoc-style list in the CLI wrapper."""
    src = read("integrations", "agent-session-bookmark.sh")
    match = re.search(r'ASB_PYTHON_CANDIDATES="(.*?)"', src, re.S)
    assert match, "ASB_PYTHON_CANDIDATES not found in the wrapper"
    return [line.strip() for line in match.group(1).split("\n") if line.strip()]


def install_candidates():
    """The `for c in ...` interpreter loop in install.sh's pre-flight."""
    src = read("install.sh")
    match = re.search(r"for c in (/opt/homebrew/bin/python3.*?); do", src, re.S)
    assert match, "interpreter loop not found in install.sh"
    return re.findall(r"(/\S*python3)", match.group(1))


class InterpreterCandidates(unittest.TestCase):
    def test_all_three_lists_match(self):
        swift, wrapper, install = swift_candidates(), wrapper_candidates(), install_candidates()
        self.assertEqual(swift, wrapper, "Model.swift and the CLI wrapper disagree")
        self.assertEqual(swift, install, "Model.swift and install.sh disagree")

    def test_stub_is_the_last_resort(self):
        for name, got in (("swift", swift_candidates()),
                          ("wrapper", wrapper_candidates()),
                          ("install", install_candidates())):
            self.assertEqual(got[-1], STUB, f"{name}: the stub must be tried last")
            self.assertEqual(got.count(STUB), 1, f"{name}: the stub is listed twice")

    def test_a_toolchain_interpreter_is_offered(self):
        """Both toolchain layouts ship a real interpreter the licence gate does
        not touch. Without the Xcode one, a Mac with Xcode installed, its
        licence unaccepted and no standalone Command Line Tools has no
        candidate at all, even though a working interpreter is present."""
        for name, got in (("swift", swift_candidates()),
                          ("wrapper", wrapper_candidates()),
                          ("install", install_candidates())):
            self.assertIn("/Library/Developer/CommandLineTools/usr/bin/python3", got, name)
            self.assertIn("/Applications/Xcode.app/Contents/Developer/usr/bin/python3", got, name)

    def test_candidates_are_absolute_paths(self):
        for name, got in (("swift", swift_candidates()),
                          ("wrapper", wrapper_candidates()),
                          ("install", install_candidates())):
            for path in got:
                self.assertTrue(path.startswith("/"), f"{name}: {path} is not absolute")

    def test_no_bare_python3_on_the_path(self):
        """Resolving through PATH would make the app and the CLI pick different
        interpreters, since a LaunchAgent has almost no PATH."""
        for name, got in (("swift", swift_candidates()),
                          ("wrapper", wrapper_candidates()),
                          ("install", install_candidates())):
            self.assertNotIn("python3", got, name)


class SwiftcCandidates(unittest.TestCase):
    """install.sh's pre-flight must accept every compiler build.sh would use,
    or --check reports a problem on a Mac where the build works."""

    @staticmethod
    def swiftc_list(src):
        match = re.search(r'for c in "\$\{SWIFTC_BIN:-\}" swiftc \\\n(.*?); do', src, re.S)
        assert match, "swiftc candidate loop not found"
        return re.findall(r"(/\S*swiftc)", match.group(1))

    def test_build_and_preflight_agree(self):
        self.assertEqual(self.swiftc_list(read("build.sh")),
                         self.swiftc_list(read("install.sh")))


if __name__ == "__main__":
    unittest.main()
