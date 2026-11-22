"""The `review` job's "Collect Claude's review threads" script: which threads it follows up, and when it skips Claude
because this head is already covered. Only the App's threads, replies and overview count."""
import contextlib, io, json, os, pathlib, runpy, tempfile, unittest
from unittest import mock

from github_fake import API, APP, GH_TOKEN, GRAPHQL, FakeGitHub, bot, user
from workflow import COLLECT, load_publish

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
            runpy.run_path(str(COLLECT), run_name="__main__")
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

    def test_legacy_authors_and_a_summary_without_a_result_cover_nothing(self):
        self.gh.add_issue_comment(f"## Code review\n\n<!-- claude-review:summary sha={HEAD} -->", login="github-actions[bot]")
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} -->\nx", login=APP + "[bot]")
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=clean -->\nx", login="github-actions[bot]")
        self.assertNotIn("covered", self.collect()[0])

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

    def test_threads_from_the_app_are_followed(self):
        app = self.gh.add_thread(bot(APP), "App finding")
        self.gh.add_thread(bot("claude"), "Legacy finding")
        self.gh.add_thread(user("someone"), "A person's thread")
        resolved = self.gh.add_thread(bot(APP), "Fixed", resolved=True)
        outputs, threads = self.collect()
        self.assertEqual({t["thread_id"] for t in threads["open"]}, {app})
        self.assertEqual(threads["raised"], [])   # resolved: no longer covers its issue, so a regression is a new finding
        self.assertNotIn("covered", outputs)
        self.assertNotIn(resolved, {t["thread_id"] for t in threads["open"]})

    def test_open_reply_for_this_head_covers_and_resolved_reply_is_retried(self):
        replied = self.gh.add_thread(bot(APP), "x")
        self.gh.thread_comment(replied, bot(APP), marker("open"))
        unresolved = self.gh.add_thread(bot(APP), "y")
        self.gh.thread_comment(unresolved, bot(APP), marker("resolved"))
        outputs, _ = self.collect(mode="followup")
        self.assertEqual(outputs.get("covered"), "true")
        self.assertEqual(json.loads(outputs["retry_ids"]), [unresolved])

    def test_a_reply_by_the_legacy_author_is_not_this_workflows(self):
        t = self.gh.add_thread(bot(APP), "x")
        self.gh.thread_comment(t, bot("github-actions"), marker("open"))
        self.assertNotIn("covered", self.collect(mode="followup")[0])

    def test_reply_for_another_head_is_pending(self):
        t = self.gh.add_thread(bot(APP), "x")
        self.gh.thread_comment(t, bot(APP), marker("open", sha=OLD))
        self.assertNotIn("covered", self.collect(mode="followup")[0])

    def test_moved_head_follows_no_thread(self):
        self.gh.add_thread(bot(APP), "x")
        self.gh.head = OLD
        outputs, threads = self.collect()
        self.assertEqual((threads["open"], len(threads["raised"])), ([], 1))   # context only: not followed up
        self.assertEqual(set(threads["raised"][0]), {"thread_id", "path", "line", "issue"})
        self.assertNotIn("covered", outputs)

    def test_pending_thread_runs_claude_and_queues_no_retry(self):
        self.gh.add_thread(bot(APP), "pending")
        done = self.gh.add_thread(bot(APP), "y")
        self.gh.thread_comment(done, bot(APP), marker("resolved"))
        outputs, threads = self.collect(mode="followup")
        self.assertNotIn("covered", outputs)
        self.assertNotIn("retry_ids", outputs)
        self.assertEqual(len(threads["open"]), 2)

    def test_the_too_long_count_leaves_out_resolved_threads(self):
        for resolved in (True, False):
            tid = self.gh.add_thread(bot(APP), "Long", resolved=resolved)
            self.gh.threads[tid]["more_comments"] = True
        _, threads = self.collect()
        self.assertEqual(len(threads["raised"]), 1)
        self.assertIn("(1 too long to follow)", self.log)

    def test_the_suggestion_marker_is_the_one_publish_writes(self):
        self.assertIn(f'SUGGESTION_MARKER = "{load_publish()["SUGGESTION_MARKER"]}"', COLLECT.read_text())

    def test_a_suggestion_thread_is_context_only(self):
        suggestion = self.gh.add_thread(bot(APP), "<!-- claude-review:suggestion -->\n**Suggestion (non-blocking):**\n\nFold it.")
        blocking = self.gh.add_thread(bot(APP), "A bug.")
        outputs, threads = self.collect()
        self.assertEqual([t["thread_id"] for t in threads["open"]], [blocking])
        self.assertEqual([t["thread_id"] for t in threads["raised"]], [suggestion])   # a rereview must not suggest it again
        self.assertNotIn("covered", outputs)
        self.gh.threads[suggestion]["isResolved"] = True   # a person's "won't do": still context, so no second suggestion
        _, threads = self.collect()
        self.assertEqual([t["thread_id"] for t in threads["raised"]], [suggestion])
        self.gh.threads[blocking]["isResolved"] = True
        self.gh.threads[suggestion]["isResolved"] = False   # only an unanswered suggestion left: nothing to judge
        outputs, threads = self.collect(mode="followup")
        self.assertEqual((outputs.get("covered"), threads["open"]), ("true", []))
        self.assertNotIn("suggestion_ids", outputs)   # no reply, so nothing to resolve
        self.assertIn("No finding thread to follow up; 1 suggestion thread(s) are never judged", self.log)
        self.gh.threads[suggestion]["isResolved"] = True   # a resolved suggestion only: the ordinary "covered"
        self.assertEqual(self.collect(mode="followup")[0].get("covered"), "true")
        self.assertIn("This head was already covered", self.log)

    def test_an_answered_suggestion_is_queued_for_publish_in_a_followup(self):
        suggestion = self.gh.add_thread(bot(APP), "<!-- claude-review:suggestion -->\nFold it.")
        self.gh.thread_comment(suggestion, user("author"), "Done in abc.")
        outputs, threads = self.collect(mode="followup")
        self.assertEqual((outputs.get("covered"), json.loads(outputs["suggestion_ids"])), ("true", [suggestion]))
        self.assertEqual([t["thread_id"] for t in threads["raised"]], [suggestion])   # still context, never judged
        self.assertIn("Queued 1 answered suggestion thread(s) for publish to resolve", self.log)
        self.assertNotIn("suggestion_ids", self.collect()[0])   # a rereview leaves it alone
        self.gh.head = OLD   # the PR moved after the checkout: publish would not write, so nothing is queued
        self.assertNotIn("suggestion_ids", self.collect(mode="followup")[0])

    def test_an_answered_suggestion_beside_a_finding_is_queued_and_the_finding_still_judged(self):
        suggestion = self.gh.add_thread(bot(APP), "<!-- claude-review:suggestion -->\nFold it.")
        self.gh.thread_comment(suggestion, user("author"), "Declined: it is clearer as is.")
        finding = self.gh.add_thread(bot(APP), "A bug.")
        outputs, threads = self.collect(mode="followup")
        self.assertEqual([t["thread_id"] for t in threads["open"]], [finding])
        self.assertNotIn("covered", outputs)
        self.assertEqual(json.loads(outputs["suggestion_ids"]), [suggestion])

    def test_followup_with_nothing_open_is_covered(self):
        self.assertEqual(self.collect(mode="followup")[0].get("covered"), "true")
        self.assertIn("This head was already covered", self.log)


if __name__ == "__main__":
    unittest.main()
