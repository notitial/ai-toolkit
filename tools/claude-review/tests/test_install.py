"""The README's SHA table is current for the two vendored files (the command, and the frozen v3.4 workflow that repos
not yet on the reusable kit still copy). This repo's own review workflow is a thin caller of the reusable kit
(test_workflow.py), and the kit reads the command from its own checkout: this repo installs no copy."""
import hashlib, re, unittest

from workflow import COMMAND, FROZEN, HERE


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Install(unittest.TestCase):
    def test_readme_sha_table_is_current(self):
        readme = (HERE.parent / "README.md").read_text(encoding="utf-8")
        for canonical in (FROZEN, COMMAND):
            with self.subTest(file=canonical.name):
                row = re.search(r"^\| \[" + re.escape(canonical.name) + r"\]\([^)]*\) \|[^|]*\| `([0-9a-f]{64})` \|$",
                                readme, re.M)
                self.assertIsNotNone(row, f"no SHA row for {canonical.name} in the README")
                self.assertEqual(row.group(1), sha256(canonical), f"the README's SHA for {canonical.name} is stale")


if __name__ == "__main__":
    unittest.main()
