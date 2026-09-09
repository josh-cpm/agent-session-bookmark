#!/usr/bin/env python3
"""asb_config.py — read and change Agent Session Bookmark settings.

Settings live in config.json in the support folder (see asb_paths.py). The panel
watches that file and applies changes within a second or two.

Usage:
  asb_config.py show                 effective settings as JSON (defaults + your overrides)
  asb_config.py get <key>            one value
  asb_config.py set <key> <value>    change one setting (ignore_cwds: comma-separated paths)
  asb_config.py add <key> <value>    append to a list setting (ignore_cwds)
  asb_config.py remove <key> <value> drop from a list setting
  asb_config.py unset <key>          back to the default
  asb_config.py keys                 list settings with their meaning and default
  asb_config.py path                 where config.json is

Exit status 0 on success, 2 on a bad key or value (message on stderr). Stdlib only.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asb_paths  # noqa: E402


def show(path):
    config = asb_paths.load_config(path)
    config["ignore_cwds"] = asb_paths.read_config_file(path).get("ignore_cwds", [])  # as written, not expanded
    return config


def main(argv, path=asb_paths.CONFIG_PATH):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "show":
        print(json.dumps(show(path), indent=2, sort_keys=True))
        return 0
    if cmd == "path":
        print(path)
        return 0
    if cmd == "keys":
        for key, default in asb_paths.DEFAULT_CONFIG.items():
            print(f"{key:14} {asb_paths.SETTING_HELP[key]}  (default: {json.dumps(default)})")
        return 0
    if cmd in ("get", "unset") and len(argv) == 3:
        key = argv[2]
        if key not in asb_paths.DEFAULT_CONFIG:
            sys.stderr.write(f"unknown setting {key!r}; known: {', '.join(asb_paths.DEFAULT_CONFIG)}\n")
            return 2
        if cmd == "get":
            print(json.dumps(show(path)[key]))
            return 0
        user = asb_paths.read_config_file(path)
        user.pop(key, None)
        asb_paths.write_config_file(user, path)
        print(f"{key} reset to default {json.dumps(asb_paths.DEFAULT_CONFIG[key])}")
        return 0
    if cmd in ("set", "add", "remove") and len(argv) >= 4:
        key, raw = argv[2], " ".join(argv[3:])
        user = asb_paths.read_config_file(path)
        try:
            if cmd == "set":
                value = asb_paths.validate(key, raw)
            else:
                if key != "ignore_cwds":
                    raise ValueError(f"{cmd} only applies to list settings (ignore_cwds)")
                current = list(user.get("ignore_cwds") or [])
                items = asb_paths.validate(key, raw)
                if cmd == "add":
                    value = current + [p for p in items if p not in current]
                else:
                    value = [p for p in current if p not in items]
        except ValueError as err:
            sys.stderr.write(f"{err}\n")
            return 2
        user[key] = value
        asb_paths.write_config_file(user, path)
        print(f"{key} = {json.dumps(value)}")
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
