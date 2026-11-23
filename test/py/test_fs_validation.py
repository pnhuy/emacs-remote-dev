"""T046: fs/* parameter validation (FR-035)."""
import os
import tempfile
import unittest

import helpers

METHODS_PATH = ["fs/stat", "fs/readdir", "fs/read", "fs/mkdir", "fs/delete",
                "fs/realpath", "fs/statvfs"]


class FsValidation(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()
        self.tmp = tempfile.mkdtemp()

    def assertInvalid(self, method, **params):
        r, err = self.d.call(method, **params)
        self.assertIsNotNone(err, "%s accepted %r" % (method, params))
        self.assertEqual(err["code"], -32602, (method, params, err))

    def test_nul_in_path_rejected(self):
        for m in METHODS_PATH:
            self.assertInvalid(m, path=self.tmp + "/a\0b")

    def test_non_string_path_rejected(self):
        for m in METHODS_PATH:
            for bad in (None, 5, ["x"], {"a": 1}, True):
                self.assertInvalid(m, path=bad)

    def test_empty_path_rejected(self):
        self.assertInvalid("fs/stat", path="")

    def test_two_path_methods(self):
        for m, a, b in (("fs/rename", "src", "dst"), ("fs/copy", "src", "dst"),
                        ("fs/link", "src", "dst"), ("fs/symlink", "target", "link")):
            self.assertInvalid(m, **{a: "x\0y", b: self.tmp + "/z"})
            self.assertInvalid(m, **{a: "x", b: 7})

    def test_mode_and_mtime_types(self):
        f = os.path.join(self.tmp, "f")
        open(f, "w").close()
        self.assertInvalid("fs/chmod", path=f, mode="755")
        self.assertInvalid("fs/chmod", path=f, mode=True)
        self.assertInvalid("fs/utime", path=f, mtime_ns=1.5)

    def test_rejected_inputs_have_no_side_effects(self):
        self.assertInvalid("fs/mkdir", path=self.tmp + "/d\0x")
        self.assertEqual(os.listdir(self.tmp), [])

    def test_valid_inputs_still_work(self):
        f = os.path.join(self.tmp, "ok")
        self.d.result("fs/write", path=f, data="aGk=")
        self.assertEqual(self.d.result("fs/stat", path=f)["size"], 2)
        self.d.result("fs/chmod", path=f, mode=0o600)
        # relative paths remain accepted (behaviour preserved)
        cwd = os.getcwd()
        try:
            os.chdir(self.tmp)
            self.assertTrue(self.d.result("fs/stat", path="ok"))
        finally:
            os.chdir(cwd)

    def test_session_survives_rejection(self):
        self.assertInvalid("fs/stat", path="a\0")
        self.assertTrue(self.d.result("hello")["version"])


if __name__ == "__main__":
    unittest.main()
