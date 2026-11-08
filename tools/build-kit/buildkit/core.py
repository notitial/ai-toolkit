"""Shared pieces of build-kit: config and allow-lists, the child process, the lock, the result."""
import collections
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

# The only variables a child gets. Everything else in the parent environment (API keys, tokens) stays behind.
ENV_KEEP = ("PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "DEVELOPER_DIR",
            "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT", "GRADLE_USER_HOME")
LOCK_WAIT = 5            # seconds a second call waits for the lock before it returns busy
KILL_GRACE = 5           # seconds between TERM and KILL
KEEP_RUNS = 10           # run folders (log, result bundle) kept per project and platform
MAX_LIST = 50            # errors and failures listed in a result; the counts and the log cover the rest
MAX_LOG = 100 * 2 ** 20  # bytes of output after which the build is stopped

DIAG = re.compile(r"^(?P<file>[^\s:][^:]*?):(?P<line>\d+):(?:(?P<col>\d+):)? "
                  r"(?P<sev>error|warning): (?P<msg>.+)$")
NOFILE = re.compile(r"^(?:xcodebuild: )?(?P<sev>error): (?P<msg>.+)$")


class Refused(Exception):
    """A request the allow-lists or the config do not permit; nothing was run."""


def safe(value, what):
    """A config word that ends up as a command-line argument: no option look-alikes, no control characters."""
    if not isinstance(value, str) or not value or value.startswith("-") or any(c in value for c in "\n\r\0"):
        raise Refused("%s: unusable value %r in .build-kit.json" % (what, value))
    return value


def names(section, key, default=None):
    """A non-empty list of safe words from the config, or the default."""
    value = section.get(key, default)
    if not isinstance(value, list) or not value:
        raise Refused("%s: expected a non-empty list in .build-kit.json" % key)
    return [safe(v, key) for v in value]


def load(root, platform):
    """(platform section, project dir, timeout) from <root>/.build-kit.json."""
    try:
        cfg = json.loads((root / ".build-kit.json").read_text())
    except (OSError, ValueError) as e:
        raise Refused(".build-kit.json: %s" % e)
    section = cfg.get(platform) if isinstance(cfg, dict) else None
    if not isinstance(section, dict):
        raise Refused("no %r section in .build-kit.json" % platform)
    timeout = cfg.get("timeoutSeconds", 1800)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise Refused("timeoutSeconds must be a positive number")
    base = section.get("projectDir", ".")
    if not isinstance(base, str):
        raise Refused("projectDir must be a string")
    project = (root / base).resolve()
    if project != root and root not in project.parents:
        raise Refused("projectDir leaves the project")
    return section, project, timeout


def check(args, allowed):
    """The call's arguments, each one on its allow-list; a missing one takes the list's first entry."""
    out = {}
    for key, value in args.items():
        if value is None:
            continue
        if key not in allowed:
            raise Refused("unknown parameter %r (allowed: %s)" % (key, ", ".join(allowed) or "none"))
        if value not in allowed[key]:
            raise Refused("%s %r is not in the allow-list %s" % (key, value, allowed[key]))
        out[key] = value
    for key, values in allowed.items():
        out.setdefault(key, values[0])
    return out


def state_dir(root):
    """A private per-project folder for logs, result bundles, the lock and the SwiftLint cache.
    Keyed on the root's device and inode, so another spelling of the same path finds the same folder."""
    st = root.stat()
    key = hashlib.sha256(("%d:%d" % (st.st_dev, st.st_ino)).encode()).hexdigest()[:12]
    path = Path.home() / ".cache" / "build-kit" / key
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if path.is_symlink() or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise Refused("%s is not a private folder (owner or mode)" % path)
    return path


def acquire(path):
    """The open lock file, or None if another call keeps holding it for LOCK_WAIT seconds."""
    f = open(path, "a")
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except OSError:
            if time.monotonic() >= deadline:
                f.close()
                return None
            time.sleep(0.2)


def new_run(state, platform, action):
    runs = state / "runs" / platform
    runs.mkdir(parents=True, exist_ok=True)
    old = sorted(runs.iterdir(), key=lambda p: p.stat().st_mtime)
    for p in old[:-(KEEP_RUNS - 1)]:
        shutil.rmtree(p, ignore_errors=True)
    return Path(tempfile.mkdtemp(prefix="%s-%s-" % (time.strftime("%Y%m%d-%H%M%S"), action), dir=str(runs)))


def child_env():
    return {k: os.environ[k] for k in ENV_KEEP if k in os.environ}


def stop(proc):
    """TERM the child's process group, then KILL whatever is left in it."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(KILL_GRACE)
    except subprocess.TimeoutExpired:
        pass
    except ProcessLookupError:
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def execute(argv, cwd, log, timeout, cancel):
    """Run argv (never a shell) in its own process group, output to the log file.
    Returns (exit code or None, why it was stopped: "timeout", "cancelled", "log_limit" or None, seconds)."""
    start = time.monotonic()
    reason = None
    with open(log, "wb") as out:
        if cancel.is_set():
            return None, "cancelled", 0.0
        try:
            proc = subprocess.Popen(argv, cwd=str(cwd), env=child_env(), stdin=subprocess.DEVNULL,
                                    stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as e:
            out.write(("cannot start %s: %s\n" % (argv[0], e)).encode())
            return None, None, 0.0
        try:
            while proc.poll() is None:
                reason = ("cancelled" if cancel.wait(0.2) else
                          "timeout" if time.monotonic() - start > timeout else
                          "log_limit" if os.fstat(out.fileno()).st_size > MAX_LOG else None)
                if reason:
                    break
            if reason and proc.poll() is None:
                stop(proc)
            elif reason:
                reason = None  # it finished on its own just before the limit
        finally:
            if proc.poll() is None:
                stop(proc)
    return proc.returncode, reason, round(time.monotonic() - start, 1)


def capture(argv, cwd, timeout=60):
    """Stdout of a short helper command (same environment rules), or None if it failed."""
    try:
        r = subprocess.run(argv, cwd=str(cwd), env=child_env(), stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def lines(log):
    """The log line by line: a build log can be large, so nothing holds all of it."""
    with open(log, errors="replace") as f:
        for line in f:
            yield line.rstrip("\n")


def diagnostics(log, extra=()):
    """(first MAX_LIST errors, warning count, error count) from compiler-style lines.
    extra: regexes with groups file, line, col, sev, msg."""
    errors, warnings, count, seen = [], 0, 0, set()
    for line in lines(log):
        for rx in (DIAG, NOFILE) + tuple(extra):
            m = rx.match(line)
            if not m:
                continue
            g = m.groupdict()
            entry = {"file": g.get("file"), "line": int(g["line"]) if g.get("line") else None,
                     "col": int(g["col"]) if g.get("col") else None, "message": g["msg"].strip()}
            key = (entry["file"], entry["line"], entry["col"], entry["message"], g["sev"][0])
            if key not in seen:
                if len(seen) < 50000:  # a runaway log must not grow this without end
                    seen.add(key)
                if g["sev"][0] == "e":
                    count += 1
                    if len(errors) < MAX_LIST:
                        errors.append(entry)
                else:
                    warnings += 1
            break
    return errors, warnings, count


def run_action(mod, root, action, args, cancel):
    """One call: validate, lock, run, parse. Always returns a result dict; never raises."""
    try:
        if action not in mod.ACTIONS:
            raise Refused("unknown action %r (one of: %s)" % (action, ", ".join(mod.ACTIONS)))
        section, project, timeout = load(root, mod.NAME)
        args = check(args, mod.params(section, action))
        state = state_dir(root)
        lock = acquire(state / (mod.NAME + ".lock"))
        if lock is None:
            return {"ok": False, "status": "busy", "message": "another %s run holds this project's lock" % mod.NAME}
        try:
            run = new_run(state, mod.NAME, action)
            log = run / "build.log"
            argv = mod.plan(section, project, action, args, run, state)
            since = time.time()
            code, reason, seconds = execute(argv, project, log, timeout, cancel)
            parsed = mod.parse(section, project, action, run, log, since)
            tail = [line[:500] for line in collections.deque(lines(log), maxlen=25)]
        finally:
            lock.close()
    except Refused as e:
        return {"ok": False, "status": "refused", "message": str(e)}
    except Exception as e:
        return {"ok": False, "status": "error", "message": "%s: %s" % (type(e).__name__, e)}
    ok = code == 0 and not reason
    notes = parsed["notes"]
    if reason == "log_limit":
        notes.append("output passed %d MB: the build was stopped" % (MAX_LOG // 2 ** 20))
    if ok and parsed["error_count"]:
        notes.append("exit code 0, but %d errors are listed; the exit code decides ok" % parsed["error_count"])
    result = {"ok": ok, "status": reason or ("passed" if ok else "failed"), "exit_code": code, "duration_s": seconds,
              "timed_out": reason == "timeout", "error_count": parsed["error_count"],
              "errors": parsed["errors"], "warnings": parsed["warnings"], "notes": notes,
              "log": str(log), "tail": "\n".join(tail)}
    if "tests" in parsed:
        result["tests"] = parsed["tests"]
    return result
