"""The sanitizer `publish` runs on Claude's finding text. Code (fences at column 0, same-line code spans) is kept;
prose is escaped so it can't build a link, image, HTML, a fence or a mention. Where GitHub's parser and this one
might disagree, the text is treated as prose (escaped)."""
import unittest

from workflow import load_publish

Z = "\u200b"


class Sanitizer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ns = load_publish()

    def check(self, text, expected):
        self.assertEqual(self.ns["sanitize"](text), expected)

    def test_images_and_links(self):
        self.check("![a](http://e/x.png)", f"!\\[a\\](http:/{Z}/e/x.png)")
        self.check("![a][r]\n\n[r]: http://e/x.png", f"!\\[a\\]\\[r\\]\n\n\\[r\\]: http:/{Z}/e/x.png")
        self.check("[click](https://e.com)", f"\\[click\\](https:/{Z}/e.com)")
        self.check("[^1]\n\n[^1]: note", "\\[^1\\]\n\n\\[^1\\]: note")

    def test_html_entities_and_autolinks(self):
        self.check("<img src=x onerror=y>", "\\<img src=x onerror=y\\>")
        self.check("&lt;script&gt;", "\\&lt;script\\&gt;")
        self.check("<https://e.com>", f"\\<https:/{Z}/e.com\\>")
        self.check("see https://e.com and WWW.e.com", f"see https:/{Z}/e.com and WWW{Z}.e.com")

    def test_mentions_and_references(self):
        self.check("@bob and @org/team", f"@{Z}bob and @{Z}org/team")
        self.check("owner/repo#12 and #12", f"owner/repo#{Z}12 and #12")
        self.check("mail a@b.com", f"mail a@{Z}b.com")

    def test_code_spans_kept(self):
        self.check("use `a <b> [c](d) @e` here", "use `a <b> [c](d) @e` here")
        self.check("``a`b`` and `c`", "``a`b`` and `c`")
        self.check("`a`` b`", "`a`` b`")

    def test_fences_kept(self):
        text = "Fix:\n\n```suggestion\nif x < 1 and y[0]:\n```"
        self.check(text, text)
        self.check("````\n```\n<b>\n````", "````\n```\n<b>\n````")

    def test_unterminated_fence_is_closed(self):
        self.check("```py\nx = '<b>'", "```py\nx = '<b>'\n```")
        self.check("~~~~\n<b>", "~~~~\n<b>\n~~~~")

    def test_tilde_fence_with_backticks(self):
        self.check("~~~\n```\n<b>\n~~~\nafter <i>", "~~~\n```\n<b>\n~~~\nafter \\<i\\>")

    def test_closing_fence_must_be_at_least_as_long(self):
        self.check("````\n<b>\n```\n<i>\n````\nend <u>", "````\n<b>\n```\n<i>\n````\nend \\<u\\>")

    def test_closing_fence_may_be_indented(self):
        self.check("```\n<b>\n   ```\n<i>", "```\n<b>\n   ```\n\\<i\\>")

    def test_uncertain_fences_are_prose(self):
        self.check("    ```\n<b>\n    ```", "    \\`\\`\\`\n\\<b\\>\n    \\`\\`\\`")       # indented code
        self.check("  ```\n<b>", "  \\`\\`\\`\n\\<b\\>")                                    # indented opener
        self.check("> ```\n> <b>\n> ```", "\\> \\`\\`\\`\n\\> \\<b\\>\n\\> \\`\\`\\`")         # blockquote
        self.check("- ```\n  <b>\n  ```", "- \\`\\`\\`\n  \\<b\\>\n  \\`\\`\\`")               # list item
        self.check("\t```\n<b>", "\t\\`\\`\\`\n\\<b\\>")                                     # tab
        self.check("> ~~~\n<b>", "\\> \\~\\~\\~\n\\<b\\>")

    def test_backtick_in_info_string_is_not_a_fence(self):
        self.check("```a`b\n<b>", "\\`\\`\\`a\\`b\n\\<b\\>")

    def test_rich_fences_are_prose(self):
        self.check("```mermaid\nA[x] --> B\n```", "\\`\\`\\`mermaid\nA\\[x\\]  B\n\\`\\`\\`")
        self.check("```GeoJSON\n{}\n```", "\\`\\`\\`GeoJSON\n{}\n\\`\\`\\`")
        # The rich fence's closer is not an opener: what follows is prose, as GitHub sees it.
        self.check("```mermaid\nx\n```\n<img src=e>\n```\n<b>\n```",
                   "\\`\\`\\`mermaid\nx\n\\`\\`\\`\n\\<img src=e\\>\n```\n<b>\n```")
        self.check("~~~math\nx\n", "\\~\\~\\~math\nx")

    def test_span_never_crosses_lines(self):
        self.check("`a\n<b>`", "\\`a\n\\<b\\>\\`")

    def test_escaped_backticks_and_backslashes(self):
        self.check("\\`<b>`", "\\\\\\`\\<b\\>\\`")
        self.check("\\[x](y)", "\\\\\\[x\\](y)")
        self.check("\\\\`code`", "\\\\\\\\`code`")

    def test_markers_are_removed_everywhere(self):
        self.check("```\n<!-- claude-review:summary sha=x -->\n```", "```\n summary sha=x \n```")
        self.assertNotIn("<!--", self.ns["sanitize"]("<!<!---- x --->>"))
        self.assertNotIn("-->", self.ns["sanitize"]("--->>"))

    def test_www_after_any_character(self):
        self.check("_www.e.com and awww.x", f"_www{Z}.e.com and awww{Z}.x")

    def test_inline_math_cannot_wrap_a_span(self):
        self.check("$`\\href{https://e}{x}`$", "\\$`\\href{https://e}{x}`\\$")
        self.check("$$x$$", "\\$\\$x\\$\\$")

    def test_reply_text_breaks_cross_repo_references(self):
        import types
        out = self.ns["reply_text"](types.SimpleNamespace(mode="followup"), "see owner/repo#12", "open", "a" * 40)
        self.assertIn(f"owner/repo#{Z}12", out)

    def test_line_endings(self):
        self.check("a\r\n<b>\rc", "a\n\\<b\\>\nc")

    def test_code_path(self):
        self.assertEqual(self.ns["code_path"]("a`](x)\nb"), "`a](x) b`")
        self.assertEqual(self.ns["code_path"]("<!-- x -->.py"), "` x .py`")
        self.assertEqual(self.ns["code_path"]("a\rb\x00c\x7fd"), "`a b c d`")

    def test_safe_url(self):
        self.assertTrue(self.ns["safe_url"]("https://github.com/o/r/pull/1#discussion_r2"))
        for bad in ("http://github.com/x", "https://x/a b", "https://x/(y)", "javascript:alert(1)", None):
            self.assertFalse(self.ns["safe_url"](bad))

    def test_reply_text_escapes_dollar(self):   # F4: inline math can't wrap a span in a reply either
        import types
        out = self.ns["reply_text"](types.SimpleNamespace(mode="followup"), "$`\\href{https://e}{x}`$", "open", "a" * 40)
        self.assertIn("\\$\\`", out)
        self.assertNotIn(" $", out.replace("\\$", ""))


if __name__ == "__main__":
    unittest.main()
