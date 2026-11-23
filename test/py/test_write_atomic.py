"""T032: fs/writeAtomic semantics (D-03)."""
import base64
import os
import stat
import tempfile
import unittest
from unittest import mock

import helpers


def b64(b):
    return base64.b64encode(b).decode()


class WriteAtomic(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()
        self.t = tempfile.TemporaryDirectory()
        self.addCleanup(self.t.cleanup)
        self.p = os.path.join(self.t.name, "f")

    def put(self, text=b"v1", mode=None):
        with open(self.p, "wb") as f:
            f.write(text)
        if mode is not None:
            os.chmod(self.p, mode)

    def wa(self, data=b"new", **kw):
        return self.d.call("fs/writeAtomic", path=self.p, data=b64(data), **kw)

    def test_capability_advertised(self):
        self.assertIn("fs.writeAtomic", self.d.result("hello")["capabilities"])

    def test_replaces_content_and_returns_version(self):
        self.put()
        v = self.d.result("fs/read", path=self.p)["version"]
        res, err = self.wa(expected=v)
        self.assertIsNone(err)
        self.assertTrue(res["atomic"])
        self.assertEqual(res["bytes"], 3)
        self.assertEqual(open(self.p, "rb").read(), b"new")
        self.assertEqual(res["version"]["size"], 3)

    def test_no_temp_files_left_and_temp_in_same_dir(self):
        self.put()
        self.wa()
        self.assertEqual(os.listdir(self.t.name), ["f"])

    def test_permissions_preserved(self):
        self.put(mode=0o640)
        self.wa()
        self.assertEqual(stat.S_IMODE(os.stat(self.p).st_mode), 0o640)

    def test_conflict_on_stale_version(self):
        self.put()
        v = self.d.result("fs/read", path=self.p)["version"]
        self.put(b"external-edit-longer")
        _, err = self.wa(expected=v)
        self.assertEqual(err["code"], -32010)
        self.assertEqual(open(self.p, "rb").read(), b"external-edit-longer")

    def test_conflict_when_deleted(self):
        self.put()
        v = self.d.result("fs/read", path=self.p)["version"]
        os.unlink(self.p)
        _, err = self.wa(expected=v)
        self.assertEqual(err["code"], -32010)
        self.assertFalse(os.path.exists(self.p))

    def test_force_overrides_conflict(self):
        self.put()
        v = self.d.result("fs/read", path=self.p)["version"]
        self.put(b"external")
        res, err = self.wa(expected=v, force=True)
        self.assertIsNone(err)
        self.assertEqual(open(self.p, "rb").read(), b"new")

    def test_create_new_and_create_false(self):
        res, err = self.wa()
        self.assertIsNone(err)
        os.unlink(self.p)
        _, err = self.wa(create=False)
        self.assertEqual(err["data"]["errno"], "ENOENT")

    def test_symlink_followed_by_default(self):
        self.put()
        link = os.path.join(self.t.name, "ln")
        os.symlink("f", link)
        res, err = self.d.call("fs/writeAtomic", path=link, data=b64(b"via-link"))
        self.assertIsNone(err)
        self.assertTrue(os.path.islink(link))
        self.assertEqual(open(self.p, "rb").read(), b"via-link")

    def test_hardlink_falls_back_non_atomic(self):
        self.put()
        os.link(self.p, os.path.join(self.t.name, "hl"))
        res, err = self.wa()
        self.assertIsNone(err)
        self.assertFalse(res["atomic"])
        self.assertEqual(open(os.path.join(self.t.name, "hl"), "rb").read(), b"new")

    def test_bad_checksum_rejected(self):
        self.put()
        _, err = self.wa(sha256="0" * 64)
        self.assertEqual(err["code"], -32013)
        self.assertEqual(open(self.p, "rb").read(), b"v1")

    def test_replace_failure_leaves_original_and_no_temp(self):
        self.put()
        m = helpers.load_module()
        s = m.Session(None, None)
        with mock.patch.object(m.os, "replace", side_effect=OSError(28, "No space")):
            with self.assertRaises(OSError):
                s.m_fs_writeAtomic(self.p, b64(b"new"))
        self.assertEqual(open(self.p, "rb").read(), b"v1")
        self.assertEqual(os.listdir(self.t.name), ["f"])

    def test_fsync_called(self):
        self.put()
        m = helpers.load_module()
        s = m.Session(None, None)
        with mock.patch.object(m.os, "fsync", wraps=os.fsync) as fs:
            s.m_fs_writeAtomic(self.p, b64(b"new"))
        self.assertGreaterEqual(fs.call_count, 1)

    def test_invalid_path_rejected(self):
        _, err = self.d.call("fs/writeAtomic", path="a\0b", data=b64(b"x"))
        self.assertIn(err["code"], (-32602, -32603))

    def test_read_and_write_return_versions(self):
        self.put()
        r = self.d.result("fs/read", path=self.p)
        self.assertEqual(set(r["version"]), {"mtime", "size", "ino", "dev"})
        w = self.d.result("fs/write", path=self.p, data=b64(b"abcd"))
        self.assertEqual(w["version"]["size"], 4)
        self.assertEqual(self.d.result("fs/stat", path=self.p)["version"], w["version"])

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_readonly_dir_writable_file_falls_back_in_place(self):
        self.put()
        os.chmod(self.t.name, 0o555)
        self.addCleanup(os.chmod, self.t.name, 0o755)
        res, err = self.wa()
        self.assertIsNone(err)
        self.assertFalse(res["atomic"])
        self.assertEqual(open(self.p, "rb").read(), b"new")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_readonly_dir_fallback_still_version_checked(self):
        self.put()
        v = self.d.result("fs/read", path=self.p)["version"]
        self.put(b"external-edit-longer")
        os.chmod(self.t.name, 0o555)
        self.addCleanup(os.chmod, self.t.name, 0o755)
        _, err = self.wa(expected=v)
        self.assertEqual(err["code"], -32010)
        self.assertEqual(open(self.p, "rb").read(), b"external-edit-longer")

    def test_symlink_not_followed_replaces_link_not_target(self):
        self.put()
        link = os.path.join(self.t.name, "ln")
        os.symlink("f", link)
        res, err = self.d.call("fs/writeAtomic", path=link, data=b64(b"x"),
                               follow_symlinks=False)
        self.assertIsNone(err)
        self.assertEqual(open(self.p, "rb").read(), b"v1")
        self.assertFalse(os.path.islink(link))
        self.assertEqual(open(link, "rb").read(), b"x")

    def test_stale_temp_of_dead_pid_swept(self):
        self.put()
        stale = os.path.join(self.t.name, ".rdev-tmp-999999999-deadbeef")
        live = os.path.join(self.t.name, ".rdev-tmp-%d-cafe0000" % os.getpid())
        for x in (stale, live):
            open(x, "w").close()
            os.utime(x, (1, 1))
        self.wa()
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(live))


if __name__ == "__main__":
    unittest.main()
