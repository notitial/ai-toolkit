import json
import os
import subprocess
import sys
import time
import unittest

from kit_helpers import CONFIG, KitCase, alive


class Cli(KitCase):
    def cli(self, *args, build=None):
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_PROJECT_DIR"}
        return subprocess.run([sys.executable, str(build or self.build), *args], capture_output=True, text=True,
                              env=env, timeout=60, cwd=str(self.tmp))

    def test_passed_run_prints_json_and_exits_zero(self):
        p = self.cli("ios", "build")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(json.loads(p.stdout)["ok"])

    def test_the_project_is_where_the_kit_is_installed(self):
        other = self.tmp / "other"
        other.mkdir()
        p = self.cli("ios", "build", build=self.install_kit(other))  # no .build-kit.json there
        self.assertEqual((p.returncode, json.loads(p.stdout)["status"]), (2, "refused"))
        self.assertEqual(self.calls(), [])

    def test_there_is_no_way_to_point_it_at_another_project(self):
        p = self.cli("ios", "build", "--project-dir", str(self.tmp))
        self.assertEqual(p.returncode, 2)
        self.assertIn("unrecognized arguments", p.stderr)
        self.assertEqual(self.calls(), [])

    def test_refusal_exits_two_and_failure_exits_one(self):
        p = self.cli("ios", "build", "--scheme", "x; touch pwned")
        self.assertEqual((p.returncode, json.loads(p.stdout)["status"]), (2, "refused"))
        self.fake(xcodebuild={"exit": 65})
        p = self.cli("ios", "build")
        self.assertEqual((p.returncode, json.loads(p.stdout)["status"]), (1, "failed"))

    def test_usage_errors(self):
        self.assertEqual(self.cli("ios").returncode, 2)
        self.assertEqual(self.cli("windows", "build").returncode, 2)


class Mcp(KitCase):
    def start(self, platform="ios"):
        p = subprocess.Popen([sys.executable, str(self.build), "--mcp", platform], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=str(self.tmp))
        self.addCleanup(self.stop, p)
        return p

    @staticmethod
    def stop(p):
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(15)
            except subprocess.TimeoutExpired:
                p.kill()
        p.wait()
        for f in (p.stdin, p.stdout, p.stderr):
            f.close()

    @staticmethod
    def send(p, **msg):
        p.stdin.write(json.dumps(dict(msg, jsonrpc="2.0")) + "\n")
        p.stdin.flush()

    @staticmethod
    def recv(p):
        line = p.stdout.readline()
        return json.loads(line) if line else None

    def wait_for_child(self):
        deadline = time.monotonic() + 10
        while not (self.home / "child.pid").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        return int((self.home / "child.pid").read_text())

    def test_handshake_list_and_call(self):
        p = self.start()
        self.send(p, id=1, method="initialize", params={"protocolVersion": "2025-03-26"})
        r = self.recv(p)["result"]
        self.assertEqual((r["protocolVersion"], r["capabilities"], r["serverInfo"]["name"]),
                         ("2025-03-26", {"tools": {}}, "build-kit-ios"))
        self.send(p, method="notifications/initialized")
        self.send(p, id=2, method="ping")
        self.assertEqual(self.recv(p), {"jsonrpc": "2.0", "id": 2, "result": {}})
        self.send(p, id=3, method="tools/list")
        tools = {t["name"]: t for t in self.recv(p)["result"]["tools"]}
        self.assertEqual(sorted(tools), ["build", "build_test", "lint", "test"])
        props = tools["build"]["inputSchema"]["properties"]
        self.assertEqual(props["scheme"]["enum"], CONFIG["ios"]["schemes"])
        self.assertEqual(props["destination"]["enum"], ["sim", "catalyst"])
        self.assertEqual(tools["lint"]["inputSchema"]["properties"], {})
        self.assertFalse(tools["build"]["inputSchema"]["additionalProperties"])
        self.send(p, id=4, method="tools/call", params={"name": "build", "arguments": {"scheme": "Other"}})
        reply = self.recv(p)["result"]
        self.assertFalse(reply["isError"])
        self.assertTrue(json.loads(reply["content"][0]["text"])["ok"])
        self.assertIn("Other", self.calls()[0]["argv"])

    def test_refusals_and_protocol_errors_keep_the_server_alive(self):
        p = self.start()
        self.send(p, id=1, method="tools/call", params={"name": "build", "arguments": {"scheme": "$(touch pwned)"}})
        reply = self.recv(p)["result"]
        self.assertTrue(reply["isError"])
        self.assertEqual(json.loads(reply["content"][0]["text"])["status"], "refused")
        self.send(p, id=2, method="tools/call", params={"name": "deploy", "arguments": {}})
        self.assertEqual(self.recv(p)["error"]["code"], -32602)
        self.send(p, id=3, method="tools/call", params={"name": "build", "arguments": "x"})
        self.assertEqual(self.recv(p)["error"]["code"], -32602)
        self.send(p, id=4, method="resources/list")
        self.assertEqual(self.recv(p)["error"]["code"], -32601)
        p.stdin.write("{not json\n[1]\n\n")
        p.stdin.flush()
        self.assertEqual(self.recv(p)["error"]["code"], -32700)
        self.assertEqual(self.recv(p)["error"]["code"], -32600)
        self.send(p, id=5, method="ping")
        self.assertEqual(self.recv(p)["id"], 5)
        self.assertEqual(self.calls(), [])

    def test_hostile_ids_and_duplicates_do_not_kill_the_server(self):
        self.fake(xcodebuild={"sleep": 2})
        p = self.start()
        for line in ('{"jsonrpc":"2.0","id":[1],"method":"tools/call","params":{"name":"build","arguments":{}}}',
                     '{"jsonrpc":"2.0","id":{},"method":"ping"}',
                     '{"jsonrpc":"2.0","id":true,"method":"ping"}',
                     "[" * 100000):
            p.stdin.write(line + "\n")
            p.stdin.flush()
        self.assertEqual([self.recv(p)["error"]["code"] for _ in range(4)], [-32600, -32600, -32600, -32700])
        self.send(p, method="notifications/cancelled", params={"requestId": [1]})
        self.send(p, id=1, method="tools/call", params={"name": "build", "arguments": {}})
        self.send(p, id=1, method="tools/call", params={"name": "build", "arguments": {}})
        self.assertEqual(self.recv(p)["error"]["code"], -32600)
        self.assertTrue(self.recv(p)["result"])
        self.send(p, id=2, method="ping")
        self.assertEqual(self.recv(p)["id"], 2)

    def test_tools_list_without_config_is_an_error_not_a_crash(self):
        os.remove(self.root / ".build-kit.json")
        p = self.start()
        self.send(p, id=1, method="tools/list")
        self.assertEqual(self.recv(p)["error"]["code"], -32603)

    def test_cancel_stops_the_build_and_sends_no_response(self):
        self.fake(xcodebuild={"sleep": 30, "spawn": True})
        p = self.start()
        self.send(p, id=7, method="tools/call", params={"name": "build", "arguments": {}})
        pid = self.wait_for_child()
        self.send(p, method="notifications/cancelled", params={"requestId": 7})
        deadline = time.monotonic() + 10
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(pid))
        self.send(p, id=8, method="ping")
        self.assertEqual(self.recv(p)["id"], 8)

    def test_closing_stdin_stops_a_running_build(self):
        self.fake(xcodebuild={"sleep": 30, "spawn": True})
        p = self.start()
        self.send(p, id=1, method="tools/call", params={"name": "build", "arguments": {}})
        pid = self.wait_for_child()
        p.stdin.close()
        self.assertEqual(p.wait(30), 0)
        self.assertFalse(alive(pid))

    def test_sigterm_stops_a_running_build(self):
        self.fake(xcodebuild={"sleep": 30, "spawn": True})
        p = self.start()
        self.send(p, id=1, method="tools/call", params={"name": "build", "arguments": {}})
        pid = self.wait_for_child()
        p.terminate()
        p.wait(30)
        self.assertFalse(alive(pid))

    def test_android_server_lists_variants(self):
        p = self.start("android")
        self.send(p, id=1, method="tools/list")
        tools = {t["name"]: t for t in self.recv(p)["result"]["tools"]}
        self.assertEqual(tools["lint"]["inputSchema"]["properties"]["variant"]["enum"], ["Debug", "Release"])


if __name__ == "__main__":
    unittest.main()
