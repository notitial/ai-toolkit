#!/usr/bin/env python3
"""Stands in for xcodebuild, xcrun, swiftlint and gradlew. It appends the call (argv, environment, cwd) to
$HOME/calls.log, then does what $HOME/fake.json says for its name (or "<name> <first argument>"):
out (stdout text), exit, sleep (seconds), spawn (leave a `sleep 60` child, its pid in $HOME/child.pid),
files and stale_files ({path relative to the cwd: content}; stale ones get an old modification time)."""
import json
import os
import subprocess
import sys
import time

name = os.path.basename(sys.argv[0])
home = os.environ["HOME"]
with open(home + "/calls.log", "a") as f:
    f.write(json.dumps({"tool": name, "argv": sys.argv[1:], "env": dict(os.environ), "cwd": os.getcwd()}) + "\n")
try:
    with open(home + "/fake.json") as f:
        plans = json.load(f)
except OSError:
    plans = {}
plan = plans.get(name + " " + (sys.argv[1] if len(sys.argv) > 1 else ""), plans.get(name, {}))
for key, old in (("files", False), ("stale_files", True)):
    for rel, content in plan.get(key, {}).items():
        os.makedirs(os.path.dirname(os.path.abspath(rel)), exist_ok=True)
        with open(rel, "w") as f:
            f.write(content)
        if old:
            os.utime(rel, (1, 1))
sys.stdout.write(plan.get("out", ""))
sys.stdout.flush()
if plan.get("spawn"):
    with open(home + "/child.pid", "w") as f:
        f.write(str(subprocess.Popen(["sleep", "60"]).pid))
time.sleep(plan.get("sleep", 0))
sys.exit(plan.get("exit", 0))
