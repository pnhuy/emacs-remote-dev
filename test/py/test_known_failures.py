"""Known-failure tests for confirmed agent/relay defects (T028, FR-006).

Each test names its defect (the expectedFailure marks were removed when the fixes landed).  When the fix lands
the test starts passing; unittest then reports an UNEXPECTED SUCCESS, which is
the signal to delete the decorator (see test/KNOWN-FAILURES.md).
"""
import base64
import os
import socket
import struct
import subprocess
import sys
import tempfile
import unittest

import helpers
from helpers import frame
from test_relay import FakeEmacs, frame as rframe


class D03UnsafeWrite(unittest.TestCase):
    def test_d03_write_atomic_detects_concurrent_change(self):
        """D-03: no atomic, version-checked write exists; fs/write truncates in place."""
        d = helpers.Driver()
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, "f")
            with open(p, "w") as f:
                f.write("v1")
            r = d.result("fs/read", path=p)
            with open(p, "w") as f:       # concurrent external edit
                f.write("external-edit")
            data = base64.b64encode(b"mine").decode()
            res, err = d.call("fs/writeAtomic", path=p, data=data,
                              expected=r.get("version"))
            self.assertIsNotNone(err)
            self.assertEqual(err["code"], -32010)           # CONFLICT
            with open(p) as f:
                self.assertEqual(f.read(), "external-edit")  # not clobbered


class D05Framing(unittest.TestCase):
    def test_d05_bad_content_length_does_not_kill_session(self):
        """D-05: non-numeric Content-Length raises out of serve()."""
        d = helpers.Driver()
        good = frame({"jsonrpc": "2.0", "id": 1, "method": "hello", "params": None})
        out = d.run_raw(b"Content-Length: abc\r\n\r\n" + good)
        self.assertTrue(any(m.get("id") == 1 for m in out))

    def test_d05_invalid_json_body_returns_parse_error(self):
        """D-05: invalid JSON body raises JSONDecodeError out of serve()."""
        d = helpers.Driver()
        body = b"{not json"
        good = frame({"jsonrpc": "2.0", "id": 2, "method": "hello", "params": None})
        out = d.run_raw(b"Content-Length: %d\r\n\r\n" % len(body) + body + good)
        self.assertTrue(any(m.get("error", {}).get("code") == -32700 for m in out))
        self.assertTrue(any(m.get("id") == 2 for m in out))

    def test_d05_oversized_header_rejected(self):
        """D-05: no limit on declared body size."""
        d = helpers.Driver()
        out = d.run_raw(b"Content-Length: 99999999999\r\n\r\n")
        self.assertTrue(any("error" in m for m in out))


class D09RelayFrames(unittest.TestCase):
    def setUp(self):
        self.e = FakeEmacs().launch()
        self.addCleanup(self.e.close)
        self.e.read_frame()

    def test_d09_non_numeric_exit_payload_exits_255(self):
        """D-09: int(payload) on X raises an uncaught exception."""
        self.e.conn.sendall(rframe(b"X", b"not-a-number"))
        self.assertEqual(self.e.p.wait(timeout=10), 255)
        self.assertNotIn(b"Traceback", self.e.p.stderr.read())

    def test_d09_oversized_length_rejected(self):
        """D-09: unbounded LEN is buffered forever."""
        self.e.conn.sendall(b"O" + struct.pack(">I", 0xFFFFFFFF) + b"x")
        self.assertEqual(self.e.p.wait(timeout=5), 255)

    def test_d09_unknown_type_is_a_protocol_error(self):
        """D-09: unknown frame types are ignored silently."""
        self.e.conn.sendall(rframe(b"Z", b"?"))
        self.assertEqual(self.e.p.wait(timeout=5), 255)


class D11TcpGate(unittest.TestCase):
    def test_d11_non_loopback_listen_requires_opt_in(self):
        """D-11: --listen on a non-loopback address starts with no opt-in."""
        s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
        p = subprocess.Popen([sys.executable, helpers.SERVER_PATH, "--listen",
                              "0.0.0.0:%d" % port, "--token", "t"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            try:
                rc = p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                rc = None
            self.assertIsNotNone(rc, "agent kept listening on 0.0.0.0 without opt-in")
            self.assertNotEqual(rc, 0)
        finally:
            if p.poll() is None:
                p.kill()
            p.wait()
            p.stdout.close(); p.stderr.close()


if __name__ == "__main__":
    unittest.main()
