"""The `review` job's "Collect Claude's review threads" script: which threads it follows up, and when it skips Claude
because this head is already covered. The App and the legacy authors (claude[bot], github-actions) both count."""
import contextlib, io, json, os, pathlib, tempfile, unittest
from unittest import mock

from github_fake import API, APP, GH_TOKEN, GRAPHQL, FakeGitHub, bot, user
from workflow import script

HEAD = "a" * 40
OLD = "b" * 40


def marker(verdict, sha=HEAD, mode="followup"):
    return f"> x\n\n— Claude review follow-up\n<!-- claude-review:followup verdict={verdict} sha={sha} mode={mode} -->"


class Collect(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub(head=HEAD)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name)

    def collect(self, mode="rereview"):
        out = self.dir / "output"
        out.write_text("")
        env = {"GITHUB_REPOSITORY": "o/r", "PR_NUMBER": "7", "GITHUB_API_URL": API, "GITHUB_GRAPHQL_URL": GRAPHQL,
               "GH_TOKEN": GH_TOKEN, "APP_LOGIN": APP, "HEAD_SHA": HEAD, "REVIEW_MODE": mode,
               "THREADS_FILE": str(self.dir / "threads.json"), "GITHUB_OUTPUT": str(out)}
        log = io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch("urllib.request.urlopen", self.gh.urlopen), \
                contextlib.redirect_stdout(log):
            exec(compile(script("Collect Claude's review threads"), "collect.py", "exec"), {"__name__": "__main__"})
        self.log = log.getvalue()
        outputs = dict(line.split("=", 1) for line in out.read_text().splitlines())
        return outputs, json.loads((self.dir / "threads.json").read_text())

    def test_followup_overview_at_head_does_not_cover_a_rereview(self):
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=followup -->\nx")
        outputs, _ = self.collect()
        self.assertNotIn("covered", outputs)

    def test_clean_overview_at_head_covers(self):
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=clean -->\nx")
        self.assertEqual(self.collect()[0].get("covered"), "true")

    def test_legacy_summary_counts_as_clean(self):
        self.gh.add_issue_comment(f"## Code review\n\n<!-- claude-review:summary sha={HEAD} -->", login="github-actions[bot]")
        self.assertEqual(self.collect()[0].get("covered"), "true")

    def test_clean_overview_at_another_head_or_by_someone_else(self):
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={OLD} result=clean -->\nx")
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=clean -->\nx", login="someone")
        self.assertNotIn("covered", self.collect()[0])

    def test_overview_on_a_later_page(self):
        self.gh.page_size = 2
        for i in range(5):
            self.gh.add_issue_comment(f"comment {i}", login="someone")
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=clean -->\nx")
        self.assertEqual(self.collect()[0].get("covered"), "true")

    def test_threads_from_the_app_and_claude_are_followed(self):
        app = self.gh.add_thread(bot(APP), "App finding")
        legacy = self.gh.add_thread(bot("claude"), "Legacy finding")
        self.gh.add_thread(user("someone"), "A person's thread")
        resolved = self.gh.add_thread(bot(APP), "Fixed", resolved=True)
        outputs, threads = self.collect()
        self.assertEqual({t["thread_id"] for t in threads["open"]}, {app, legacy})
        self.assertEqual(len(threads["raised"]), 1)
        self.assertNotIn("covered", outputs)
        self.assertNotIn(resolved, {t["thread_id"] for t in threads["open"]})
        # v2.5: resolved by a person (no `resolved` reply from this workflow), so it isn't reopenable.
        self.assertEqual((threads["raised"][0]["thread_id"], threads["raised"][0]["reopenable"]), (resolved, False))
        self.assertNotIn("comments", threads["raised"][0])

    def test_only_a_thread_this_workflow_resolved_at_an_earlier_head_is_reopenable(self):   # v2.5, review B2
        fixed = self.gh.add_thread(bot(APP), "SQLi", resolved=True)
        self.gh.thread_comment(fixed, user("dev"), "Fixed in abc.")
        self.gh.thread_comment(fixed, bot(APP), marker("resolved", sha=OLD))
        legacy = self.gh.add_thread(bot("claude"), "Old", resolved=True)
        self.gh.thread_comment(legacy, bot("github-actions"), marker("resolved", sha=OLD))
        at_head = self.gh.add_thread(bot(APP), "Now", resolved=True)
        self.gh.thread_comment(at_head, bot(APP), marker("resolved"))
        after = self.gh.add_thread(bot(APP), "Then", resolved=True)
        self.gh.thread_comment(after, bot(APP), marker("resolved", sha=OLD))
        self.gh.thread_comment(after, user("dev"), "Won't fix.")
        forged = self.gh.add_thread(bot(APP), "Forged", resolved=True)
        self.gh.thread_comment(forged, user("dev"), marker("resolved", sha=OLD))
        raised = {t["thread_id"]: t for t in self.collect()[1]["raised"]}
        self.assertEqual({t for t, r in raised.items() if r["reopenable"]}, {fixed, legacy})
        self.assertEqual([c["body"] for c in raised[fixed]["comments"]][1], "Fixed in abc.")   # Claude sees the replies

    def test_open_reply_for_this_head_covers_and_resolved_reply_is_retried(self):
        replied = self.gh.add_thread(bot(APP), "x")
        self.gh.thread_comment(replied, bot(APP), marker("open"))
        legacy = self.gh.add_thread(bot("claude"), "y")
        self.gh.thread_comment(legacy, bot("github-actions"), marker("resolved"))
        outputs, _ = self.collect(mode="followup")
        self.assertEqual(outputs.get("covered"), "true")
        self.assertEqual(json.loads(outputs["retry_ids"]), [legacy])

    def test_reply_for_another_head_is_pending(self):
        t = self.gh.add_thread(bot(APP), "x")
        self.gh.thread_comment(t, bot(APP), marker("open", sha=OLD))
        self.assertNotIn("covered", self.collect(mode="followup")[0])

    def test_moved_head_follows_no_thread(self):
        self.gh.add_thread(bot(APP), "x")
        self.gh.head = OLD
        outputs, threads = self.collect()
        self.assertEqual((threads["open"], len(threads["raised"])), ([], 1))
        self.assertIs(threads["raised"][0]["reopenable"], False)   # moved, not resolved: never reopened
        self.assertNotIn("covered", outputs)

    def test_pending_thread_runs_claude_and_queues_no_retry(self):
        self.gh.add_thread(bot(APP), "pending")
        done = self.gh.add_thread(bot(APP), "y")
        self.gh.thread_comment(done, bot(APP), marker("resolved"))
        outputs, threads = self.collect(mode="followup")
        self.assertNotIn("covered", outputs)
        self.assertNotIn("retry_ids", outputs)
        self.assertEqual(len(threads["open"]), 2)

    def test_followup_with_nothing_open_is_covered(self):
        self.assertEqual(self.collect(mode="followup")[0].get("covered"), "true")


if __name__ == "__main__":
    unittest.main()
