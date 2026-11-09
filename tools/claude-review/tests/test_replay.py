"""The offline replay runner (tools/claude-review/replay/replay.py): the parts that do not call claude."""
import importlib.util, json, pathlib, subprocess, tempfile, unittest

KIT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("replay", KIT / "replay" / "replay.py")
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


def run(*a, cwd):
    subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)


class PatchCommand(unittest.TestCase):
    OLD = "- Model: `opus` for a defect, interaction, security or failure-path candidate; `sonnet` for a written-rule or private-data candidate.\n"
    NEW = "- Model: `opus` for an interaction, security or failure-path candidate; `sonnet` for a defect, written-rule or private-data candidate.\n"

    def test_kit_command_has_the_verifier_line_and_only_it_changes(self):
        text = (KIT / "claude-pr-review.md").read_text()
        out = replay.patch_command(text, "sonnet")
        before, after = text.splitlines(), out.splitlines()
        changed = [(a, b) for a, b in zip(before, after) if a != b]
        self.assertEqual(len(changed), 1)
        self.assertTrue(changed[0][0].startswith("- Model: `opus` for ") and changed[0][1].startswith("- Model: `sonnet` for "))

    def test_both_wordings_of_the_line(self):
        for line in (self.OLD, self.NEW):
            out = replay.patch_command("a\n" + line + "b\n", "sonnet")
            self.assertEqual(out, "a\n" + line.replace("`opus`", "`sonnet`", 1) + "b\n")
            self.assertEqual(out.count("`opus`"), 0)

    def test_missing_line_fails_instead_of_running_the_wrong_arm(self):
        with self.assertRaises(SystemExit):
            replay.patch_command("nothing here", "sonnet")

    def test_model_name_is_checked(self):
        with self.assertRaises(SystemExit):
            replay.patch_command((KIT / "claude-pr-review.md").read_text(), "so`net")


class WorkflowSettings(unittest.TestCase):
    def test_reads_the_kit_workflow(self):
        s = replay.workflow_settings((KIT / "claude-review.yml").read_text())
        self.assertEqual(s["allowed"], "Agent,Task")
        self.assertIn("Bash", s["disallowed"].split(","))
        self.assertEqual(json.loads(s["schema"])["required"], ["no_issues", "stopped", "findings", "threads", "overview"])

    def test_missing_setting_fails(self):
        with self.assertRaises(SystemExit):
            replay.workflow_settings("TOOLS: 'x'")


class Context(unittest.TestCase):
    def test_files_and_diff_from_git(self):
        with tempfile.TemporaryDirectory() as d:
            run("init", "-q", cwd=d)
            run("config", "user.email", "t@example.com", cwd=d)
            run("config", "user.name", "t", cwd=d)
            p = pathlib.Path(d)
            (p / "a.txt").write_text("one\ntwo\nthree\n")
            (p / "old.txt").write_text("keep me\nkeep me too\nand me\nand me\n")
            (p / "gone.txt").write_text("x\n")
            run("add", ".", cwd=d)
            run("commit", "-qm", "base", cwd=d)
            base = replay.git("rev-parse", "HEAD", cwd=d).strip()
            (p / "a.txt").write_text("one\nTWO\nthree\n")
            (p / "new.txt").write_text("hello\n")
            (p / "gone.txt").unlink()
            run("mv", "old.txt", "renamed.txt", cwd=d)
            run("add", "-A", cwd=d)
            run("commit", "-qm", "head", cwd=d)
            head = replay.git("rev-parse", "HEAD", cwd=d).strip()
            files = {f["filename"]: f for f in replay.file_entries(d, base, head)}
            self.assertEqual(set(files), {"a.txt", "new.txt", "gone.txt", "renamed.txt"})
            self.assertEqual((files["a.txt"]["status"], files["a.txt"]["additions"], files["a.txt"]["deletions"]), ("modified", 1, 1))
            self.assertTrue(files["a.txt"]["patch"].startswith("@@"))
            self.assertEqual(files["new.txt"]["status"], "added")
            self.assertEqual(files["gone.txt"]["status"], "removed")
            self.assertEqual((files["renamed.txt"]["status"], files["renamed.txt"]["previous_filename"]), ("renamed", "old.txt"))
            self.assertIsNone(files["renamed.txt"]["patch"])


class ContextEdgeCases(unittest.TestCase):
    def test_non_utf8_file_and_glob_like_names(self):
        with tempfile.TemporaryDirectory() as d:
            run("init", "-q", cwd=d)
            run("config", "user.email", "t@example.com", cwd=d)
            run("config", "user.name", "t", cwd=d)
            p = pathlib.Path(d)
            (p / "keep.txt").write_text("x\n")
            run("add", ".", cwd=d)
            run("commit", "-qm", "base", cwd=d)
            base = replay.git("rev-parse", "HEAD", cwd=d).strip()
            (p / "latin.txt").write_bytes("caf\xe9\r\n".encode("latin-1"))
            (p / "[id].tsx").write_text("one\n")
            (p / "i.tsx").write_text("two\ntwo\n")
            run("add", "-A", cwd=d)
            run("commit", "-qm", "head", cwd=d)
            head = replay.git("rev-parse", "HEAD", cwd=d).strip()
            files = {f["filename"]: f for f in replay.file_entries(d, base, head)}
            self.assertEqual(set(files), {"latin.txt", "[id].tsx", "i.tsx"})
            self.assertEqual(files["[id].tsx"]["additions"], 1)   # not also i.tsx's 2 lines
            self.assertEqual(files["i.tsx"]["additions"], 2)
            self.assertIn("�", files["latin.txt"]["patch"])

    def test_file_replaced_by_a_directory_keeps_each_patch_to_its_own_file(self):
        with tempfile.TemporaryDirectory() as d:
            run("init", "-q", cwd=d)
            run("config", "user.email", "t@example.com", cwd=d)
            run("config", "user.name", "t", cwd=d)
            p = pathlib.Path(d)
            (p / "config").write_text("old\n")
            run("add", ".", cwd=d)
            run("commit", "-qm", "base", cwd=d)
            base = replay.git("rev-parse", "HEAD", cwd=d).strip()
            (p / "config").unlink()
            (p / "config").mkdir()
            (p / "config" / "default.yml").write_text("a: 1\nb: 2\n")
            run("add", "-A", cwd=d)
            run("commit", "-qm", "head", cwd=d)
            head = replay.git("rev-parse", "HEAD", cwd=d).strip()
            files = {f["filename"]: f for f in replay.file_entries(d, base, head)}
            self.assertEqual(set(files), {"config", "config/default.yml"})
            self.assertEqual((files["config"]["status"], files["config"]["additions"], files["config"]["deletions"]), ("removed", 0, 1))
            self.assertNotIn("a: 1", files["config"]["patch"])
            self.assertEqual((files["config/default.yml"]["status"], files["config/default.yml"]["additions"]), ("added", 2))
            self.assertNotIn("old", files["config/default.yml"]["patch"])

    def test_clone_dir_that_is_not_a_clone_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            work = pathlib.Path(d) / "w"
            (work / "clone").mkdir(parents=True)
            args = type("A", (), {"repo": "o/r", "pr": 1, "base": "auto", "head": "0" * 40})()
            with self.assertRaises(SystemExit):
                replay.prepare_clone(args, work)


class Command(unittest.TestCase):
    def test_tool_limits_and_model_reach_the_claude_command(self):
        s = replay.workflow_settings((KIT / "claude-review.yml").read_text())
        cmd = replay.claude_command(s, pathlib.Path("/ctx"), "/claude-pr-review x", "sonnet")
        self.assertEqual(cmd[cmd.index("--model") + 1], "sonnet")
        self.assertEqual(cmd[cmd.index("--allowedTools") + 1], "Agent,Task")
        self.assertEqual(cmd[cmd.index("--add-dir") + 1], "/ctx")
        self.assertNotIn("Bash", cmd[cmd.index("--allowedTools") + 1])


class Summarize(unittest.TestCase):
    def test_counts_agents_by_model_and_reads_the_result(self):
        lines = [
            json.dumps({"type": "assistant", "message": {"content": [
                {"type": "tool_use", "name": "Agent", "input": {"model": "opus"}},
                {"type": "tool_use", "name": "Task", "input": {"model": "sonnet"}},
                {"type": "tool_use", "name": "Read", "input": {}},
                {"type": "text", "text": "x"}]}}),
            "not json",
            json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Agent", "input": {}}]}}),
            json.dumps({"type": "result", "is_error": False, "total_cost_usd": 1.5, "duration_ms": 9, "num_turns": 3,
                        "modelUsage": {"claude-opus-5-5": {"costUSD": 1.0}}, "permission_denials": [],
                        "structured_output": {"findings": []}}),
        ]
        s = replay.summarize(lines)
        self.assertEqual(s["agent_calls"], 3)
        self.assertEqual(s["agent_models"], {"opus": 1, "sonnet": 1, "default": 1})
        self.assertEqual(s["model_cost_usd"], {"claude-opus-5-5": 1.0})
        self.assertEqual(s["total_cost_usd"], 1.5)

    def test_no_result_message(self):
        self.assertIsNone(replay.summarize(["{}"]))

    def test_structured_output_as_json_string_or_missing(self):
        def result(out):
            return [json.dumps({"type": "result", "is_error": False, "structured_output": out})]
        self.assertEqual(replay.summarize(result('{"findings": []}'))["structured_output"], {"findings": []})
        self.assertIsNone(replay.summarize(result("not json"))["structured_output"])
        self.assertIsNone(replay.summarize(result(None))["structured_output"])


if __name__ == "__main__":
    unittest.main()
