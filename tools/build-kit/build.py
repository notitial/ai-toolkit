#!/usr/bin/env python3
"""build-kit: build, test and lint an iOS or Android project with allow-listed arguments.

  build.py <ios|android> <build|test|lint|build_test> [--scheme S] [--configuration C] [--destination D] [--variant V]
  build.py --mcp <ios|android>        MCP server on stdio, the same four actions as tools

The kit works on the project it is installed in: this file lives at <project>/tools/build-kit/build.py, and the
project's .build-kit.json holds the allow-lists. Prints one JSON result; exit 0 passed, 2 refused, 1 anything else.
Python 3.9+, standard library only.
"""
import argparse
import json
import signal
import sys
import threading
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the project that carries this copy
sys.path.insert(0, str(Path(__file__).resolve().parent))
from buildkit import android, core, ios  # noqa: E402

PLATFORMS = {"ios": ios, "android": android}
PARAMS = ("scheme", "configuration", "destination", "variant")
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
SUMMARY = {"build": "Build", "test": "Run the unit tests of", "lint": "Lint", "build_test": "Build and test, in one call,"}
ROOT = Path(__file__).resolve().parents[2]


def tool_list(mod):
    section = core.load(ROOT, mod.NAME)[0]
    tools = []
    for action in mod.ACTIONS:
        props = {k: {"type": "string", "enum": v, "default": v[0]} for k, v in mod.params(section, action).items()}
        tools.append({"name": action, "description": "%s the %s project." % (SUMMARY[action], mod.NAME),
                      "inputSchema": {"type": "object", "properties": props, "additionalProperties": False}})
    return tools


def serve(mod):
    """MCP over stdio, one JSON message per line. A call runs in its own thread so pings and cancels get through."""
    out_lock = threading.Lock()
    cancels, workers = {}, []

    def send(message):
        with out_lock:
            sys.stdout.write(json.dumps(dict(message, jsonrpc="2.0"), separators=(",", ":")) + "\n")
            sys.stdout.flush()

    def fail(i, code, text):
        send({"id": i, "error": {"code": code, "message": text}})

    def call(i, action, arguments, cancel):
        result = core.run_action(mod, ROOT, action, arguments, cancel)
        cancels.pop(i, None)
        if not cancel.is_set():  # a cancelled call gets no response
            send({"id": i, "result": {"content": [{"type": "text", "text": json.dumps(result)}],
                                      "isError": not result["ok"]}})

    def handle(msg):
        method, i, p = msg.get("method"), msg.get("id"), msg.get("params")
        p = p if isinstance(p, dict) else {}
        if "id" in msg and (isinstance(i, bool) or not isinstance(i, (int, str))):
            return fail(None, -32600, "invalid request id")
        if method == "initialize":
            wanted = p.get("protocolVersion")
            send({"id": i, "result": {"protocolVersion": wanted if wanted in PROTOCOLS else PROTOCOLS[0],
                                      "capabilities": {"tools": {}},
                                      "serverInfo": {"name": "build-kit-" + mod.NAME, "version": "1"}}})
        elif method == "ping":
            send({"id": i, "result": {}})
        elif method == "tools/list":
            send({"id": i, "result": {"tools": tool_list(mod)}})
        elif method == "tools/call" and "id" in msg:  # without an id it is a notification: nothing to run or answer
            arguments = p.get("arguments") or {}
            if p.get("name") not in mod.ACTIONS or not isinstance(arguments, dict):
                fail(i, -32602, "unknown tool or bad arguments")
            elif i in cancels:
                fail(i, -32600, "request id %r is already running" % (i,))
            else:
                cancels[i] = cancel = threading.Event()
                workers.append(threading.Thread(target=call, args=(i, p["name"], arguments, cancel), daemon=True))
                workers[-1].start()
        elif method == "notifications/cancelled":
            event = cancels.get(p.get("requestId")) if isinstance(p.get("requestId"), (int, str)) else None
            if event:
                event.set()
        elif "id" in msg and method is not None:
            fail(i, -32601, "method not found")

    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except (ValueError, RecursionError):
                fail(None, -32700, "parse error")
                continue
            if not isinstance(msg, dict):
                fail(None, -32600, "invalid request")
                continue
            try:
                handle(msg)
            except core.Refused as e:
                fail(msg.get("id"), -32603, str(e))
            except Exception as e:
                fail(msg.get("id") if isinstance(msg.get("id"), (int, str)) else None, -32603, "%s: %s" % (type(e).__name__, e))
    finally:  # the client is gone: stop what it started
        for event in list(cancels.values()):
            event.set()
        for t in workers:
            t.join(2 * core.KILL_GRACE + 5)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mcp", action="store_true", help="serve MCP on stdio")
    ap.add_argument("platform", choices=sorted(PLATFORMS))
    ap.add_argument("action", nargs="?")
    for name in PARAMS:
        ap.add_argument("--" + name)
    opts = ap.parse_args(argv)
    mod = PLATFORMS[opts.platform]
    for sig in (signal.SIGTERM, signal.SIGHUP):  # run the cleanup that stops the build's process group
        signal.signal(sig, lambda *_: sys.exit(143))
    if opts.mcp:
        serve(mod)
        return 0
    if not opts.action:
        ap.error("an action is required")
    arguments = {k: getattr(opts, k) for k in PARAMS if getattr(opts, k) is not None}
    result = core.run_action(mod, ROOT, opts.action, arguments, threading.Event())
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 2 if result["status"] == "refused" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
