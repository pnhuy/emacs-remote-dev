"""T060 (agent half): TCP token handling (FR-034)."""
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

import helpers
from test_tcp_auth import rpc


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


class TcpSecurity(unittest.TestCase):
    def start(self, port, *extra, env=None, home=None):
        e = dict(os.environ)
        e.pop("RDEV_TOKEN", None)
        e.update(env or {})
        if home:
            e["HOME"] = home
        p = subprocess.Popen([sys.executable, helpers.SERVER_PATH, "--listen",
                              "127.0.0.1:%d" % port] + list(extra), env=e,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: (p.kill(), p.wait(), p.stdout.close(), p.stderr.close()))
        return p

    def conn(self, port):
        for _ in range(50):
            try:
                c = socket.create_connection(("127.0.0.1", port), timeout=5)
                self.addCleanup(c.close)
                return c.makefile("rwb")
            except OSError:
                time.sleep(0.1)
        self.fail("agent not listening")

    def authed(self, port, token):
        f = self.conn(port)
        r = rpc(f, 1, "auth", {"token": token})
        return bool(r and r.get("result"))

    def test_env_token(self):
        port = free_port()
        self.start(port, env={"RDEV_TOKEN": "envsecret"})
        self.assertTrue(self.authed(port, "envsecret"))
        self.assertFalse(self.authed(port, "wrong"))

    def test_token_file(self):
        port = free_port()
        d = tempfile.mkdtemp()
        tf = os.path.join(d, "t")
        with open(tf, "w") as f:
            f.write("filesecret\n")
        self.start(port, "--token-file", tf)
        self.assertTrue(self.authed(port, "filesecret"))

    def test_argv_token_warns_and_is_not_echoed(self):
        port = free_port()
        p = self.start(port, "--token", "argvsecret")
        self.assertTrue(self.authed(port, "argvsecret"))
        p.kill()
        out, err = p.stdout.read(), p.stderr.read()
        self.assertIn(b"--token", err)
        self.assertIn(b"WARNING", err)
        self.assertNotIn(b"argvsecret", out + err)

    def test_generated_token_is_strong_0600_and_not_logged(self):
        port = free_port()
        home = tempfile.mkdtemp()
        p = self.start(port, home=home)
        path = os.path.join(home, ".cache", "rdev", "token-%d" % port)
        for _ in range(50):
            if os.path.exists(path):
                break
            time.sleep(0.1)
        self.assertTrue(os.path.exists(path))
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        token = open(path).read().strip()
        self.assertGreaterEqual(len(token), 43)  # token_urlsafe(32) = 256 bits
        self.assertTrue(self.authed(port, token))
        p.kill()
        out, err = p.stdout.read(), p.stderr.read()
        self.assertNotIn(token.encode(), out + err)
        self.assertIn(path.encode(), err)

    def test_failed_token_never_logged(self):
        port = free_port()
        p = self.start(port, env={"RDEV_TOKEN": "realsecret"})
        self.assertFalse(self.authed(port, "guess-xyz"))
        p.kill()
        out, err = p.stdout.read(), p.stderr.read()
        for s in (b"realsecret", b"guess-xyz"):
            self.assertNotIn(s, out + err)

    def test_non_loopback_refused_without_flag(self):
        p = subprocess.run([sys.executable, helpers.SERVER_PATH, "--listen", "0.0.0.0:%d" % free_port(),
                            "--token", "x"], capture_output=True, timeout=10)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b"non-loopback", p.stderr)


if __name__ == "__main__":
    unittest.main()
