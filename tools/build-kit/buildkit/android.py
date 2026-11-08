"""Android: the project's Gradle wrapper (assemble, unit tests, lint and detekt)."""
import os
import re
import stat
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.parsers import expat

from . import core

NAME = "android"
ACTIONS = ("build", "test", "lint", "build_test")
MAX_REPORT = 5 * 1024 * 1024
KOTLIN = re.compile(r"^(?P<sev>[ew]): (?:file://)?(?P<file>.+?):(?P<line>\d+):(?P<col>\d+) (?P<msg>.+)$")


def params(section, action):
    return {"variant": core.names(section, "variants", ["Debug"])}


def tasks(section, action, variant):
    def sub(task):
        return task.replace("{Variant}", variant)
    if action == "lint":
        return [sub(t) for t in core.names(section, "lintTasks", ["lint{Variant}", "detekt"])]
    out = []
    if action in ("build", "build_test"):
        out.append(sub(core.safe(section.get("buildTask", "assemble{Variant}"), "buildTask")))
    if action in ("test", "build_test"):
        out.append(sub(core.safe(section.get("testTask", "test{Variant}UnitTest"), "testTask")))
    return out


def plan(section, project, action, args, run, state):
    argv = [str(project / "gradlew")] + tasks(section, action, args["variant"]) + ["--console=plain"]
    if action == "lint":
        argv.append("--continue")  # lint and detekt both report, even when the first fails
    return argv


def report_files(project, pattern):
    """Regular files matching <module>/build/<pattern>, for every module under the project. Symlinks, hidden
    folders, node_modules and build outputs are not walked."""
    for folder, dirs, _ in os.walk(str(project)):
        if "build" in dirs and not os.path.islink(os.path.join(folder, "build")):
            yield from sorted(Path(folder, "build").glob(pattern))
        dirs[:] = [d for d in dirs if d != "build" and d != "node_modules" and not d.startswith(".")]


def reports(project, pattern, since, notes):
    """XML roots of the reports written during this run, one at a time. A report that is not a regular file, over MAX_REPORT bytes
    or has a DOCTYPE or ENTITY declaration is skipped with a note (the standard library XML parser is not hardened)."""
    for f in report_files(project, pattern):
        try:
            fd = os.open(str(f), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)  # never a link, never blocks on a pipe
            with os.fdopen(fd, "rb") as fh:
                st = os.fstat(fh.fileno())
                if not stat.S_ISREG(st.st_mode) or st.st_mtime < since - 1:
                    continue
                data = fh.read(MAX_REPORT + 1)
            if len(data) > MAX_REPORT:
                raise ValueError("over %d bytes" % MAX_REPORT)
            scan = expat.ParserCreate()

            def refuse(*_):
                raise ValueError("has a DOCTYPE or ENTITY declaration")
            scan.StartDoctypeDeclHandler = scan.EntityDeclHandler = refuse
            scan.Parse(data, True)
            yield ET.fromstring(data)
        except (OSError, ValueError, ET.ParseError, expat.ExpatError) as e:
            notes.append("skipped report %s: %s" % (f.name, e))


def parse(section, project, action, run, log, since):
    errors, warnings, count = core.diagnostics(log, (KOTLIN,))
    notes = []
    out = {"errors": errors, "warnings": warnings, "notes": notes}
    if action == "lint":
        found = 0
        for root in reports(project, "reports/lint-results-*.xml", since, notes):
            found += 1
            for issue in root.iter("issue"):
                loc = issue.find("location")
                where = loc.attrib if loc is not None else {}
                if issue.get("severity") in ("Error", "Fatal"):
                    count += 1
                    if len(errors) < core.MAX_LIST:
                        errors.append(entry(where.get("file"), where.get("line"), where.get("column"), issue.get("message")))
                else:
                    out["warnings"] += 1
        for root in reports(project, "reports/detekt/*.xml", since, notes):
            found += 1
            for f in root.iter("file"):
                for e in f.iter("error"):
                    if e.get("severity") == "error":
                        count += 1
                        if len(errors) < core.MAX_LIST:
                            errors.append(entry(f.get("name"), e.get("line"), e.get("column"), e.get("message")))
                    else:
                        out["warnings"] += 1
        if not found:
            notes.append("no lint or detekt report was written in this run (Gradle may have skipped the tasks as up to date)")
    if action in ("test", "build_test"):
        t = {"passed": 0, "failed": 0, "skipped": 0, "failures": [], "source": "none"}
        for suite in reports(project, "test-results/*/*.xml", since, notes):
            t["source"] = "junit"
            failed = int(suite.get("failures", 0)) + int(suite.get("errors", 0))
            skipped = int(suite.get("skipped", 0))
            t["failed"] += failed
            t["skipped"] += skipped
            t["passed"] += int(suite.get("tests", 0)) - failed - skipped
            for case in suite.iter("testcase"):
                bad = case.find("failure") if case.find("failure") is not None else case.find("error")
                if bad is not None and len(t["failures"]) < core.MAX_LIST:
                    t["failures"].append({"test": "%s.%s" % (case.get("classname"), case.get("name")),
                                          "message": bad.get("message")})
        if t["source"] == "none":
            notes.append("no test report was written in this run (Gradle may have skipped the task as up to date)")
        out["tests"] = t
    out["error_count"] = count
    return out


def entry(file, line, col, message):
    return {"file": file, "line": int(line or 0) or None, "col": int(col or 0) or None, "message": message or ""}
