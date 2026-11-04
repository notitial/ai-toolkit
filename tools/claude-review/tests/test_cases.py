"""The reviewer cases under tools/claude-review/cases/: every case.json has the fields cases/README.md names."""
import json, pathlib, re, unittest

CASES = pathlib.Path(__file__).resolve().parent.parent / "cases"
SHA = re.compile(r"^[0-9a-f]{40}$")
TOP = {"id", "kind", "title", "reviewedPr", "baseSha", "headSha", "appReview", "fix", "anchors", "expected",
       "hitCriterion", "checkedBy", "checkedOn", "notes"}


class Cases(unittest.TestCase):
    def cases(self):
        found = sorted(p for p in CASES.iterdir() if p.is_dir())
        if not found:   # the set starts empty in a new repo: cases/README.md says how to add the first
            self.skipTest("no cases yet")
        return found

    def test_each_case_has_the_documented_shape(self):
        for d in self.cases():
            with self.subTest(case=d.name):
                c = json.loads((d / "case.json").read_text())
                self.assertEqual(set(c), TOP)
                self.assertEqual(c["id"], d.name)
                self.assertRegex(d.name, r"^\d{4}-\d\d-\d\d-[a-z0-9-]+$")
                self.assertIn(c["kind"], {"miss", "hit", "clean"})
                self.assertIsInstance(c["reviewedPr"], int)
                for k in ("baseSha", "headSha"):
                    self.assertRegex(c[k], SHA)
                self.assertNotEqual(c["baseSha"], c["headSha"])
                self.assertRegex(c["appReview"]["sha"], r"^[0-9a-f]{40}$")
                self.assertRegex(c["fix"]["sha"], SHA)
                self.assertTrue(c["checkedBy"] and c["checkedOn"], "an unchecked case must not be committed")
                self.assertRegex(c["checkedOn"], r"^\d{4}-\d\d-\d\d$")
                for k in ("severity", "category", "summary"):
                    self.assertTrue(c["expected"][k].strip())
                self.assertTrue(c["hitCriterion"].strip())

    def test_anchors_are_well_formed_ranges(self):
        # Anchors are lines of the file as it was at headSha; the path may have moved since, so it is not looked up.
        for d in self.cases():
            c = json.loads((d / "case.json").read_text())
            self.assertTrue(c["anchors"])
            for a in c["anchors"]:
                with self.subTest(case=d.name, anchor=a["what"][:30]):
                    self.assertGreaterEqual(a["lineFrom"], 1)
                    self.assertGreaterEqual(a["lineTo"], a["lineFrom"])
                    self.assertTrue(a["what"].strip())
                    self.assertFalse(a["file"].startswith("/") or ".." in a["file"].split("/"))

    def test_no_email_address_in_a_case(self):
        for d in self.cases():
            self.assertNotRegex((d / "case.json").read_text(), r"[\w.+-]+@[\w-]+\.[\w.]+")


if __name__ == "__main__":
    unittest.main()
