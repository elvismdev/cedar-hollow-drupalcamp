# Tests for audit_records.py, the strict reader merge-records.py and
# render-issue.py share. The module is loaded by path, as both scripts load it.
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SA = os.path.dirname(HERE)
SPEC = importlib.util.spec_from_file_location("audit_records", os.path.join(SA, "audit_records.py"))
records = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(records)


class ReaderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def file(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as handle:
            handle.write(data)
        return path

    def test_reads_one_strict_json_value(self):
        self.assertEqual(records.read_json(self.file("ok.json", b'{"a": [1, 2]}'), 100), {"a": [1, 2]})

    def test_refuses_duplicate_keys_non_finite_numbers_and_deep_nesting(self):
        for data in (b'{"a": 1, "a": 2}', b'[NaN]', b'[Infinity]', b"[" * 100000 + b"]" * 100000):
            with self.subTest(data=data[:20]):
                with self.assertRaises(ValueError):
                    records.read_json(self.file("bad.json", data), 1024 * 1024)

    def test_refuses_a_symlink_a_hardlink_and_an_oversized_file(self):
        target = self.file("target.json", b"{}")
        link = os.path.join(self.tmp, "link.json")
        os.symlink(target, link)
        with self.assertRaisesRegex(records.Refused, "symlink"):
            records.read_json(link, 100)
        os.link(target, os.path.join(self.tmp, "second.json"))
        with self.assertRaisesRegex(records.Refused, "hardlinked"):
            records.read_json(target, 100)
        with self.assertRaisesRegex(records.Refused, "oversized"):
            records.read_json(self.file("big.json", b"[" + b"1," * 100 + b"1]"), 100)

    def test_both_scripts_load_it_under_isolated_mode(self):
        for script in ("merge-records.py", "render-issue.py"):
            with self.subTest(script=script):
                result = subprocess.run([sys.executable, "-I", os.path.join(SA, script), "--help"],
                                        capture_output=True, text=True, cwd=self.tmp)
                self.assertEqual(result.returncode, 0, result.stderr)
                with open(os.path.join(SA, script), encoding="utf-8") as handle:
                    source = handle.read()
                self.assertIn('os.path.join(HERE, "audit_records.py")', source)
                self.assertNotIn("def parse_strict", source)


if __name__ == "__main__":
    unittest.main()
