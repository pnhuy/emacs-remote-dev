"""Characterization tests for every frozen fs/* RPC method (T023)."""
import base64
import os
import stat
import tempfile
import unittest

import helpers


def b64(b):
    return base64.b64encode(b).decode()


class FsMethods(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()
        self.tmp = tempfile.mkdtemp(prefix="rdev-py-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, True))

    def p(self, *a):
        return os.path.join(self.tmp, *a)

    def test_stat_file_dir_missing(self):
        open(self.p("f"), "w").write("x")
        os.mkdir(self.p("d"))
        f = self.d.result("fs/stat", path=self.p("f"))
        self.assertEqual((f["type"], f["ftype"], f["size"]), ("file", "file", 1))
        self.assertEqual(self.d.result("fs/stat", path=self.p("d"))["type"], "dir")
        self.assertIsNone(self.d.result("fs/stat", path=self.p("none")))
        self.assertIsNone(self.d.result("fs/stat", path=self.p("f", "x")))
        for k in ("mode", "modestr", "mtime", "uid", "gid", "ino", "dev", "r", "w", "x"):
            self.assertIn(k, f)

    def test_stat_symlinks(self):
        open(self.p("f"), "w").write("x")
        os.symlink("f", self.p("l"))
        os.symlink("zzz", self.p("dangle"))
        l = self.d.result("fs/stat", path=self.p("l"))
        self.assertEqual((l["type"], l["ftype"], l["target"]), ("symlink", "file", "f"))
        g = self.d.result("fs/stat", path=self.p("dangle"))
        self.assertEqual((g["type"], g["ftype"]), ("symlink", None))

    def test_readdir(self):
        open(self.p("f"), "w").write("x")
        os.mkdir(self.p("d"))
        names = dict(self.d.result("fs/readdir", path=self.tmp))
        self.assertEqual(names, {"f": False, "d": True})
        att = dict(self.d.result("fs/readdir", path=self.tmp, attrs=True))
        self.assertEqual(att["d"]["type"], "dir")
        _, err = self.d.call("fs/readdir", path=self.p("nope"))
        self.assertEqual(err["data"]["errno"], "ENOENT")

    def test_read_write_roundtrip_binary(self):
        data = bytes(range(256)) * 3
        r = self.d.result("fs/write", path=self.p("b"), data=b64(data))
        self.assertIn("mtime", r)
        got = self.d.result("fs/read", path=self.p("b"))
        self.assertEqual(base64.b64decode(got["data"]), data)
        self.assertIn("mtime", got)

    def test_write_append_excl_mode(self):
        self.d.result("fs/write", path=self.p("a"), data=b64(b"1"))
        self.d.result("fs/write", path=self.p("a"), data=b64(b"2"), append=True)
        self.assertEqual(open(self.p("a"), "rb").read(), b"12")
        _, err = self.d.call("fs/write", path=self.p("a"), data=b64(b"x"), excl=True)
        self.assertEqual(err["data"]["errno"], "EEXIST")
        self.d.result("fs/write", path=self.p("m"), data=b64(b""), mode=0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.p("m")).st_mode), 0o600 & ~0)

    def test_read_missing_and_dir(self):
        _, err = self.d.call("fs/read", path=self.p("nope"))
        self.assertEqual(err["data"]["errno"], "ENOENT")
        os.mkdir(self.p("d"))
        _, err = self.d.call("fs/read", path=self.p("d"))
        self.assertEqual(err["data"]["errno"], "EISDIR")

    def test_mkdir_delete(self):
        self.assertFalse(self.d.result("fs/mkdir", path=self.p("x")))
        _, err = self.d.call("fs/mkdir", path=self.p("x"))
        self.assertEqual(err["data"]["errno"], "EEXIST")
        self.assertFalse(self.d.result("fs/mkdir", path=self.p("p", "q"), parents=True))
        self.assertTrue(self.d.result("fs/mkdir", path=self.p("p", "q"), parents=True))
        _, err = self.d.call("fs/delete", path=self.p("p"))
        self.assertEqual(err["data"]["errno"], "ENOTEMPTY")
        self.d.result("fs/delete", path=self.p("p"), recursive=True)
        self.assertFalse(os.path.exists(self.p("p")))
        open(self.p("f"), "w").close()
        self.d.result("fs/delete", path=self.p("f"))
        self.assertFalse(os.path.exists(self.p("f")))

    def test_delete_symlink_to_dir_removes_link_only(self):
        os.mkdir(self.p("d"))
        open(self.p("d", "keep"), "w").close()
        os.symlink("d", self.p("l"))
        self.d.result("fs/delete", path=self.p("l"), recursive=True)
        self.assertTrue(os.path.exists(self.p("d", "keep")))
        self.assertFalse(os.path.lexists(self.p("l")))

    def test_rename_copy(self):
        open(self.p("a"), "w").write("A")
        open(self.p("b"), "w").write("B")
        _, err = self.d.call("fs/rename", src=self.p("a"), dst=self.p("b"), overwrite=False)
        self.assertEqual(err["data"]["errno"], "EEXIST")
        self.d.result("fs/rename", src=self.p("a"), dst=self.p("b"))
        self.assertEqual(open(self.p("b")).read(), "A")
        self.d.result("fs/copy", src=self.p("b"), dst=self.p("c"))
        self.assertEqual(open(self.p("c")).read(), "A")
        os.mkdir(self.p("dir"))
        open(self.p("dir", "f"), "w").write("F")
        self.d.result("fs/copy", src=self.p("dir"), dst=self.p("dir2"))
        self.assertEqual(open(self.p("dir2", "f")).read(), "F")

    def test_chmod_utime(self):
        open(self.p("a"), "w").close()
        self.d.result("fs/chmod", path=self.p("a"), mode=0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.p("a")).st_mode), 0o600)
        self.d.result("fs/utime", path=self.p("a"), mtime_ns=1_000_000_000_000)
        self.assertEqual(os.stat(self.p("a")).st_mtime_ns, 1_000_000_000_000)

    def test_symlink_link_realpath_statvfs(self):
        open(self.p("a"), "w").write("A")
        self.d.result("fs/symlink", target="a", link=self.p("s"))
        self.assertEqual(os.readlink(self.p("s")), "a")
        _, err = self.d.call("fs/symlink", target="a", link=self.p("s"))
        self.assertEqual(err["data"]["errno"], "EEXIST")
        self.d.result("fs/symlink", target="b", link=self.p("s"), overwrite=True)
        self.assertEqual(os.readlink(self.p("s")), "b")
        self.d.result("fs/link", src=self.p("a"), dst=self.p("h"))
        self.assertEqual(os.stat(self.p("a")).st_nlink, 2)
        self.assertEqual(self.d.result("fs/realpath", path=self.p("h")),
                         os.path.realpath(self.p("h")))
        total, free, avail = self.d.result("fs/statvfs", path=self.tmp)
        self.assertTrue(total >= free >= 0 and avail >= 0)

    def test_unicode_filenames(self):
        name = "héllo ✓"
        self.d.result("fs/write", path=self.p(name), data=b64("x".encode()))
        self.assertIn(name, [n for n, _ in self.d.result("fs/readdir", path=self.tmp)])


if __name__ == "__main__":
    unittest.main()
