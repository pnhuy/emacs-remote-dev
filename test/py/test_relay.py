"""Relay frame tests driven against rdev-relay.py with a fake Emacs socket (T025)."""
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

import helpers


def frame(t, payload=b""):
    return t + struct.pack(">I", len(payload)) + payload


class FakeEmacs:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="rdev-relay-")
        self.path = os.path.join(self.dir, "s.sock")
        self.srv = socket.socket(socket.AF_UNIX)
        self.srv.bind(self.path)
        self.srv.listen(1)
        self.srv.settimeout(10)
        self.buf = b""

    def launch(self, chan="7"):
        self.p = subprocess.Popen([sys.executable, "-u", helpers.RELAY_PATH, self.path, chan],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
        self.conn, _ = self.srv.accept()
        self.conn.settimeout(10)
        return self

    def read_frame(self):
        while True:
            if len(self.buf) >= 5:
                n = struct.unpack(">I", self.buf[1:5])[0]
                if len(self.buf) >= 5 + n:
                    t, payload = self.buf[:1], self.buf[5:5 + n]
                    self.buf = self.buf[5 + n:]
                    return t, payload
            self.buf += self.conn.recv(65536)

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass
        self.p.wait()
        self.srv.close()


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.e = FakeEmacs().launch()
        self.addCleanup(self.e.close)

    def test_hello_frame(self):
        t, payload = self.e.read_frame()
        self.assertEqual(t, b"H")
        chan, rows, cols = payload.decode().split()
        self.assertEqual(chan, "7")

    def test_stdout_stderr_and_exit_code(self):
        self.e.read_frame()
        self.e.conn.sendall(frame(b"O", b"hello") + frame(b"E", b"oops") + frame(b"X", b"3"))
        self.assertEqual(self.e.p.wait(timeout=10), 3)
        self.assertEqual(self.e.p.stdout.read(), b"hello")
        self.assertEqual(self.e.p.stderr.read(), b"oops")

    def test_partial_frames_reassembled(self):
        self.e.read_frame()
        data = frame(b"O", b"split-me") + frame(b"X", b"0")
        for i in range(0, len(data), 3):
            self.e.conn.sendall(data[i:i + 3])
            time.sleep(0.01)
        self.assertEqual(self.e.p.wait(timeout=10), 0)
        self.assertEqual(self.e.p.stdout.read(), b"split-me")

    def test_stdin_forwarded_then_eof(self):
        self.e.read_frame()
        self.e.p.stdin.write(b"typed")
        self.e.p.stdin.flush()
        t, payload = self.e.read_frame()
        self.assertEqual((t, payload), (b"I", b"typed"))
        self.e.p.stdin.close()
        t, _ = self.e.read_frame()
        self.assertEqual(t, b"C")

    def test_signal_forwarded(self):
        self.e.read_frame()
        time.sleep(0.2)
        self.e.p.send_signal(signal.SIGUSR1)
        t, payload = self.e.read_frame()
        self.assertEqual(t, b"S")
        self.assertEqual(int(payload), int(signal.SIGUSR1))

    def test_socket_close_exits_255(self):
        self.e.read_frame()
        self.e.conn.close()
        self.assertEqual(self.e.p.wait(timeout=10), 255)


if __name__ == "__main__":
    unittest.main()
