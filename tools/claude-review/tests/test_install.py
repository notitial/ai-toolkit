"""This repo runs the kit it ships: its installed copies equal the canonical files, and the README's SHA table is
current. This repo's runners are the canonical `ubuntu-latest`, so no replacement point applies here."""
import hashlib, re, unittest

from workflow import HERE, INSTALLED


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Install(unittest.TestCase):
    def test_installed_copies_equal_the_canonical_files(self):
        for canonical, installed in INSTALLED.items():
            with self.subTest(file=canonical.name):
                self.assertTrue(installed.is_file(), f"{installed} is missing")
                self.assertEqual(installed.read_bytes(), canonical.read_bytes(),
                                 f"{installed} differs from the kit's {canonical.name}: copy it again")

    def test_readme_sha_table_is_current(self):
        readme = (HERE.parent / "README.md").read_text(encoding="utf-8")
        for canonical in INSTALLED:
            with self.subTest(file=canonical.name):
                row = re.search(r"^\| \[" + re.escape(canonical.name) + r"\]\([^)]*\) \|[^|]*\| `([0-9a-f]{64})` \|$",
                                readme, re.M)
                self.assertIsNotNone(row, f"no SHA row for {canonical.name} in the README")
                self.assertEqual(row.group(1), sha256(canonical), f"the README's SHA for {canonical.name} is stale")


if __name__ == "__main__":
    unittest.main()
