import os
import time
import unittest

from kit_helpers import KitCase

XCRESULT = ('{"passedTests": 7, "failedTests": 2, "skippedTests": 1, "totalTestCount": 10, "testFailures": ['
            '{"testName": "testA()", "failureText": "XCTAssertEqual failed"}, {"testName": "testB()", "failureText": "nil"}]}')
LINT_XML = ('<issues><issue severity="Error" message="Missing permission"><location file="src/A.kt" line="4" column="9"/></issue>'
            '<issue severity="Fatal" message="Crash"><location file="src/B.kt" line="1"/></issue>'
            '<issue severity="Warning" message="Unused"><location file="src/C.kt" line="2"/></issue></issues>')
DETEKT_XML = ('<checkstyle><file name="src/D.kt"><error line="8" column="1" severity="error" message="TooLong"/>'
              '<error line="9" column="2" severity="warning" message="Magic"/></file></checkstyle>')
JUNIT_XML = ('<testsuite tests="5" failures="1" errors="1" skipped="1"><testcase classname="a.B" name="ok"/>'
             '<testcase classname="a.B" name="bad"><failure message="expected 1"/></testcase>'
             '<testcase classname="a.B" name="boom"><error message="npe"/></testcase></testsuite>')


class IosArguments(KitCase):
    def test_build_is_one_argument_list_with_signing_off(self):
        self.assertTrue(self.run_kit("ios", "build", scheme="Other", configuration="Release", destination="catalyst")["ok"])
        (call,) = self.calls()
        self.assertEqual(call["argv"], ["-workspace", "App.xcworkspace", "-scheme", "Other", "-configuration", "Release",
                                        "-destination", "platform=macOS,variant=Mac Catalyst",
                                        "CODE_SIGNING_ALLOWED=NO", "build"])
        self.assertEqual(call["cwd"], str(self.root / "ios"))

    def test_signing_can_be_turned_on_in_the_config(self):
        self.edit_config("ios", codeSigning=True)
        self.run_kit("ios", "build")
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", self.calls()[0]["argv"])

    def test_build_test_and_test_are_one_xcodebuild_test_call(self):
        for action in ("test", "build_test"):
            (self.home / "calls.log").unlink(missing_ok=True)
            self.run_kit("ios", action)
            xcodebuild = [c for c in self.calls() if c["tool"] == "xcodebuild"]
            self.assertEqual(len(xcodebuild), 1, action)
            self.assertEqual(xcodebuild[0]["argv"][-1], "test")
            self.assertIn("-resultBundlePath", xcodebuild[0]["argv"])

    def test_project_instead_of_workspace(self):
        self.edit_config("ios", workspace=None, project="App.xcodeproj")
        self.run_kit("ios", "build")
        self.assertEqual(self.calls()[0]["argv"][:2], ["-project", "App.xcodeproj"])


class IosParsing(KitCase):
    def test_diagnostics_are_deduplicated_and_warnings_counted(self):
        out = ("/a/My App/X.swift:10:5: error: cannot find 'foo'\n/a/My App/X.swift:11:1: warning: unused\n"
               "/a/My App/X.swift:10:5: error: cannot find 'foo'\n/a/Y.swift:3: error: no column\n"
               "error: Signing for \"App\" requires a development team.\n   not a diagnostic: error: indented\n")
        self.fake(xcodebuild={"exit": 65, "out": out})
        r = self.run_kit("ios", "build")
        self.assertEqual(r["warnings"], 1)
        self.assertEqual([(e["file"], e["line"], e["col"]) for e in r["errors"]],
                         [("/a/My App/X.swift", 10, 5), ("/a/Y.swift", 3, None), (None, None, None)])

    def test_test_counts_come_from_the_xcresult_summary(self):
        self.fake(xcodebuild={"exit": 65}, xcrun__xcresulttool={"out": XCRESULT})
        r = self.run_kit("ios", "test")
        self.assertEqual((r["tests"]["passed"], r["tests"]["failed"], r["tests"]["skipped"]), (7, 2, 1))
        self.assertEqual(r["tests"]["failures"][0], {"test": "testA()", "message": "XCTAssertEqual failed"})
        self.assertEqual(r["tests"]["source"], "xcresult")
        xcrun = [c for c in self.calls() if c["tool"] == "xcrun"][0]["argv"]
        self.assertEqual(xcrun[:4], ["xcresulttool", "get", "test-results", "summary"])

    def test_test_counts_fall_back_to_the_log(self):
        out = ("Test Case '-[T a]' passed (0.1 seconds).\nTest Case '-[T b]' failed (0.1 seconds).\n"
               "Test case 'T.c()' skipped on 'x'\nTest Case '-[T d]' passed (0.1 seconds).\n")
        self.fake(xcodebuild={"exit": 65, "out": out}, xcrun__xcresulttool={"exit": 1})
        t = self.run_kit("ios", "build_test")["tests"]
        self.assertEqual((t["passed"], t["failed"], t["skipped"], t["source"]), (2, 1, 1, "log"))
        self.assertEqual(t["failures"], [{"test": "-[T b]", "message": None}])

    def test_a_run_without_any_result_says_so(self):
        r = self.run_kit("ios", "test")
        self.assertEqual(r["tests"]["source"], "log")
        self.assertIn("no test results", r["notes"][0])

    def test_build_has_no_test_counts(self):
        self.assertNotIn("tests", self.run_kit("ios", "build"))


class SwiftLint(KitCase):
    def test_lint_runs_with_the_configured_args_and_reports_diagnostics(self):
        self.fake(swiftlint__lint={"exit": 2, "out": "/p/A.swift:4:2: error: Force Cast Violation (force_cast)\n"
                                                      "/p/A.swift:9:1: warning: Line Length (line_length)\n"},
                  swiftlint__version={"out": "0.57.0\n"})
        r = self.run_kit("ios", "lint")
        self.assertEqual((r["ok"], r["error_count"], r["warnings"], r["notes"]), (False, 1, 1, []))
        lint = [c for c in self.calls() if c["argv"][:1] == ["lint"]]
        self.assertEqual(lint[0]["argv"][-1], "--strict")
        self.assertEqual(lint[0]["cwd"], str(self.root / "ios"))

    def test_version_mismatch_warns_and_still_runs_the_local_version(self):
        self.fake(swiftlint__version={"out": "0.50.3\n"})
        r = self.run_kit("ios", "lint")
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["notes"]), 1)
        self.assertIn("0.50.3", r["notes"][0])
        self.assertIn("0.57.0", r["notes"][0])

    def test_matching_version_has_no_note(self):
        self.fake(swiftlint__version={"out": "0.57.0\n"})
        self.assertEqual(self.run_kit("ios", "lint")["notes"], [])


class AndroidArguments(KitCase):
    def test_build_and_test_tasks_use_the_variant(self):
        self.run_kit("android", "build", variant="Release")
        self.run_kit("android", "test")
        self.assertEqual([c["argv"] for c in self.calls()],
                         [["assembleRelease", "--console=plain"], ["testDebugUnitTest", "--console=plain"]])
        self.assertEqual(self.calls()[0]["cwd"], str(self.root / "android"))

    def test_build_test_is_one_gradle_call(self):
        self.run_kit("android", "build_test")
        (call,) = self.calls()
        self.assertEqual(call["argv"], ["assembleDebug", "testDebugUnitTest", "--console=plain"])

    def test_lint_runs_lint_and_detekt_in_one_call(self):
        self.run_kit("android", "lint")
        (call,) = self.calls()
        self.assertEqual(call["argv"], ["lintDebug", "detekt", "--console=plain", "--continue"])

    def test_configured_task_names_replace_the_defaults(self):
        self.edit_config("android", lintTasks=["lint{Variant}", "detekt", "ktlintCheck"], buildTask="bundle{Variant}")
        self.run_kit("android", "lint", variant="Release")
        self.run_kit("android", "build")
        self.assertEqual(self.calls()[0]["argv"][:3], ["lintRelease", "detekt", "ktlintCheck"])
        self.assertEqual(self.calls()[1]["argv"][0], "bundleDebug")


class AndroidParsing(KitCase):
    def test_kotlin_and_javac_errors_from_the_log(self):
        out = ("e: file:///p/app/A.kt:12:5 Unresolved reference: foo\nw: file:///p/app/A.kt:13:1 Unused\n"
               "/p/app/B.java:7: error: ';' expected\n")
        self.fake(gradlew={"exit": 1, "out": out})
        r = self.run_kit("android", "build")
        self.assertEqual(r["errors"], [{"file": "/p/app/A.kt", "line": 12, "col": 5, "message": "Unresolved reference: foo"},
                                       {"file": "/p/app/B.java", "line": 7, "col": None, "message": "';' expected"}])
        self.assertEqual(r["warnings"], 1)

    def test_lint_and_detekt_reports_give_file_line_errors(self):
        self.fake(gradlew={"exit": 1, "files": {"app/build/reports/lint-results-debug.xml": LINT_XML,
                                                "build/reports/detekt/detekt.xml": DETEKT_XML}})
        r = self.run_kit("android", "lint")
        self.assertEqual(r["error_count"], 3)
        self.assertEqual(r["errors"][0], {"file": "src/A.kt", "line": 4, "col": 9, "message": "Missing permission"})
        self.assertEqual(r["errors"][2]["file"], "src/D.kt")
        self.assertEqual(r["warnings"], 2)

    def test_junit_reports_give_test_counts_and_failures(self):
        self.fake(gradlew={"exit": 1, "files": {"app/build/test-results/testDebugUnitTest/TEST-a.B.xml": JUNIT_XML}})
        t = self.run_kit("android", "test")["tests"]
        self.assertEqual((t["passed"], t["failed"], t["skipped"]), (2, 2, 1))
        self.assertEqual(t["failures"], [{"test": "a.B.bad", "message": "expected 1"}, {"test": "a.B.boom", "message": "npe"}])

    def test_reports_from_an_earlier_run_are_ignored_and_the_gap_is_said(self):
        self.fake(gradlew={"stale_files": {"app/build/reports/lint-results-debug.xml": LINT_XML,
                                           "app/build/test-results/testDebugUnitTest/TEST-a.xml": JUNIT_XML}})
        lint = self.run_kit("android", "lint")
        self.assertEqual(lint["error_count"], 0)
        self.assertIn("no lint or detekt report", lint["notes"][0])
        test = self.run_kit("android", "test")
        self.assertEqual(test["tests"], {"passed": 0, "failed": 0, "skipped": 0, "failures": [], "source": "none"})
        self.assertIn("no test report", test["notes"][0])

    def test_modules_at_any_depth_are_found_but_links_and_hidden_folders_are_not(self):
        deep = "feature/login/impl/build/test-results/testDebugUnitTest/TEST-x.xml"
        self.fake(gradlew={"files": {deep: JUNIT_XML, ".hidden/build/test-results/t/TEST-h.xml": JUNIT_XML}})
        self.assertEqual(self.run_kit("android", "test")["tests"]["failed"], 2)

    def test_a_linked_module_folder_is_not_walked(self):
        elsewhere = self.tmp / "elsewhere" / "build" / "test-results" / "t"
        elsewhere.mkdir(parents=True)
        (elsewhere / "TEST-link.xml").write_text(JUNIT_XML)
        (self.root / "android" / "linked").symlink_to(self.tmp / "elsewhere")
        self.assertEqual(self.run_kit("android", "test")["tests"]["source"], "none")

    def test_a_report_that_is_a_symlink_or_a_fifo_is_skipped(self):
        target = self.tmp / "real.xml"
        target.write_text(JUNIT_XML)
        folder = self.root / "android" / "app" / "build" / "test-results" / "t"
        folder.mkdir(parents=True)
        (folder / "TEST-link.xml").symlink_to(target)
        os.mkfifo(str(folder / "TEST-fifo.xml"))
        r = self.run_kit("android", "test")
        self.assertEqual(r["tests"]["source"], "none")

    def test_cdata_that_looks_like_a_doctype_is_fine_but_utf16_entities_are_not(self):
        cdata = '<testsuite tests="1" failures="0"><testcase classname="a" name="b"/><system-out><![CDATA[<!DOCTYPE html>]]></system-out></testsuite>'
        utf16 = '<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY a "aaaa">]><testsuite tests="1"/>'
        self.fake(gradlew={"files": {"app/build/test-results/t/TEST-a.xml": cdata}})
        self.assertEqual(self.run_kit("android", "test")["tests"]["passed"], 1)
        folder = self.root / "android" / "app" / "build" / "test-results" / "t"
        (folder / "TEST-a.xml").write_bytes(utf16.encode("utf-16"))
        self.fake(gradlew={"files": {}})
        r = self.run_kit("android", "test")
        self.assertEqual(r["tests"]["source"], "none")
        self.assertIn("DOCTYPE", r["notes"][0])

    def test_hostile_or_broken_reports_are_skipped_with_a_note(self):
        bomb = '<!DOCTYPE x [<!ENTITY a "aaaa">]><issues><issue severity="Error" message="&a;"/></issues>'
        self.fake(gradlew={"files": {"app/build/reports/lint-results-debug.xml": bomb,
                                     "app/build/reports/detekt/detekt.xml": "<checkstyle"}})
        r = self.run_kit("android", "lint")
        self.assertEqual((r["status"], r["error_count"], len(r["notes"])), ("passed", 0, 3))

    def test_missing_wrapper_is_a_failed_result(self):
        os.unlink(self.root / "android" / "gradlew")
        r = self.run_kit("android", "build")
        self.assertEqual((r["status"], r["exit_code"]), ("failed", None))


if __name__ == "__main__":
    unittest.main()
