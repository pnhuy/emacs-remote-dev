"""T044: fs/statMany (cap fs.statMany)."""
import os
import tempfile
import unittest

import helpers


class StatMany(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()
        self.t = tempfile.TemporaryDirectory()
        self.addCleanup(self.t.cleanup)

    def test_capability(self):
        self.assertIn("fs.statMany", self.d.result("hello")["capabilities"])

    def test_mixed_results_in_order(self):
        a = os.path.join(self.t.name, "a")
        open(a, "w").write("hi")
        os.symlink("nowhere", os.path.join(self.t.name, "dangling"))
        paths = [a, os.path.join(self.t.name, "missing"), os.path.join(self.t.name, "dangling"),
                 os.path.join(a, "notdir"), self.t.name]
        r = self.d.result("fs/statMany", paths=paths)["results"]
        self.assertEqual([x["path"] for x in r], paths)
        self.assertEqual(r[0]["stat"]["size"], 2)
        self.assertIsNone(r[1]["stat"])                    # same as fs/stat: absent => null
        self.assertEqual(r[2]["stat"]["type"], "symlink") # lstat-based, like fs/stat
        self.assertIsNone(r[3]["stat"])
        self.assertEqual(r[4]["stat"]["type"], "dir")
        for x, p in zip(r, paths):
            one = self.d.result("fs/stat", path=p)
            for k in ("atime", "atime_ns"):   # atime may move between two reads
                for dct in (x["stat"], one):
                    if dct:
                        dct.pop(k, None)
            self.assertEqual(x["stat"], one)

    def test_permission_error_is_per_path(self):
        if os.geteuid() == 0:
            self.skipTest("root")
        d = os.path.join(self.t.name, "locked")
        os.mkdir(d)
        open(os.path.join(d, "f"), "w").close()
        os.chmod(d, 0)
        self.addCleanup(os.chmod, d, 0o700)
        ok = os.path.join(self.t.name, "ok")
        open(ok, "w").close()
        r = self.d.result("fs/statMany", paths=[os.path.join(d, "f"), ok])["results"]
        self.assertEqual(r[0]["error"]["errno"], "EACCES")
        self.assertIsNotNone(r[1]["stat"])

    def test_validation(self):
        for bad in ("x", [1], ["a\0b"], [""], None):
            _, err = self.d.call("fs/statMany", paths=bad)
            self.assertEqual(err["code"], -32602, bad)

    def test_limit(self):
        _, err = self.d.call("fs/statMany", paths=["/x"] * 5000)
        self.assertEqual(err["code"], -32011)

    def test_empty(self):
        self.assertEqual(self.d.result("fs/statMany", paths=[]), {"results": []})


if __name__ == "__main__":
    unittest.main()
