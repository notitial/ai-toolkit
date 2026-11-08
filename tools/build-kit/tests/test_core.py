import os
import threading
import time
import unittest
from unittest import mock

from kit_helpers import CONFIG, KitCase, alive, core, ios

INJECTIONS = ["x; touch pwned", "$(touch pwned)", "`touch pwned`", "App\ntouch pwned", "App && touch pwned",
              "-resultBundlePath", "--help", "", "app", "App "]


class AllowLists(KitCase):
    def test_injection_strings_are_refused_before_anything_runs(self):
        for bad in INJECTIONS:
            for key, platform in (("scheme", "ios"), ("configuration", "ios"), ("destination", "ios"), ("variant", "android")):
                r = self.run_kit(platform, "build", **{key: bad})
                self.assertEqual(r["status"], "refused", (key, bad))
        self.assertEqual(self.calls(), [])
        self.assertFalse(any(p.name == "pwned" for p in self.tmp.rglob("*")))

    def test_non_string_values_and_unknown_parameters_are_refused(self):
        for bad in (1, ["App"], {"a": 1}, True):
            self.assertEqual(self.run_kit("ios", "build", scheme=bad)["status"], "refused")
        self.assertEqual(self.run_kit("ios", "build", derivedDataPath="/tmp/x")["status"], "refused")
        self.assertEqual(self.run_kit("ios", "lint", scheme="App")["status"], "refused")
        self.assertEqual(self.run_kit("android", "build", scheme="App")["status"], "refused")
        self.assertEqual(self.run_kit("ios", "clean")["status"], "refused")
        self.assertEqual(self.calls(), [])

    def test_defaults_are_the_first_entries(self):
        self.assertEqual(self.run_kit("ios", "build")["status"], "passed")
        argv = self.calls()[0]["argv"]
        self.assertEqual(argv[argv.index("-scheme") + 1], "App")
        self.assertEqual(argv[argv.index("-configuration") + 1], "Debug")
        self.assertEqual(argv[argv.index("-destination") + 1], "platform=iOS Simulator,name=iPhone 16")

    def test_config_words_that_look_like_options_are_refused(self):
        for key, value in (("schemes", ["-project"]), ("configurations", ["Debug\n-x"]), ("schemes", [])):
            self.edit_config("ios", **{key: value})
            self.assertEqual(self.run_kit("ios", "build")["status"], "refused", (key, value))
        self.edit_config("android", variants=["--init-script"])
        self.assertEqual(self.run_kit("android", "build")["status"], "refused")
        self.edit_config("android", lintTasks=["-Pfoo"])
        self.assertEqual(self.run_kit("android", "lint")["status"], "refused")
        self.assertEqual(self.calls(), [])


class Config(KitCase):
    def test_missing_malformed_and_incomplete_config(self):
        (self.root / ".build-kit.json").write_text("{not json")
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")
        self.config({"android": {}})
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")
        (self.root / ".build-kit.json").unlink()
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")

    def test_project_dir_cannot_leave_the_project(self):
        for bad in ("..", "../elsewhere", str(self.tmp), 5):
            self.edit_config("ios", projectDir=bad)
            self.assertEqual(self.run_kit("ios", "build")["status"], "refused", bad)
        (self.root / "link").symlink_to(self.tmp)
        self.edit_config("ios", projectDir="link")
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")

    def test_timeout_must_be_a_positive_number(self):
        for bad in (0, -1, "10", True, None, float("nan"), float("inf")):
            self.config(dict(CONFIG, timeoutSeconds=bad))
            self.assertEqual(self.run_kit("ios", "build")["status"], "refused", bad)

    def test_signing_setting_must_be_a_boolean(self):
        self.edit_config("ios", codeSigning="false")
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")
        self.assertEqual(self.calls(), [])

    def test_another_spelling_of_the_root_finds_the_same_state(self):
        link = self.tmp / "alias"
        link.symlink_to(self.root)
        self.assertEqual(core.state_dir(link), core.state_dir(self.root))

    def test_state_dir_must_be_private(self):
        state = core.state_dir(self.root)
        self.assertEqual(state.stat().st_mode & 0o777, 0o700)
        state.chmod(0o770)
        self.assertEqual(self.run_kit("ios", "build")["status"], "refused")
        self.assertEqual(self.calls(), [])


class Process(KitCase):
    def test_child_environment_is_the_allow_list(self):
        self.assertTrue(self.run_kit("ios", "build")["ok"])
        env = self.calls()[0]["env"]
        self.assertNotIn("SECRET_TOKEN", env)
        self.assertEqual(env["HOME"], str(self.home))
        self.assertIn(str(self.bin), env["PATH"])
        self.assertLessEqual(set(env) - {"LC_CTYPE", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL"}, set(core.ENV_KEEP))

    def test_failure_result_has_the_documented_fields(self):
        self.fake(xcodebuild={"exit": 65, "out": "/p/A.swift:3:7: error: boom\n** BUILD FAILED **\n"})
        r = self.run_kit("ios", "build")
        self.assertFalse(r["ok"])
        self.assertEqual((r["status"], r["exit_code"], r["timed_out"]), ("failed", 65, False))
        self.assertEqual(r["errors"], [{"file": "/p/A.swift", "line": 3, "col": 7, "message": "boom"}])
        self.assertEqual(r["error_count"], 1)
        self.assertIn("BUILD FAILED", r["tail"])
        self.assertTrue(r["log"].startswith(str(self.home / ".cache" / "build-kit")))
        self.assertIn("duration_s", r)

    def test_missing_tool_is_a_failed_result_not_a_crash(self):
        os.environ["PATH"] = str(self.tmp / "empty")
        r = self.run_kit("ios", "build")
        self.assertEqual((r["ok"], r["status"], r["exit_code"]), (False, "failed", None))
        self.assertIn("cannot start xcodebuild", r["tail"])

    def test_timeout_kills_the_whole_process_group(self):
        self.config(dict(CONFIG, timeoutSeconds=1))
        self.fake(xcodebuild={"sleep": 30, "spawn": True})
        started = time.monotonic()
        r = self.run_kit("ios", "build")
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual((r["status"], r["timed_out"], r["ok"]), ("timeout", True, False))
        pid = int((self.home / "child.pid").read_text())
        time.sleep(0.3)
        self.assertFalse(alive(pid))

    def test_cancel_kills_the_group_and_reports_cancelled(self):
        self.fake(xcodebuild={"sleep": 30, "spawn": True})
        cancel = threading.Event()
        threading.Timer(1.5, cancel.set).start()
        started = time.monotonic()
        r = self.run_kit("ios", "build", cancel=cancel)
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual((r["status"], r["ok"]), ("cancelled", False))
        pid = int((self.home / "child.pid").read_text())
        time.sleep(0.3)
        self.assertFalse(alive(pid))


class Limits(KitCase):
    def test_runaway_output_stops_the_build(self):
        self.fake(xcodebuild={"out": "x" * 200000, "sleep": 30, "spawn": True})
        with mock.patch.object(core, "MAX_LOG", 1000):
            r = self.run_kit("ios", "build")
        self.assertEqual((r["status"], r["ok"]), ("log_limit", False))
        self.assertIn("stopped", r["notes"][0])
        time.sleep(0.3)
        self.assertFalse(alive(int((self.home / "child.pid").read_text())))

    def test_a_cancel_before_the_start_runs_nothing(self):
        cancel = threading.Event()
        cancel.set()
        self.assertEqual(self.run_kit("ios", "build", cancel=cancel)["status"], "cancelled")
        self.assertEqual(self.calls(), [])

    def test_exit_zero_with_listed_errors_stays_ok_with_a_note(self):
        self.fake(xcodebuild={"out": "/p/A.swift:3:7: error: boom\n"})
        r = self.run_kit("ios", "build")
        self.assertEqual((r["ok"], r["error_count"]), (True, 1))
        self.assertIn("exit code 0", r["notes"][0])

    def test_a_long_log_is_streamed_and_the_tail_is_bounded(self):
        self.fake(xcodebuild={"out": "".join("line %d %s\n" % (i, "y" * 900) for i in range(3000))})
        r = self.run_kit("ios", "build")
        self.assertEqual(len(r["tail"].splitlines()), 25)
        self.assertLess(len(r["tail"]), 25 * 501)
        self.assertIn("line 2999", r["tail"])


class Locking(KitCase):
    def test_second_call_gets_busy_and_runs_nothing(self):
        held = core.acquire(core.state_dir(self.root) / "ios.lock")
        self.addCleanup(held.close)
        r = self.run_kit("ios", "build")
        self.assertEqual((r["ok"], r["status"]), (False, "busy"))
        self.assertEqual(self.calls(), [])

    def test_other_platform_and_released_lock_are_free(self):
        held = core.acquire(core.state_dir(self.root) / "ios.lock")
        self.assertTrue(self.run_kit("android", "build")["ok"])
        held.close()
        self.assertTrue(self.run_kit("ios", "build")["ok"])

    def test_concurrent_calls_do_not_overlap(self):
        self.fake(xcodebuild={"sleep": 2})
        results = []
        t = threading.Thread(target=lambda: results.append(self.run_kit("ios", "build")))
        t.start()
        time.sleep(0.8)
        second = self.run_kit("ios", "build")
        t.join()
        self.assertEqual(second["status"], "busy")
        self.assertTrue(results[0]["ok"])
        self.assertEqual(len(self.calls()), 1)


class Runs(KitCase):
    def test_only_the_newest_runs_are_kept(self):
        for _ in range(core.KEEP_RUNS + 3):
            self.run_kit("android", "build")
            time.sleep(0.02)
        runs = list((core.state_dir(self.root) / "runs" / "android").iterdir())
        self.assertEqual(len(runs), core.KEEP_RUNS)

    def test_swiftlint_cache_and_result_bundle_live_in_the_private_folder(self):
        self.run_kit("ios", "lint")
        self.run_kit("ios", "test")
        state = str(core.state_dir(self.root))
        lint = [c for c in self.calls() if c["tool"] == "swiftlint" and c["argv"][0] == "lint"][0]["argv"]
        self.assertTrue(lint[lint.index("--cache-path") + 1].startswith(state))
        test = [c for c in self.calls() if c["tool"] == "xcodebuild"][0]["argv"]
        self.assertTrue(test[test.index("-resultBundlePath") + 1].startswith(state))


if __name__ == "__main__":
    unittest.main()
