"""T033: fs/readChunk + beginWrite/writeChunk/commitWrite/abortWrite (FR-015)."""
import base64
import hashlib
import io
import os
import tempfile
import unittest

import helpers


def b64(b):
    return base64.b64encode(b).decode()


class Chunks(unittest.TestCase):
    def setUp(self):
        self.m = helpers.load_module()
        self.s = self.m.Session(io.BytesIO(), io.BytesIO())
        self.t = tempfile.TemporaryDirectory()
        self.addCleanup(self.t.cleanup)
        self.p = os.path.join(self.t.name, "f")

    def tmps(self):
        return [n for n in os.listdir(self.t.name) if n.startswith(".rdev-tmp-")]

    def put(self, data=b"old"):
        with open(self.p, "wb") as f:
            f.write(data)

    def code(self, fn, *a, **kw):
        with self.assertRaises(self.m.RpcError) as cm:
            fn(*a, **kw)
        return cm.exception.code

    def test_capability_and_limits(self):
        h = self.s.m_hello()
        self.assertIn("fs.chunk", h["capabilities"])
        self.assertEqual(h["limits"]["max_chunk"], self.m.MAX_CHUNK)

    def test_read_chunks_reassemble(self):
        data = os.urandom(10000)
        self.put(data)
        out, off = b"", 0
        while True:
            r = self.s.m_fs_readChunk(self.p, off, 4096)
            piece = base64.b64decode(r["data"])
            out += piece
            off += len(piece)
            if r["eof"]:
                break
        self.assertEqual(out, data)
        self.assertEqual(r["version"]["size"], 10000)

    def test_read_past_end_is_eof_empty(self):
        self.put(b"abc")
        r = self.s.m_fs_readChunk(self.p, 99, 10)
        self.assertEqual((r["data"], r["eof"]), ("", True))

    def test_read_length_over_limit(self):
        self.put()
        self.assertEqual(self.code(self.s.m_fs_readChunk, self.p, 0, self.m.MAX_CHUNK + 1), -32011)

    def test_read_expected_mismatch_conflicts(self):
        self.put(b"abc")
        v = self.s.m_fs_readChunk(self.p, 0, 1)["version"]
        self.put(b"abcdef")
        self.assertEqual(self.code(self.s.m_fs_readChunk, self.p, 0, 1, expected=v), -32010)

    def test_roundtrip_commit(self):
        self.put()
        data = os.urandom(5000)
        tid = self.s.m_fs_beginWrite(self.p, size=len(data))["tid"]
        self.assertEqual(len(self.tmps()), 1)
        self.s.m_fs_writeChunk(tid, 0, b64(data[:3000]))
        self.assertEqual(self.s.m_fs_writeChunk(tid, 3000, b64(data[3000:]))["received"], 5000)
        r = self.s.m_fs_commitWrite(tid, sha256=hashlib.sha256(data).hexdigest(), size=5000)
        self.assertTrue(r["atomic"])
        self.assertEqual(open(self.p, "rb").read(), data)
        self.assertEqual(self.tmps(), [])

    def test_gap_and_overlap_rejected_and_cleaned(self):
        self.put()
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"abc"))
        self.assertEqual(self.code(self.s.m_fs_writeChunk, tid, 5, b64(b"x")), -32013)
        self.assertEqual(self.tmps(), [])
        self.assertEqual(open(self.p, "rb").read(), b"old")
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"abc"))
        self.assertEqual(self.code(self.s.m_fs_writeChunk, tid, 1, b64(b"x")), -32013)

    def test_hash_and_size_mismatch_leave_target_intact(self):
        self.put()
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"abc"))
        self.assertEqual(self.code(self.s.m_fs_commitWrite, tid, sha256="0" * 64), -32013)
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"abc"))
        self.assertEqual(self.code(self.s.m_fs_commitWrite, tid, size=99), -32013)
        self.assertEqual(open(self.p, "rb").read(), b"old")
        self.assertEqual(self.tmps(), [])

    def test_conflict_detected_at_commit(self):
        self.put()
        ver = self.s.m_fs_readChunk(self.p, 0, 10)["version"]
        tid = self.s.m_fs_beginWrite(self.p, expected=ver)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"mine"))
        self.put(b"someone else was here")   # external change mid-transfer
        self.assertEqual(self.code(self.s.m_fs_commitWrite, tid), -32010)
        self.assertEqual(open(self.p, "rb").read(), b"someone else was here")
        self.assertEqual(self.tmps(), [])

    def test_conflict_detected_at_begin(self):
        self.put()
        ver = self.s.m_fs_readChunk(self.p, 0, 10)["version"]
        self.put(b"changed")
        self.assertEqual(self.code(self.s.m_fs_beginWrite, self.p, expected=ver), -32010)
        self.assertEqual(self.tmps(), [])

    def test_too_large(self):
        self.put()
        self.assertEqual(self.code(self.s.m_fs_beginWrite, self.p, size=self.m.MAX_TRANSFER + 1), -32011)
        tid = self.s.m_fs_beginWrite(self.p, size=2)["tid"]
        self.assertEqual(self.code(self.s.m_fs_writeChunk, tid, 0, b64(b"abc")), -32011)
        self.assertEqual(self.tmps(), [])

    def test_too_many_concurrent(self):
        self.put()
        for _ in range(self.m.MAX_TRANSFERS):
            self.s.m_fs_beginWrite(self.p)
        self.assertEqual(self.code(self.s.m_fs_beginWrite, self.p), -32011)
        self.s._abort_all_transfers()
        self.assertEqual(self.tmps(), [])

    def test_abort_idempotent(self):
        self.put()
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.assertEqual(self.s.m_fs_abortWrite(tid), {})
        self.assertEqual(self.s.m_fs_abortWrite(tid), {})
        self.assertEqual(self.s.m_fs_abortWrite("nope"), {})
        self.assertEqual(self.tmps(), [])
        self.assertEqual(self.code(self.s.m_fs_writeChunk, tid, 0, b64(b"x")), -32013)

    def test_idle_transfer_swept(self):
        self.put()
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.xfers[tid]["last"] -= self.m.TRANSFER_IDLE + 1
        self.s._sweep_transfers()
        self.assertEqual(self.tmps(), [])
        self.assertNotIn(tid, self.s.xfers)

    def test_session_end_cleans_up(self):
        self.put()
        req = helpers.frame({"jsonrpc": "2.0", "id": 1, "method": "fs/beginWrite",
                             "params": {"path": self.p}})
        helpers.Driver().run_raw(req)       # session ends right after the request
        self.assertEqual(self.tmps(), [])

    def test_new_file_and_mode(self):
        tid = self.s.m_fs_beginWrite(self.p, mode=0o600)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"hi"))
        self.s.m_fs_commitWrite(tid)
        self.assertEqual(oct(os.stat(self.p).st_mode & 0o777), "0o600")

    def test_existing_mode_preserved(self):
        self.put()
        os.chmod(self.p, 0o640)
        tid = self.s.m_fs_beginWrite(self.p)["tid"]
        self.s.m_fs_writeChunk(tid, 0, b64(b"new"))
        self.s.m_fs_commitWrite(tid)
        self.assertEqual(oct(os.stat(self.p).st_mode & 0o777), "0o640")


if __name__ == "__main__":
    unittest.main()
