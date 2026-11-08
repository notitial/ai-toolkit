"""iOS: xcodebuild and SwiftLint."""
import json
import re

from . import core

NAME = "ios"
ACTIONS = ("build", "test", "lint", "build_test")
TEST_LINE = re.compile(r"^Test [Cc]ase '(?P<name>.+?)' (?P<result>passed|failed|skipped)")


def params(section, action):
    """The model-supplied values and their allow-lists (the first entry is the default)."""
    if action == "lint":
        return {}
    allowed = {"scheme": core.names(section, "schemes"),
               "configuration": core.names(section, "configurations", ["Debug"])}
    dests = section.get("destinations")
    if dests:
        if not isinstance(dests, dict) or not all(isinstance(v, str) and v for v in dests.values()):
            raise core.Refused("destinations: expected a name -> destination string map")
        allowed["destination"] = list(dests)
    return allowed


def plan(section, project, action, args, run, state):
    if action == "lint":
        lint = section.get("swiftlint") or {}
        extra = lint.get("args", [])
        if not isinstance(extra, list) or not all(isinstance(a, str) for a in extra):
            raise core.Refused("swiftlint.args: expected a list of strings")
        return ["swiftlint", "lint", "--cache-path", str(state / "swiftlint-cache")] + extra
    argv = ["xcodebuild"]
    for key in ("workspace", "project"):
        if section.get(key):
            argv += ["-" + key, core.safe(section[key], key)]
    argv += ["-scheme", args["scheme"], "-configuration", args["configuration"]]
    if "destination" in args:
        argv += ["-destination", section["destinations"][args["destination"]]]
    if action != "build":
        argv += ["-resultBundlePath", str(run / "result.xcresult")]
    signing = section.get("codeSigning", False)
    if not isinstance(signing, bool):
        raise core.Refused("codeSigning must be true or false")
    if not signing:
        argv.append("CODE_SIGNING_ALLOWED=NO")
    # xcodebuild test builds first, so build_test is the same single call as test.
    return argv + ["build" if action == "build" else "test"]


def parse(section, project, action, run, log, since):
    errors, warnings, count = core.diagnostics(log)
    out = {"errors": errors, "warnings": warnings, "error_count": count, "notes": []}
    if action == "lint":
        pinned = (section.get("swiftlint") or {}).get("version")
        have = core.capture(["swiftlint", "version"], project)
        if pinned and have and have.strip() != pinned:
            out["notes"].append("swiftlint %s ran, but .build-kit.json pins %s" % (have.strip(), pinned))
    elif action != "build":
        out["tests"] = tests(run, project, log)
        if out["tests"]["source"] == "log" and not any(out["tests"][k] for k in ("passed", "failed", "skipped")):
            out["notes"].append("no test results found in the xcresult or the log")
    return out


def tests(run, project, log):
    """Counts and failures from the xcresult summary, else from XCTest log lines."""
    raw = core.capture(["xcrun", "xcresulttool", "get", "test-results", "summary",
                        "--path", str(run / "result.xcresult"), "--format", "json"], project)
    try:
        s = json.loads(raw) if raw else None
    except ValueError:
        s = None
    if isinstance(s, dict) and "passedTests" in s:
        failures = [{"test": f.get("testName"), "message": f.get("failureText")} for f in s.get("testFailures") or []]
        return {"passed": s.get("passedTests", 0), "failed": s.get("failedTests", 0),
                "skipped": s.get("skippedTests", 0), "failures": failures[:core.MAX_LIST], "source": "xcresult"}
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    failures = []
    for line in core.lines(log):
        m = TEST_LINE.match(line)
        if m:
            counts[m["result"]] += 1
            if m["result"] == "failed" and len(failures) < core.MAX_LIST:
                failures.append({"test": m["name"], "message": None})
    return dict(counts, failures=failures[:core.MAX_LIST], source="log")
