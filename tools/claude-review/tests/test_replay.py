"""The offline replay runner (tools/claude-review/replay/replay.py): the parts that do not call claude."""
import importlib.util, json, pathlib, subprocess, tempfile, unittest

KIT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("replay", KIT / "replay" / "replay.py")
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)


def run(*a, cwd):
    subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True)


class PatchCommand(unittest.TestCase):
    def test_kit_command_has_the_verifier_line_and_only_it_changes(self):
        text = (KIT / "claude-pr-review.md").read_text()
        out = replay.patch_command(text, "sonnet")
        self.assertIn("- Model: `sonnet` for a defect, interaction, security or failure-path candidate;", out)
        before, after = text.splitlines(), out.splitlines()
        self.assertEqual([i for i, (a, b) in enumerate(zip(before, after)) if a != b].__len__(), 1)

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


if __name__ == "__main__":
    unittest.main()
