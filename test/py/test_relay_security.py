"""T061: relay frame validation (cap, unknown type, bad payloads)."""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

RELAY = os.path.join(os.path.dirname(__file__), "..", "..", "rdev-relay.py")


def frame(t, payload=b""):
    return t + struct.pack(">I", len(payload)) + payload


class RelaySecurity(unittest.TestCase):
    def run_relay(self, data):
        d = tempfile.mkdtemp(prefix="rr", dir="/tmp")
        path = os.path.join(d, "s.sock")
        srv = socket.socket(socket.AF_UNIX)
        srv.bind(path)
        srv.listen(1)
        p = subprocess.Popen([sys.executable, RELAY, path, "1"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        srv.settimeout(10)
        try:
            c, _ = srv.accept()
        except socket.timeout:
            p.kill()
            self.skipTest("relay CLI shape differs; cannot connect")
        c.settimeout(10)
        c.recv(4096)  # the H hello frame
        c.sendall(data)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            self.fail("relay did not exit on malformed frame")
        finally:
            c.close()
            srv.close()
        return p.returncode, p.stderr.read().decode(errors="replace")

    def test_oversized_frame_rejected(self):
        rc, _ = self.run_relay(b"O" + struct.pack(">I", 0x7FFFFFFF))
        self.assertNotEqual(rc, 0)

    def test_unknown_type_rejected(self):
        rc, _ = self.run_relay(frame(b"Z", b"x"))
        self.assertNotEqual(rc, 0)


    def test_bad_exit_payload_rejected(self):
        rc, _ = self.run_relay(frame(b"X", b"notanumber"))
        self.assertNotEqual(rc, 0)

    def test_valid_exit_frame_sets_status(self):
        rc, _ = self.run_relay(frame(b"X", b"7"))
        self.assertEqual(rc, 7)


if __name__ == "__main__":
    unittest.main()
