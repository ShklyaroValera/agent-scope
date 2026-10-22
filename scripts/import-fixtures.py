#!/usr/bin/env python3
"""Copy raw hook payloads captured by `agentscope hook` (keep-raw-payloads mode) into Tests/Fixtures,
numbered in arrival order, with local paths replaced by neutral ones.

Usage: scripts/import-fixtures.py <payload-dir> <agent> <version> <capture-cwd>
"""
import json
import os
import re
import sys

src, agent, version, cwd = sys.argv[1:5]
home = os.path.expanduser("~")
dest = os.path.join(os.path.dirname(__file__), "..", "Tests", "Fixtures", agent, version)
os.makedirs(dest, exist_ok=True)

def mangle(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)

replacements = [
    (os.path.realpath(cwd), "/Users/me/dev/demo"),
    (cwd, "/Users/me/dev/demo"),
    (mangle(os.path.realpath(cwd)), "-Users-me-dev-demo"),
    (mangle(cwd), "-Users-me-dev-demo"),
    (home, "/Users/me"),
    (mangle(home), "-Users-me"),
    (os.environ.get("USER", "me"), "me"),
]

def scrub(value):
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items()}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, str):
        for old, new in replacements:
            if old:
                value = value.replace(old, new)
        # Scratch directories outside the capture cwd.
        value = re.sub(r"/private/tmp/[^\s\"]*", "/tmp/scratch", value)
        value = re.sub(r"-private-tmp-[A-Za-z0-9-]*", "-tmp-scratch", value)
    return value

names = sorted(name for name in os.listdir(src) if name.endswith(".json"))
for index, name in enumerate(names, 1):
    event = name.split("-")[1]
    with open(os.path.join(src, name)) as handle:
        payload = json.load(handle)
    out = os.path.join(dest, f"{index:02d}-{event}.json")
    with open(out, "w") as handle:
        json.dump(scrub(payload), handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(out)
