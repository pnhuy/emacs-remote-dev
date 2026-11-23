"""T065: the relay presents a per-session token and checks the server's uid."""
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import unittest

import helpers
from test_relay import FakeEmacs


def load_relay():
    spec = importlib.util.spec_from_file_location("rdev_relay_mod", helpers.RELAY_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TokenTests(unittest.TestCase):
    def launch(self, env):
        e = FakeEmacs()
        self.addCleanup(e.close)
        e.p = subprocess.Popen([sys.executable, "-u", helpers.RELAY_PATH, e.path, "9"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env)
        e.conn, _ = e.srv.accept()
        e.conn.settimeout(10)
        return e

    def test_token_from_environment_is_in_hello(self):
        env = dict(os.environ, RDEV_RELAY_TOKEN="s3cret0123")
        e = self.launch(env)
        t, payload = e.read_frame()
        self.assertEqual(t, b"H")
        self.assertEqual(payload.decode().split(), ["9", "0", "0", "s3cret0123"])

    def test_no_token_means_three_field_hello(self):
        env = {k: v for k, v in os.environ.items() if k != "RDEV_RELAY_TOKEN"}
        e = self.launch(env)
        _, payload = e.read_frame()
        self.assertEqual(len(payload.decode().split()), 3)

    def test_peer_uid_of_own_socket_is_own_uid(self):
        mod = load_relay()
        a, b = socket.socketpair()
        try:
            uid = mod.peer_uid(a)
            # None is allowed where the platform cannot answer; a value must be ours.
            self.assertIn(uid, (None, os.getuid()))
        finally:
            a.close()
            b.close()

    def test_peer_uid_reports_none_on_failure(self):
        mod = load_relay()
        s = socket.socket(socket.AF_INET)
        s.close()
        self.assertIsNone(mod.peer_uid(s))

    def test_main_refuses_server_of_other_uid(self):
        """Simulate a foreign owner by patching peer_uid; the relay must exit 255."""
        mod = load_relay()
        e = FakeEmacs()
        e.p = subprocess.Popen(["true"])
        self.addCleanup(e.close)
        mod.peer_uid = lambda _s: os.getuid() + 1
        argv, sys.argv = sys.argv, ["relay", e.path, "3"]
        try:
            with self.assertRaises(SystemExit) as cm:
                mod.main()
            self.assertEqual(cm.exception.code, 255)
        finally:
            sys.argv = argv


if __name__ == "__main__":
    unittest.main()
