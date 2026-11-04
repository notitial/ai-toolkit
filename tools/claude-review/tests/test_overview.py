"""The Claude-written overview: `overview_slot` (one safe paragraph) and how `publish` puts it in the sticky comment."""
import unittest

from test_publish import PublishCase, result
from workflow import load_publish

Z = "​"
OPEN, CLOSE = "<!-- claude-review:overview -->", "<!-- /claude-review:overview -->"


class OverviewSlot(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.slot = staticmethod(load_publish()["overview_slot"])

    def check(self, text, expected):
        self.assertEqual(self.slot(text), expected)

    def test_plain_text_unchanged(self):
        self.check("Adds a cache. No issues found.", "Adds a cache. No issues found.")

    def test_multiline_collapsed(self):
        self.check("Adds a cache.\n\n  No   issues\tfound.\r\n", "Adds a cache. No issues found.")

    def test_code_span_kept(self):
        self.check("Renames `foo_bar` safely.", "Renames `foo_bar` safely.")

    def test_link_and_image(self):
        self.check("See [x](http://e/y) ![a](http://e/z.png)",
                   f"See \\[x\\](http:/{Z}/e/y) !\\[a\\](http:/{Z}/e/z.png)")

    def test_html_and_entities(self):
        self.check("<b>hi</b> &amp; <img src=x>", "\\<b\\>hi\\</b\\> \\&amp; \\<img src=x\\>")

    def test_mention_url_and_cross_repo(self):
        self.check("cc @octo see https://e.com and www.e.com and o/r#5",
                   f"cc @{Z}octo see https:/{Z}/e.com and www{Z}.e.com and o/r#{Z}5")

    def test_fence_stays_one_line(self):
        out = self.slot("```python\nprint(1)\n```")
        self.assertNotIn("\n", out)
        self.assertEqual(out, "```python print(1) ```")   # a code span on one line, not a fenced block
        self.assertEqual(self.slot("```python\nprint(1)"), "\\`\\`\\`python print(1)")

    def test_block_markers_escaped(self):
        self.check("# Title", "\\# Title")
        self.check("- item", "\\- item")
        self.check("+ item", "\\+ item")
        self.check("* item", "\\* item")
        self.check("1. item", "1\\. item")
        self.check("2) item", "2\\) item")
        self.check("> quote", "\\> quote")
        self.check("| a | b |", "\\| a | b |")
        self.check("---", "\\---")
        self.check("===", "\\===")
        self.check("***", "\\***")
        self.check("___", "\\___")

    def test_marker_after_collapse(self):
        self.check("\n\n  # Heading\nmore", "\\# Heading more")

    def test_non_markers_untouched(self):
        self.check("2026 was fine. -5 is odd. *emph*", "2026 was fine. -5 is odd. *emph*")

    def test_markers_removed(self):
        self.check("a <!-- claude-review:overview --> b", "a overview b")
        self.check("a --> b", "a b")
        self.check("<!-- note -->Hi", "note Hi")
        self.check("<!<!-- --> --claude-review:>", "\\<!")   # re-assembled markers are removed too

    def test_empty(self):
        self.check("", "")
        self.check("  \n\t \r\n ", "")
        self.check("<!-- -->", "")

    def test_600_characters(self):
        out = self.slot(("Sentence number one is fine. " * 30)[:600])
        self.assertNotIn("\n", out)
        self.assertEqual(len(out), 599)  # the trailing space is stripped

    def test_600_with_newlines(self):
        out = self.slot("\n".join(["word"] * 120))
        self.assertNotIn("\n", out)
        self.assertEqual(out, " ".join(["word"] * 120))


class OverviewComment(PublishCase):
    def slot_of(self, body):
        self.assertIn(OPEN, body)
        return body.split(OPEN, 1)[1].split(CLOSE, 1)[0]

    def test_clean_initial_review_fills_the_slot(self):
        self.assertEqual(self.run_publish(result(overview="Adds X. No issues found.")), 0, self.log)
        self.assertIn(OPEN + "\nAdds X. No issues found.\n" + CLOSE, self.overview())

    def test_followup_keeps_the_slot(self):
        self.run_publish(result(overview="Adds X. No issues found."))
        self.assertEqual(self.run_publish(result(no_issues=False), MODE="followup", GITHUB_RUN_ID="124",
                                         GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created"), 0,
                         self.log)
        self.assertIn(OPEN + "\nAdds X. No issues found.\n" + CLOSE, self.overview())

    def test_stopped_leaves_the_slot_empty(self):
        self.assertEqual(self.run_publish(result(no_issues=False, stopped=True, overview="ignored")), 0, self.log)
        self.assertIn(OPEN + "\n" + CLOSE, self.overview())

    def test_rereview_replaces_the_slot(self):
        self.run_publish(result(overview="Adds X. No issues found."))
        self.assertEqual(self.run_publish(result(overview="Now also adds Y."), MODE="rereview", GITHUB_RUN_ID="124",
                                          GITHUB_EVENT_NAME="issue_comment", EVENT_ACTION="created"), 0, self.log)
        body = self.overview()
        self.assertIn(OPEN + "\nNow also adds Y.\n" + CLOSE, body)
        self.assertNotIn("Adds X.", self.slot_of(body))
        self.assertIn("History (last 2 runs)", body)

    def test_overview_that_sanitizes_to_empty_leaves_the_slot_empty(self):
        self.assertEqual(self.run_publish(result(overview="<!-- --> -->")), 0, self.log)
        self.assertIn(OPEN + "\n" + CLOSE, self.overview())


if __name__ == "__main__":
    unittest.main()
