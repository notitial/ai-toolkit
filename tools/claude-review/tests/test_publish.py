"""The `publish` script against a fake GitHub: the verdict table, idempotency, retries, dismissal, the overview
comment, thread replies and resolve."""
import contextlib, io, json, os, pathlib, re, tempfile, unittest
from unittest import mock

from github_fake import API, APP, APP_TOKEN, GH_TOKEN, GRAPHQL, FakeGitHub, bot, user
from workflow import load_publish, save_threads

HEAD = "a" * 40
OLD = "b" * 40
# LEFT lines 1-3 (2 removed), RIGHT lines 1-4 (2 and 3 added), all in hunk 0.
PATCH = "@@ -1,3 +1,4 @@\n line1\n-old2\n+new2\n+new3\n line3"


def result(**kw):
    return {"no_issues": True, "stopped": False, "findings": [], "threads": [], "overview": "", **kw}


def finding(path="src/a.py", line=2, side="RIGHT", body="Off by one.", **kw):
    return {"path": path, "line": line, "side": side, "body": body, "line_text": "", **kw}


def followup_marker(verdict, sha=HEAD, mode="followup"):
    return f"> ok\n\n— Claude review follow-up\n<!-- claude-review:followup verdict={verdict} sha={sha} mode={mode} -->"


class PublishCase(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub(head=HEAD)
        self.gh.add_file("src/a.py", PATCH)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name)
        self.env = {
            "GITHUB_REPOSITORY": "o/r", "PR_NUMBER": "7", "GITHUB_API_URL": API, "GITHUB_GRAPHQL_URL": GRAPHQL,
            "APP_TOKEN": APP_TOKEN, "GH_TOKEN": GH_TOKEN, "APP_LOGIN": APP,
            "GITHUB_EVENT_NAME": "pull_request", "EVENT_ACTION": "opened",
            "REVIEW_RESULT": "success", "MODE": "initial", "HEAD_SHA": HEAD, "RAN": "true", "RETRY_IDS": "",
            "HAS_RESULT": "true", "RESULT_FILE": str(self.dir / "result.json"),
            "THREADS_FILE": str(self.dir / "threads.json"),
            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
            "CHANGES_EVENT": "REQUEST_CHANGES", "APPROVE_EVENT": "APPROVE",
            "GITHUB_STEP_SUMMARY": str(self.dir / "summary.md"),
        }

    def run_publish(self, res=None, threads=None, **env):
        if res is not None:
            (self.dir / "result.json").write_text(json.dumps(res))
        if threads is not None:
            (self.dir / "threads.json").write_text(json.dumps(threads))
        ns = load_publish()
        out = io.StringIO()
        with mock.patch("urllib.request.urlopen", self.gh.urlopen), contextlib.redirect_stdout(out):
            rc = ns["main"](dict(self.env, **env))
        self.log = out.getvalue()
        return rc

    def new_reviews(self, before=0):
        return self.gh.app_reviews()[before:]

    def overview(self):
        found = self.gh.overviews()
        self.assertEqual(len(found), 1, self.log)
        return found[0]["body"]

    def open_app_thread(self):
        return self.gh.add_thread(bot(APP), "Still broken.", "src/a.py", 2)


class Verdicts(PublishCase):
    def test_clean_review_approves_and_writes_a_clean_overview(self):
        self.assertEqual(self.run_publish(result()), 0, self.log)
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "APPROVE")
        self.assertEqual(review["commit_id"], HEAD)
        self.assertIn("<!-- claude-review:review run=123 attempt=1 sha=" + HEAD + " -->", review["body"])
        self.assertIn("No issues found at `aaaaaaa`.", review["body"])
        body = self.overview()
        self.assertTrue(body.startswith(f"<!-- claude-review:summary sha={HEAD} result=clean -->"))
        self.assertIn("**Result:** No issues found.", body)
        self.assertIn(self.gh.overviews()[0]["html_url"], review["body"])

    def test_findings_inline_in_body_and_dropped(self):
        res = result(no_issues=False, findings=[
            finding(),                                         # inline
            finding(line=40, body="Not in the diff."),         # body
            finding(path="elsewhere.py", body="Not a PR file."),  # dropped
        ])
        self.assertEqual(self.run_publish(res), 0, self.log)
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        [comment] = self.gh.review_comments
        self.assertEqual((comment["path"], comment["line"], comment["side"]), ("src/a.py", 2, "RIGHT"))
        self.assertIn("**Not on a changed line:**", review["body"])
        self.assertIn("**`src/a.py` line 40**", review["body"])
        self.assertNotIn("elsewhere.py", review["body"])
        body = self.overview()
        self.assertIn("result=issues", body)
        self.assertIn(f"**Result:** 2 findings in the [review]({review['html_url']}).", body)
        self.assertIn("**Threads:** 0 resolved · 1 still open: [`src/a.py:2`](" + comment["html_url"], body)
        self.assertIn("1 dropped", self.log)

    def test_no_issues_with_findings_never_approves(self):
        self.run_publish(result(no_issues=True, findings=[finding()]))
        self.assertEqual([r["event"] for r in self.new_reviews()], ["REQUEST_CHANGES"])

    def test_duplicate_findings_post_once(self):
        self.run_publish(result(no_issues=False, findings=[finding(), finding()]))
        self.assertEqual(len(self.gh.review_comments), 1)

    def test_open_thread_blocks_approval(self):
        self.open_app_thread()
        self.run_publish(result())
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        self.assertIn("1 review thread(s) still open", review["body"])
        self.assertIn("No new findings; 1 thread(s) still open.", self.overview())

    def test_stopped_writes_overview_and_no_review(self):
        self.run_publish(result(no_issues=False, stopped=True))
        self.assertEqual(self.new_reviews(), [])
        self.assertIn("result=stopped", self.overview())
        self.assertIn("Review stopped: the PR was closed or a draft when the review ran", self.overview())


class TransitionTable(PublishCase):
    """notes.md §5.3: effective state E (the App's latest decisive review) × desired verdict D."""

    def scenario(self, decision):
        if decision == "approve":
            return {}, result()
        if decision == "changes+findings":
            return {}, result(no_issues=False, findings=[finding()])
        if decision == "changes":
            self.open_app_thread()
            return {}, result()
        if decision == "clear":
            return {"MODE": "followup"}, result(no_issues=False)
        return {}, result(no_issues=False, stopped=True)   # none

    def state(self, e):
        if e == "approved-head":
            return self.gh.add_review("APPROVED", commit_id=HEAD)
        if e == "approved-old":
            return self.gh.add_review("APPROVED", commit_id=OLD)
        if e == "changes":
            return self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        return None

    TABLE = {
        ("none", "approve"): ["APPROVE"], ("none", "changes+findings"): ["REQUEST_CHANGES"],
        ("none", "changes"): ["REQUEST_CHANGES"], ("none", "clear"): [], ("none", "none"): [],
        ("approved-head", "approve"): [], ("approved-head", "changes+findings"): ["REQUEST_CHANGES"],
        ("approved-head", "changes"): ["REQUEST_CHANGES"], ("approved-head", "clear"): [],
        ("approved-head", "none"): [],
        ("approved-old", "approve"): ["APPROVE"], ("approved-old", "changes+findings"): ["REQUEST_CHANGES"],
        ("approved-old", "changes"): ["REQUEST_CHANGES"], ("approved-old", "clear"): [], ("approved-old", "none"): [],
        ("changes", "approve"): ["APPROVE"], ("changes", "changes+findings"): ["REQUEST_CHANGES"],
        ("changes", "changes"): [], ("changes", "clear"): ["COMMENT"], ("changes", "none"): [],
    }

    def test_table(self):
        for (e, d), expected in self.TABLE.items():
            with self.subTest(E=e, D=d):
                self.setUp()
                env, res = self.scenario(d)
                before = self.state(e)
                n = len(self.gh.app_reviews())
                self.assertEqual(self.run_publish(res, **env), 0, self.log)
                self.assertEqual([r["event"] for r in self.new_reviews(n)], expected, self.log)
                dismissed = before is not None and before["state"] == "DISMISSED"
                self.assertEqual(dismissed, (e, d) == ("changes", "clear"))
                if expected == ["REQUEST_CHANGES"] and d == "changes+findings":
                    self.assertEqual(len(self.gh.review_comments), 1)

    def test_clear_comment_text(self):
        self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.run_publish(result(no_issues=False), MODE="followup")
        self.assertIn("Findings addressed; new code was not re-reviewed.", self.gh.app_reviews()[-1]["body"])

    def test_changes_event_comment_dismisses_the_approval(self):
        approved = self.gh.add_review("APPROVED", commit_id=HEAD)
        self.run_publish(result(no_issues=False, findings=[finding()]), CHANGES_EVENT="COMMENT")
        self.assertEqual(approved["state"], "DISMISSED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "COMMENT")

    def test_approve_event_comment_dismisses_the_change_request(self):
        changes = self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.run_publish(result(), APPROVE_EVENT="COMMENT")
        self.assertEqual(changes["state"], "DISMISSED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "COMMENT")

    def test_dismissed_latest_review_means_no_state(self):
        self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.gh.add_review("DISMISSED", commit_id=OLD)
        self.run_publish(result(no_issues=False), MODE="followup")
        self.assertEqual(len(self.gh.app_reviews()), 2)   # clear with no state: nothing

    def test_other_reviewers_are_ignored(self):
        self.gh.add_review("CHANGES_REQUESTED", login="someone")
        self.run_publish(result(no_issues=False), MODE="followup")
        self.assertEqual(self.gh.app_reviews(), [])


class PushPath(PublishCase):
    PUSH = {"EVENT_ACTION": "synchronize", "REVIEW_RESULT": "skipped", "MODE": "", "HEAD_SHA": "", "HAS_RESULT": ""}

    def test_push_dismisses_an_approval_of_an_older_commit(self):
        approved = self.gh.add_review("APPROVED", commit_id=OLD)
        self.assertEqual(self.run_publish(**self.PUSH), 0, self.log)
        self.assertEqual(approved["state"], "DISMISSED")
        self.assertEqual(approved["dismiss_message"], "New commits since this approval.")

    def test_push_keeps_an_approval_of_the_head_and_a_change_request(self):
        approved = self.gh.add_review("APPROVED", commit_id=HEAD)
        self.run_publish(**self.PUSH)
        self.assertEqual(approved["state"], "APPROVED")
        self.setUp()
        changes = self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.run_publish(**self.PUSH)
        self.assertEqual(changes["state"], "CHANGES_REQUESTED")

    def test_failed_dismissal_fails_the_job(self):
        approved = self.gh.add_review("APPROVED", commit_id=OLD)
        self.gh.fail("dismiss", 403, "Forbidden")
        self.assertEqual(self.run_publish(**self.PUSH), 1)
        self.assertIn("::warning::Dismissing the App's review failed", self.log)
        self.assertEqual(approved["state"], "APPROVED")
        self.assertEqual(self.gh.issue_comments, [])

    def test_already_dismissed_is_a_no_op(self):
        self.gh.add_review("APPROVED", commit_id=OLD)
        self.gh.fail("dismiss", 422, "Already dismissed")
        self.run_publish(**self.PUSH)
        self.assertNotIn("::warning::", self.log)

    def test_push_with_a_review_dismisses_then_publishes(self):
        approved = self.gh.add_review("APPROVED", commit_id=OLD)
        self.run_publish(result(), EVENT_ACTION="synchronize")
        self.assertEqual(approved["state"], "DISMISSED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "APPROVE")


class Idempotency(PublishCase):
    """The run marker on the review is the only key: a run that finds its review has done everything and stops."""

    def test_rerun_finds_its_review_and_stops(self):
        self.run_publish(result(no_issues=False, findings=[finding()]))
        self.assertEqual(len(self.gh.app_reviews()), 1)
        before = self.overview()
        calls = len(self.gh.calls)
        self.assertEqual(self.run_publish(result(), GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertIn("already submitted", self.log)
        self.assertEqual(len(self.gh.app_reviews()), 1)
        self.assertEqual(self.overview(), before)
        writes = {"submit review", "dismiss", "reply", "resolve", "post issue comment", "edit issue comment"}
        self.assertEqual([c for c in self.gh.calls[calls:] if c[1] in writes], [])

    def test_rerun_after_an_attempt_that_ended_without_a_verdict_posts_the_review(self):
        self.run_publish(result(no_issues=False, overview="One pass failed."))
        self.assertEqual(self.new_reviews(), [])
        self.assertIn("Review incomplete", self.overview())
        self.run_publish(result(), GITHUB_RUN_ATTEMPT="2")
        self.assertEqual([r["event"] for r in self.new_reviews()], ["APPROVE"])
        self.assertIn("result=clean", self.overview())

    def test_run_marker_is_an_exact_token(self):
        self.gh.add_review("COMMENTED", body=f"<!-- claude-review:review run=1234 attempt=1 sha={HEAD} -->\nx")
        self.run_publish(result())
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "APPROVE")

    def test_a_review_that_landed_despite_a_5xx_is_not_posted_again(self):
        self.gh.fail("submit review", 502, "", landed=True)
        self.assertEqual(self.run_publish(result()), 1)
        self.assertEqual(len(self.gh.app_reviews()), 1)
        self.assertEqual(self.run_publish(result(), GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertEqual(len(self.gh.app_reviews()), 1)


class RetryPolicy(PublishCase):
    def test_inline_422_retries_with_every_finding_in_the_body(self):
        self.gh.fail("submit review", 422, "Validation Failed")
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[finding()])), 0, self.log)
        [review] = self.gh.app_reviews()
        self.assertEqual(self.gh.review_comments, [])
        self.assertIn("**`src/a.py` line 2**", review["body"])

    def test_a_failed_submit_fails_the_job_and_the_rerun_posts_the_review(self):
        self.gh.fail("submit review", 502)
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[finding()])), 1)
        self.assertEqual(self.gh.app_reviews(), [])
        self.assertIn("::warning::Submitting the review failed", self.log)
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[finding()]), GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertEqual([r["event"] for r in self.gh.app_reviews()], ["REQUEST_CHANGES"])

    def test_a_422_with_nothing_inline_is_not_retried(self):
        self.gh.fail("submit review", 422, "Can not approve your own pull request")
        self.assertEqual(self.run_publish(result()), 1)
        self.assertEqual(len([c for c in self.gh.calls if c[1] == "submit review"]), 1)
        self.assertEqual(self.gh.app_reviews(), [])


class Overview(PublishCase):
    def test_overview_is_edited_in_place_across_runs(self):
        self.run_publish(result(no_issues=False, findings=[finding()]))
        first = self.gh.overviews()[0]["id"]
        for thread in self.gh.threads.values():
            thread["isResolved"] = True
        self.run_publish(result(), GITHUB_RUN_ID="124", MODE="rereview", GITHUB_EVENT_NAME="issue_comment")
        self.assertEqual([c["id"] for c in self.gh.overviews()], [first])
        body = self.overview()
        self.assertIn("result=clean", body)
        self.assertIn("**Threads:** 1 resolved · 0 still open", body)
        self.assertNotIn("History", body)
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "APPROVE")

    def test_overview_on_a_later_page_is_found(self):
        self.gh.page_size = 2
        for i in range(5):
            self.gh.add_issue_comment(f"comment {i}", login="someone")
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={OLD} result=issues -->\nold")
        self.run_publish(result())
        self.assertEqual(len(self.gh.overviews()), 1)
        self.assertIn("result=clean", self.overview())

    def test_two_overviews_edit_the_newest(self):
        a = self.gh.add_issue_comment(f"<!-- claude-review:summary sha={OLD} result=issues -->\na")
        b = self.gh.add_issue_comment(f"<!-- claude-review:summary sha={OLD} result=issues -->\nb")
        self.run_publish(result())
        self.assertEqual(a["body"].splitlines()[-1], "a")
        self.assertIn("result=clean", b["body"])
        self.assertIn("::warning::2 overview comments", self.log)

    def test_legacy_summary_is_left_and_a_new_overview_posted(self):
        legacy = self.gh.add_issue_comment(f"## Code review\n\nNo issues found.\n\n<!-- claude-review:summary sha={OLD} -->",
                                           login="github-actions[bot]")
        self.run_publish(result())
        self.assertTrue(legacy["body"].startswith("## Code review"))
        self.assertEqual(len([c for c in self.gh.overviews() if c["user"]["login"] == APP + "[bot]"]), 1)

    def test_open_thread_links_and_counts(self):
        self.gh.page_size = 2
        for i in range(12):
            self.gh.add_thread(bot(APP), f"issue {i}", "src/a.py", i + 1)
        self.gh.add_thread(bot(APP), "fixed", resolved=True)
        self.gh.add_thread(user("someone"), "a person's thread")
        self.run_publish(result())
        body = self.overview()
        self.assertIn("**Threads:** 1 resolved · 12 still open: [`src/a.py:1`](", body)
        self.assertIn(", and 2 more", body)
        self.assertEqual(body.count("#discussion_r"), 10)

    def test_followup_carries_the_overview_slot(self):
        self.gh.add_issue_comment(f"<!-- claude-review:summary sha={HEAD} result=issues -->\n### x\n\n**Result:** r\n\n"
                                  "<!-- claude-review:overview -->\nWhat the PR does.\n<!-- /claude-review:overview -->")
        self.run_publish(result(no_issues=False), MODE="followup")
        self.assertIn("<!-- claude-review:overview -->\nWhat the PR does.\n<!-- /claude-review:overview -->", self.overview())
        self.assertIn("result=followup", self.overview())

    def test_overview_write_failure_fails_the_job_but_never_holds_back_the_review(self):
        self.gh.fail("post issue comment", 500)
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[finding()])), 1)
        [review] = self.gh.app_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        self.assertNotIn("review overview", review["body"])
        self.assertIn("::warning::Writing the overview comment failed", self.log)

    def test_overview_write_failure_never_approves(self):
        self.gh.fail("post issue comment", 500)
        self.assertEqual(self.run_publish(result()), 1)
        self.assertEqual(self.gh.app_reviews(), [])
        self.assertEqual(self.run_publish(result(), GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertEqual([r["event"] for r in self.gh.app_reviews()], ["APPROVE"])
        self.assertIn("result=clean", self.overview().splitlines()[0])

    def test_a_failed_reply_never_approves_but_still_asks_for_changes(self):
        tid = self.open_app_thread()
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        threads = {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]}
        self.gh.fail("reply", 500)
        res = result(threads=[{"thread_id": tid, "verdict": "resolved", "reply": "x"}])
        self.assertEqual(self.run_publish(res, threads, MODE="rereview"), 1)
        self.assertEqual([r["event"] for r in self.gh.app_reviews()], ["REQUEST_CHANGES"])   # the thread is still open
        self.assertIn("result=issues", self.overview().splitlines()[0])

    def test_a_failed_reply_with_findings_still_posts_them_over_an_approval(self):
        approved = self.gh.add_review("APPROVED", commit_id=HEAD)
        tid = self.open_app_thread()
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        threads = {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]}
        self.gh.fail("reply", 500)
        res = result(no_issues=False, findings=[finding()], threads=[{"thread_id": tid, "verdict": "open", "reply": "x"}])
        self.assertEqual(self.run_publish(res, threads, MODE="rereview", CHANGES_EVENT="COMMENT"), 1)
        self.assertEqual(approved["state"], "DISMISSED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "COMMENT")

    def test_the_overview_is_a_fresh_render_with_no_history(self):
        self.run_publish(result(overview="Adds X."))
        self.run_publish(result(no_issues=False, findings=[finding()], overview="Adds Y."), GITHUB_RUN_ID="124",
                         MODE="rereview", GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created")
        body = self.overview()
        self.assertIn(f"<!-- claude-review:summary sha={HEAD} result=issues -->", body)
        self.assertIn("### Claude review · `aaaaaaa` · rereview", body)
        self.assertIn("Adds Y.", body)
        self.assertNotIn("Adds X.", body)
        self.assertNotIn("<details>", body)


class SchemaSubset(unittest.TestCase):
    """`conforms` checks a result against the schema file; it resolves a local $ref, which later schemas use."""

    def test_ref_and_the_keywords_the_schema_uses(self):
        conforms = load_publish()["conforms"]
        schema = {"type": "object", "required": ["a"], "properties": {
            "a": {"type": "array", "maxItems": 2, "items": {"$ref": "#/$defs/item"}}}, "$defs": {
            "item": {"type": "object", "required": ["n"], "properties": {
                "n": {"type": "integer"}, "s": {"type": "string", "maxLength": 3, "enum": ["x", "yy"]}}}}}
        good = {"a": [{"n": 1, "s": "yy"}, {"n": 2}]}
        self.assertTrue(conforms(schema, good, schema))
        for bad in ({}, {"a": [{"n": 1}] * 3}, {"a": [{"n": True}]}, {"a": [{}]}, {"a": [{"n": 1, "s": "z"}]},
                    {"a": [{"n": 1, "extra": 1}]}, {"a": [], "b": 1}, {"a": {}}, []):
            with self.subTest(bad=bad):
                self.assertFalse(conforms(schema, bad, schema))

    def test_the_shipped_schema_uses_only_what_conforms_checks(self):
        # A keyword conforms() skips would be enforced for Claude (--json-schema) but not here.
        known = {"type", "enum", "minLength", "maxLength", "maxItems", "items", "properties", "required",
                 "additionalProperties", "$ref", "$defs", "$schema", "description"}
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key == "properties":
                        for sub in value.values():
                            walk(sub)
                    else:
                        self.assertIn(key, known)
                        if key in ("items", "$defs"):
                            walk(value) if key == "items" else [walk(v) for v in value.values()]
            return None
        walk(json.loads(pathlib.Path(load_publish()["SCHEMA"]).read_text()))

    def test_an_empty_path_is_the_wrong_shape(self):
        ns = load_publish()
        schema = json.loads(pathlib.Path(ns["SCHEMA"]).read_text())
        bad = {"stopped": False, "no_issues": False, "overview": "", "threads": [],
               "findings": [{"path": "", "line": 1, "side": "RIGHT", "body": "b", "line_text": ""}]}
        self.assertFalse(ns["conforms"](schema, bad, schema))


class ResultChecks(PublishCase):
    def assert_nothing_posted(self):
        self.assertEqual(self.gh.app_reviews(), [])
        self.assertEqual(self.gh.issue_comments, [])

    def test_missing_result_fails_the_job(self):
        # has_result was true, so the download failed: a lost review must not end green.
        self.assertEqual(self.run_publish(), 1)
        self.assertIn("::error::", self.log)
        self.assert_nothing_posted()

    def test_oversize_result(self):
        (self.dir / "result.json").write_text(" " * ((1 << 20) + 1))
        self.run_publish()
        self.assertIn("larger than 1 MiB", self.log)
        self.assert_nothing_posted()

    def test_wrong_shapes(self):
        bad = [
            {"no_issues": True},
            result(extra=1),
            result(findings=[finding(side="MIDDLE")]),
            result(findings=[finding(line=True)]),
            result(findings=[finding(body="x" * 4001)]),
            result(findings=[finding()] * 9),
            result(findings=[{k: v for k, v in finding().items() if k != "line_text"}]),   # the schema requires it
            result(findings=[finding(start_line="2")]),
            result(threads=[{"thread_id": "t", "verdict": "open"}]),
            result(overview="x" * 601),
            result(threads=[{"thread_id": "t", "verdict": "maybe", "reply": ""}]),
        ]
        for res in bad:
            with self.subTest(res=str(res)[:60]):
                self.setUp()
                self.run_publish(res)
                self.assertIn("the wrong shape", self.log)
                self.assert_nothing_posted()

    def test_contradictions(self):
        # A stop outside an initial review is rejected: nothing is posted and nothing approves.
        self.run_publish(result(no_issues=False, stopped=True), MODE="rereview")
        self.assertIn("No verdict: Claude's result has", self.log)
        self.assert_nothing_posted()
        self.assertEqual(self.new_reviews(), [])

    def test_incomplete_review_says_so_without_a_verdict(self):
        # An incomplete full review fails closed: no_issues false with no findings gives no review in both full modes,
        # but the overview comment still says the review ran, so nobody waits on silence.
        for env in ({}, {"MODE": "rereview"}):
            with self.subTest(env=env):
                self.setUp()
                self.assertEqual(self.run_publish(result(no_issues=False, overview="One pass failed."), **env), 0)
                self.assertIn("No verdict: Claude's result has issues reported without findings", self.log)
                self.assertEqual(self.new_reviews(), [])
                self.assertIn("result=issues", self.overview())
                self.assertIn("Review incomplete: issues reported without findings. No verdict.", self.overview())
                self.assertIn("One pass failed.", self.overview())

    def test_incomplete_review_leaves_threads_alone(self):
        tid = self.open_app_thread()
        res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "Fixed."}])
        self.run_publish(res, MODE="rereview")
        self.assertEqual(len(self.gh.threads[tid]["comments"]), 1)
        self.assertEqual(self.new_reviews(), [])
        self.assertIn("Review incomplete", self.overview())

    def test_head_moved(self):
        self.gh.head = OLD
        self.run_publish(result(no_issues=False, findings=[finding()]))
        self.assertIn("the PR moved", self.log)
        self.assert_nothing_posted()

    def test_review_not_run(self):
        for outcome in ("failure", "cancelled", "skipped"):
            self.run_publish(result(), REVIEW_RESULT=outcome)
            self.assertIn("no verdict", self.log)
        self.assert_nothing_posted()

    def test_covered_without_retry(self):
        self.run_publish(HAS_RESULT="false", RAN="false", MODE="followup")
        self.assertIn("already covered", self.log)
        self.assertEqual(self.gh.calls, [])


class ThreadsAndMigration(PublishCase):
    def test_followup_replies_as_the_app_and_resolves_with_the_job_token(self):
        tid = self.open_app_thread()
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        threads = {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]}
        res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "Fixed in @x [y](z)."}])
        self.assertEqual(self.run_publish(res, threads, MODE="followup", GITHUB_EVENT_NAME="issue_comment"), 0, self.log)
        reply = self.gh.threads[tid]["comments"][-1]
        self.assertEqual(reply["author"], bot(APP))
        self.assertIn("verdict=resolved sha=" + HEAD + " mode=followup", reply["body"])
        self.assertNotIn("[y](z)", reply["body"])
        self.assertTrue(self.gh.threads[tid]["isResolved"])
        self.assertEqual(self.gh.tokens("reply"), {APP_TOKEN})
        self.assertEqual(self.gh.tokens("resolve"), {GH_TOKEN})
        self.assertIn("Follow-up: 1 resolved, 0 still open.", self.overview())

    def test_legacy_authors_are_not_this_reviews_threads_or_markers(self):
        legacy = self.gh.add_thread(bot("claude"), "Legacy finding.")
        last = int(self.gh.threads[legacy]["comments"][-1]["fullDatabaseId"])
        res = result(no_issues=False, threads=[{"thread_id": legacy, "verdict": "resolved", "reply": "Fixed."}])
        self.run_publish(res, {"head_sha": HEAD, "open": [{"thread_id": legacy, "last_comment_id": last}]}, MODE="followup")
        self.assertEqual(len(self.gh.threads[legacy]["comments"]), 1)   # no reply: not a thread the App started
        mine = self.open_app_thread()
        self.gh.thread_comment(mine, bot("github-actions"), followup_marker("resolved"))
        self.run_publish(HAS_RESULT="false", RAN="false", MODE="followup", RETRY_IDS=json.dumps([mine]))
        self.assertFalse(self.gh.threads[mine]["isResolved"])   # a legacy reply is not this workflow's marker

    def test_resolve_refuses_threads_it_did_not_start_or_mark(self):
        theirs = self.gh.add_thread(user("someone"), "A person's thread.")
        self.gh.thread_comment(theirs, bot(APP), followup_marker("resolved"))
        unmarked = self.open_app_thread()
        other_head = self.open_app_thread()
        self.gh.thread_comment(other_head, bot(APP), followup_marker("resolved", sha=OLD))
        self.run_publish(HAS_RESULT="false", MODE="followup", RETRY_IDS=json.dumps([theirs, unmarked, other_head]))
        self.assertFalse(any(self.gh.threads[t]["isResolved"] for t in (theirs, unmarked, other_head)))
        self.assertIn("3 skipped", self.log)

    def test_verdicts_only_for_collected_threads(self):
        tid = self.open_app_thread()
        res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "x"},
                                               {"thread_id": "PRRT_nope", "verdict": "resolved", "reply": "x"}])
        self.run_publish(res, {"head_sha": HEAD, "open": []}, MODE="followup")
        self.assertEqual(len(self.gh.threads[tid]["comments"]), 1)
        self.assertIn("not a collected open thread: 2", self.log)

    def test_reply_failure_fails_the_job_and_never_approves(self):
        tid = self.open_app_thread()
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        self.gh.fail("reply", 500)
        res = result(threads=[{"thread_id": tid, "verdict": "resolved", "reply": "x"}])
        rc = self.run_publish(res, {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]},
                              MODE="rereview")
        self.assertEqual(rc, 1)
        self.assertNotIn("APPROVE", [r["event"] for r in self.gh.app_reviews()])


class ReviewGateFixes(PublishCase):
    """Findings of the 2026-10-22 review gate (review/2026-10-22-findings.md)."""

    def test_rerun_after_reply_landed_and_resolve_failed_resolves(self):
        tid = self.open_app_thread()
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        threads = {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]}
        res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "Fixed."}])
        self.gh.fail("resolve", 502)
        self.assertEqual(self.run_publish(res, threads, MODE="followup"), 1, self.log)
        self.assertFalse(self.gh.threads[tid]["isResolved"])
        self.assertEqual(self.run_publish(res, threads, MODE="followup", GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertTrue(self.gh.threads[tid]["isResolved"])
        self.assertEqual(len(self.gh.threads[tid]["comments"]), 2)   # one reply, not two

    def test_failed_approval_fails_the_job_and_the_rerun_approves(self):
        self.gh.fail("submit review", 502)
        self.assertEqual(self.run_publish(result()), 1)
        self.assertEqual(self.gh.app_reviews(), [])
        # `clean` would mark the head covered, so a new request could not retry: it is written only with the approval.
        self.assertIn("result=issues", self.overview().splitlines()[0])
        self.assertIn("**Result:** A write failed: re-run this job. No verdict.", self.overview())
        self.assertEqual(self.run_publish(result(), GITHUB_RUN_ATTEMPT="2"), 0, self.log)
        self.assertEqual([r["event"] for r in self.gh.app_reviews()], ["APPROVE"])
        self.assertIn("result=clean", self.overview().splitlines()[0])
        self.assertIn("**Result:** No issues found.", self.overview())

    def test_failed_dismissal_still_posts_the_findings(self):
        approved = self.gh.add_review("APPROVED", commit_id=HEAD)
        self.gh.fail("dismiss", 403, "Forbidden")
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[finding()]), CHANGES_EVENT="COMMENT"), 1)
        self.assertEqual(approved["state"], "APPROVED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "COMMENT")
        self.assertIn("1 finding in the [review](", self.overview())

    def test_failed_dismissal_of_a_change_request_posts_no_approval_comment(self):
        changes = self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.gh.fail("dismiss", 403, "Forbidden")
        self.assertEqual(self.run_publish(result(), APPROVE_EVENT="COMMENT"), 1)
        self.assertEqual(changes["state"], "CHANGES_REQUESTED")
        self.assertEqual(len(self.gh.app_reviews()), 1)

    def test_dropped_findings_never_approve(self):
        self.run_publish(result(no_issues=True, findings=[finding(path="elsewhere.py")]))
        self.assertNotIn("APPROVE", [r["event"] for r in self.gh.app_reviews()])
        self.assertIn("No finding named one of this PR's files. No verdict.", self.overview())
        self.assertIn("result=issues", self.overview().splitlines()[0])

    def test_fork_pr_gets_a_comment_not_an_approval(self):
        self.gh.cross_repo = True
        self.run_publish(result())
        self.assertEqual([r["event"] for r in self.gh.app_reviews()], ["COMMENT"])
        self.setUp()
        self.gh.cross_repo = True
        changes = self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.run_publish(result())
        self.assertEqual(changes["state"], "DISMISSED")
        self.assertEqual(self.gh.app_reviews()[-1]["event"], "COMMENT")

    def test_push_during_approval_dismisses_it(self):
        self.gh.on_submit = lambda review: setattr(self.gh, "head", OLD)
        self.run_publish(result())
        [review] = self.gh.app_reviews()
        self.assertEqual(review["state"], "DISMISSED")

    def test_reply_refuses_a_thread_it_did_not_start(self):
        tid = self.gh.add_thread(user("someone"), "A person's thread.")
        last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
        res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "x"}])
        self.run_publish(res, {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]}, MODE="followup")
        self.assertEqual(len(self.gh.threads[tid]["comments"]), 1)
        self.assertFalse(self.gh.threads[tid]["isResolved"])

    def test_threads_on_another_pr_or_repository_are_refused(self):
        for where in ({"number": 8}, {"repo": "other/r"}):   # v2.5: one App can be installed on several repositories
            with self.subTest(**where):
                tid = self.gh.add_thread(bot(APP), "Elsewhere.")
                self.gh.threads[tid].update(where)
                last = int(self.gh.threads[tid]["comments"][-1]["fullDatabaseId"])
                res = result(no_issues=False, threads=[{"thread_id": tid, "verdict": "resolved", "reply": "x"}])
                self.run_publish(res, {"head_sha": HEAD, "open": [{"thread_id": tid, "last_comment_id": last}]},
                                 MODE="followup")
                self.assertEqual(len(self.gh.threads[tid]["comments"]), 1)
                self.gh.thread_comment(tid, bot(APP), followup_marker("resolved"))
                self.run_publish(HAS_RESULT="false", MODE="followup", RETRY_IDS=json.dumps([tid]))
                self.assertFalse(self.gh.threads[tid]["isResolved"])

class Placement(unittest.TestCase):
    def setUp(self):
        self.ns = load_publish()
        self.files = {"src/a.py": self.ns["parse_patch"](PATCH), "bin.png": None,
                      "two.py": self.ns["parse_patch"]("@@ -1,2 +1,2 @@\n-a\n+b\n c\n@@ -10,2 +10,3 @@\n x\n+y\n z\n\\ No newline at end of file")}

    def place(self, **kw):
        return self.ns["place"](finding(**kw), self.files)[0]

    def test_sides(self):
        self.assertEqual(self.ns["parse_patch"](PATCH), {"LEFT": {1: (0, "line1"), 2: (0, "old2"), 3: (0, "line3")},
                                                         "RIGHT": {1: (0, "line1"), 2: (0, "new2"), 3: (0, "new3"),
                                                                   4: (0, "line3")}})
        self.assertEqual(self.place(line=2, side="LEFT"), "inline")    # removed line
        self.assertEqual(self.place(line=3, side="RIGHT"), "inline")   # added line
        self.assertEqual(self.place(line=4, side="RIGHT"), "inline")   # context
        self.assertEqual(self.place(line=4, side="LEFT"), "body")
        self.assertEqual(self.place(line=0), "body")

    def test_ranges(self):
        self.assertEqual(self.place(path="two.py", line=12, start_line=10), "inline")
        self.assertEqual(self.place(path="two.py", line=11, start_line=1), "body")     # other hunk
        self.assertEqual(self.place(path="two.py", line=10, start_line=12), "body")    # backwards
        self.assertEqual(self.place(line=3, start_line=3), "inline")                   # a range of one line
        self.assertEqual(self.place(line=4, start_line=2, start_side="LEFT"), "inline")
        self.assertEqual(self.place(line=4, start_line=1, start_side="LEFT"), "inline")

    def test_no_patch_and_unknown_file(self):
        self.assertEqual(self.place(path="bin.png", line=1), "body")
        self.assertEqual(self.place(path="nope.py"), "drop")
        self.assertEqual(self.ns["place"](finding(), None)[0], "body")


# A new file, as Claude miscounted it in the live test (row b): it counted lines in pr.diff, 6 header lines too many.
NEW_FILE = ("@@ -0,0 +1,8 @@\n+def chunk(items, size):\n+    out = []\n+    for i in range(0, len(items) - size + 1, size):\n"
            "+        out.append(items[i:i + size])\n+    return out\n+\n+def clamp(v, lo, hi):\n+    return max(hi, min(lo, v))")
CHUNK_LOOP = "    for i in range(0, len(items) - size + 1, size):"
CLAMP_RETURN = "    return max(hi, min(lo, v))"


class PlacementByText(unittest.TestCase):
    """L1 (Wave 5 live test): a finding names its line's text, and publish checks the line number against it."""

    def setUp(self):
        self.ns = load_publish()
        parse = self.ns["parse_patch"]
        self.files = {"new.py": parse(NEW_FILE), "src/a.py": parse(PATCH),
                      "dup.py": parse("@@ -0,0 +1,4 @@\n+def a():\n+    return out\n+def b():\n+    return out"),
                      "c.js": parse("@@ -0,0 +1,3 @@\n+if (x) {\n+  y();\n+}")}

    def place(self, **kw):
        return self.ns["place"](finding(**kw), self.files)

    def test_wrong_line_moves_to_the_line_with_that_text(self):
        self.assertEqual(self.place(path="new.py", line=9, line_text=CHUNK_LOOP),
                         ("moved", {"path": "new.py", "line": 3, "side": "RIGHT"}))

    def test_line_past_the_hunk_moves_too(self):
        self.assertEqual(self.place(path="new.py", line=14, line_text=CLAMP_RETURN)[1]["line"], 8)

    def test_matching_text_stays(self):
        self.assertEqual(self.place(path="new.py", line=3, line_text=CHUNK_LOOP)[0], "inline")
        self.assertEqual(self.place(line=2, line_text="  new2  ")[0], "inline")   # whitespace doesn't count

    def test_text_on_two_lines_goes_to_the_body(self):
        self.assertEqual(self.place(path="dup.py", line=3, line_text="return out"), ("body", None))

    def test_text_nowhere_in_the_diff_goes_to_the_body(self):
        self.assertEqual(self.place(path="new.py", line=3, line_text="print('gone')"), ("body", None))

    def test_short_text_is_checked_but_never_moved(self):
        self.assertEqual(self.place(path="c.js", line=1, line_text="}"), ("body", None))
        self.assertEqual(self.place(path="c.js", line=3, line_text="}")[0], "inline")

    def test_moved_range_goes_to_the_body(self):
        # Only `line` has a text to check: a range's start may be miscounted differently, and a suggestion written for
        # the range would replace the wrong lines (review S3).
        self.assertEqual(self.place(path="new.py", line=9, start_line=8, line_text=CHUNK_LOOP), ("body", None))
        self.assertEqual(self.place(path="new.py", line=14, start_line=1, line_text=CLAMP_RETURN), ("body", None))
        self.assertEqual(self.place(path="new.py", line=9, start_line=9, line_text=CHUNK_LOOP)[0], "moved")   # one line

    def test_whitespace_inside_the_line_and_a_truncated_text(self):   # review C7
        self.assertEqual(self.place(path="new.py", line=3, line_text=CHUNK_LOOP.replace(" in ", "  in "))[0], "inline")
        self.files["long.py"] = self.ns["parse_patch"]("@@ -0,0 +1,2 @@\n+x = 1\n+y = '" + "a" * 600 + "'")
        cut = ("y = '" + "a" * 600)[:500]
        self.assertEqual(self.place(path="long.py", line=2, line_text=cut)[0], "inline")
        self.assertEqual(self.place(path="long.py", line=8, line_text=cut), ("moved", {"path": "long.py", "line": 2, "side": "RIGHT"}))
        self.assertEqual(self.place(path="long.py", line=2, line_text=cut[:400]), ("body", None))   # a prefix only at 500

    def test_left_side(self):
        self.assertEqual(self.place(line=3, side="LEFT", line_text="old2")[1], {"path": "src/a.py", "line": 2, "side": "LEFT"})

    def test_an_empty_line_text_skips_the_text_check(self):
        self.assertEqual(self.place(path="new.py", line=3)[0], "inline")


class FoldBack(PublishCase):
    """Findings of the Wave 5 live test (L1, L6) and the delta re-review follow-ups (F3, F5)."""

    def test_moved_finding_is_posted_on_the_right_line_and_counted(self):
        self.gh.add_file("new.py", NEW_FILE)
        self.assertEqual(self.run_publish(result(no_issues=False, findings=[
            finding(path="new.py", line=9, line_text=CHUNK_LOOP)])), 0, self.log)
        [comment] = self.gh.review_comments
        self.assertEqual(comment["line"], 3)
        self.assertNotIn("line_text", comment)
        self.assertIn("1 inline, 0 in body, 0 dropped, 1 moved,", self.log)

    def test_moved_counts_only_what_was_posted_inline(self):   # review C5
        self.gh.add_file("new.py", NEW_FILE)
        self.gh.fail("submit review", 422, "Validation Failed")
        self.run_publish(result(no_issues=False, findings=[finding(path="new.py", line=9, line_text=CHUNK_LOOP)]))
        self.assertIn("0 inline, 1 in body, 0 dropped, 0 moved,", self.log)
        self.assertIn("**`new.py` line 3**", self.gh.app_reviews()[-1]["body"])   # the body heading has the checked line

    def test_unreadable_head_after_an_approval_fails_the_job(self):   # F3
        self.gh.on_submit = lambda review: self.gh.fail("head", 502)
        self.assertEqual(self.run_publish(result()), 1)
        self.assertIn("::warning::Re-reading the PR head after the approval failed", self.log)

    def test_moved_pr_still_dismisses_a_stale_approval(self):   # F3
        approval = self.gh.add_review("APPROVED", commit_id=HEAD)
        self.gh.head = "c" * 40
        self.run_publish(result(), MODE="rereview", GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created")
        self.assertIn("the PR moved", self.log)
        self.assertEqual(approval["state"], "DISMISSED")

    def test_cross_repo_until_known(self):   # F5
        self.assertIs(load_publish()["Ctx"](self.env).cross_repo, True)

    def test_verdict_events_are_two_values_each(self):   # the kit's inputs changes-event and approve-event
        Ctx = load_publish()["Ctx"]
        for key, bad in (("CHANGES_EVENT", "APPROVE"), ("CHANGES_EVENT", ""), ("APPROVE_EVENT", "approve"),
                         ("APPROVE_EVENT", "REQUEST_CHANGES")):
            with self.subTest(key=key, value=bad), self.assertRaises(SystemExit):
                Ctx(dict(self.env, **{key: bad}))
        Ctx(dict(self.env, CHANGES_EVENT="COMMENT", APPROVE_EVENT="COMMENT"))


class FixedIssueIsBack(PublishCase):
    """Live finding L7 (a rereview APPROVEd with the bug back), settled since v4.0: a regression is an ordinary finding."""

    def setUp(self):
        super().setUp()
        self.tid = self.gh.add_thread(bot(APP), "SQL injection.", "src/a.py", 2, resolved=True)
        self.gh.thread_comment(self.tid, bot(APP), followup_marker("resolved", sha=OLD, mode="rereview"))

    def rereview(self, findings, **env):
        return self.run_publish(result(no_issues=False, findings=findings), save_threads({"head_sha": HEAD, "open": []}),
                                MODE="rereview", GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created", **env)

    def test_it_is_posted_as_a_new_finding_and_asks_for_changes(self):
        self.assertEqual(self.rereview([finding(body="The f-string is back.")]), 0, self.log)
        [comment] = self.gh.review_comments
        self.assertEqual(comment["body"], "The f-string is back.")
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        self.assertIn("result=issues", self.overview().splitlines()[0])
        self.assertTrue(self.gh.threads[self.tid]["isResolved"])   # the old thread is left as it was
        self.assertEqual(len(self.gh.threads[self.tid]["comments"]), 2)
        self.assertNotIn("resolve", {r for _, r, _ in self.gh.calls})   # no thread write at all

    def test_the_reopens_key_is_gone(self):
        self.rereview([finding(body="Back.", reopens=self.tid)])
        self.assertIn("No verdict: Claude's result is the wrong shape", self.log)
        self.assertEqual(self.gh.review_comments, [])


MARK = "<!-- claude-review:suggestion -->"


def suggestion(body="Fold the special case into the general path; saves 4 lines.", **kw):
    return finding(body=body, **kw)


class Suggestions(PublishCase):
    """The `suggestions` list: non-blocking inline comments that never change the verdict and are never followed up."""

    def posted(self):
        return [c["body"] for c in self.gh.review_comments]

    def test_only_suggestions_approve_and_ride_on_the_approval(self):
        self.assertEqual(self.run_publish(result(suggestions=[suggestion()])), 0, self.log)
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "APPROVE")
        [body] = self.posted()
        self.assertEqual(body, MARK + "\n**Suggestion (non-blocking):**\n\nFold the special case into the general path; saves 4 lines.")
        overview = self.overview()
        self.assertIn("result=clean", overview)
        self.assertIn("**Result:** No issues found. 1 suggestion (non-blocking).", overview)
        self.assertIn("**Threads:** 0 resolved · 0 still open", overview)   # a suggestion thread is not counted
        self.assertIn("1 suggested", self.log)

    def test_findings_decide_the_verdict_and_suggestions_come_along(self):
        res = result(no_issues=False, findings=[finding(line=3)], suggestions=[suggestion(), suggestion(line=3, body="Other.")])
        self.run_publish(res)
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        self.assertEqual(len(self.gh.review_comments), 3)
        self.assertEqual(sum(b.startswith(MARK) for b in self.posted()), 2)
        self.assertIn("1 finding in the [review](", self.overview())
        self.assertIn("2 suggestions (non-blocking).", self.overview())

    def test_an_open_thread_still_blocks_and_a_suggestion_thread_does_not(self):
        self.gh.add_thread(bot(APP), MARK + "\n**Suggestion (non-blocking):**\n\nOld one.")
        self.run_publish(result())
        self.assertEqual([r["event"] for r in self.new_reviews()], ["APPROVE"])
        self.setUp()
        self.open_app_thread()
        self.run_publish(result(suggestions=[suggestion()]))
        self.assertEqual([r["event"] for r in self.new_reviews()], ["REQUEST_CHANGES"])
        self.assertEqual(len(self.gh.review_comments), 1)

    def test_a_suggestion_that_cannot_go_inline_is_dropped_not_put_in_the_body(self):
        res = result(suggestions=[suggestion(line=40), suggestion(path="elsewhere.py")])
        self.run_publish(res)
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "APPROVE")
        self.assertEqual(self.gh.review_comments, [])
        self.assertNotIn("Not on a changed line", review["body"])
        self.assertIn("2 dropped", self.log)
        self.assertNotIn("suggestion", self.overview().split("**Threads:**")[0].split("**Result:**")[1])

    def test_the_schema_holds_the_cap_and_the_shape(self):
        for bad in ([suggestion()] * 4, [{"path": "src/a.py", "line": 2, "side": "RIGHT", "body": "b"}],
                    [dict(suggestion(), severity="high")], {"path": "x"}, [suggestion(side="MIDDLE")]):
            with self.subTest(bad=bad):
                self.setUp()
                self.run_publish(result(suggestions=bad))
                self.assertIn("No verdict: Claude's result is the wrong shape", self.log)
                self.assertEqual(self.gh.app_reviews(), [])

    def test_a_suggestion_is_posted_even_where_the_verdict_is_already_in_place(self):
        self.gh.add_review("APPROVED", commit_id=HEAD)
        self.run_publish(result(suggestions=[suggestion()]))
        self.assertEqual([r["event"] for r in self.new_reviews(1)], ["APPROVE"])
        self.setUp()
        self.open_app_thread()
        self.gh.add_review("CHANGES_REQUESTED", commit_id=OLD)
        self.run_publish(result(suggestions=[suggestion()]))
        self.assertEqual([r["event"] for r in self.new_reviews(1)], ["REQUEST_CHANGES"])

    def test_a_refused_review_gives_up_the_suggestions_before_it_moves_a_finding(self):
        self.gh.fail("submit review", 422, "Validation Failed")
        self.run_publish(result(no_issues=False, findings=[finding(body="Real bug.")], suggestions=[suggestion(line=3)]))
        [review] = self.new_reviews()
        self.assertEqual(review["event"], "REQUEST_CHANGES")
        [comment] = self.gh.review_comments   # the finding keeps its line; no suggestion rode along
        self.assertEqual(comment["body"], "Real bug.")
        self.assertNotIn("suggestion", self.overview().split("**Threads:**")[0].split("**Result:**")[1])

    def test_a_review_refused_twice_moves_the_findings_to_the_body_and_never_a_suggestion(self):
        self.gh.fail("submit review", 422, "Validation Failed")
        self.gh.fail("submit review", 422, "Validation Failed")
        self.run_publish(result(no_issues=False, findings=[finding(body="Real bug.")], suggestions=[suggestion(line=3)]))
        [review] = self.new_reviews()
        self.assertEqual(self.gh.review_comments, [])
        self.assertIn("Real bug.", review["body"])
        self.assertNotIn("Fold the special case", review["body"])

    def test_a_marker_in_claudes_text_is_stripped_and_a_suggestion_block_survives(self):
        forged = "Real.\n" + MARK + " <!-- claude-review:suggestion -->"
        block = "Use this:\n```suggestion\nnew2 = 1\n```"
        self.run_publish(result(no_issues=False, findings=[finding(body=forged)], suggestions=[suggestion(line=3, body=block)]))
        by_line = {c["line"]: c["body"] for c in self.gh.review_comments}
        self.assertFalse(by_line[2].startswith(MARK))
        self.assertNotIn("claude-review:", by_line[2])
        self.assertTrue(by_line[3].startswith(MARK))
        self.assertIn("```suggestion\nnew2 = 1\n```", by_line[3])
        self.assertIn("1 still open", self.overview())   # the finding's thread is counted: it carries no marker

    def test_no_verdict_posts_no_suggestions(self):
        self.run_publish(result(no_issues=False, suggestions=[suggestion()]))   # incomplete: nothing found, not clean
        self.assertEqual(self.gh.review_comments, [])
        self.setUp()
        self.run_publish(result(no_issues=False, stopped=True, suggestions=[suggestion()]))
        self.assertEqual(self.gh.review_comments, [])
        self.setUp()
        self.run_publish(result(no_issues=False, suggestions=[suggestion()]), MODE="followup")
        self.assertEqual(self.gh.review_comments, [])
        self.setUp()
        self.run_publish(result(no_issues=False, suggestions=[suggestion()]), REVIEW_RESULT="failure")
        self.assertEqual(self.gh.review_comments, [])

    def test_a_verdict_for_a_suggestion_thread_is_not_followed(self):   # collect keeps it out of `open`: test_collect.py
        self.run_publish(result(suggestions=[suggestion()]))
        [tid] = [t for t in self.gh.threads]
        collected = save_threads({"head_sha": HEAD, "open": []})   # collect.py keeps suggestion threads out of `open`
        res = result(threads=[{"thread_id": tid, "verdict": "resolved", "reply": "Applied."}])
        self.run_publish(res, collected, MODE="rereview", GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created",
                         GITHUB_RUN_ID="124")
        self.assertIn("skipped, not a collected open thread: 1", self.log)
        self.assertFalse(self.gh.threads[tid]["isResolved"])
        self.assertEqual(len(self.gh.threads[tid]["comments"]), 1)   # no reply


if __name__ == "__main__":
    unittest.main()
