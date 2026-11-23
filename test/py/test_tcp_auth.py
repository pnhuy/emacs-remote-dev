"""T060-ish: TCP agent gate, auth-failure limit, loopback default."""
import json
import socket
import subprocess
import sys
import time
import unittest

import helpers


def rpc(f, i, method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}).encode()
    f.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    f.flush()
    n = None
    while True:
        line = f.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        if line.lower().startswith(b"content-length"):
            n = int(line.split(b":")[1])
    return json.loads(f.read(n))


class TcpAgent(unittest.TestCase):
    def start(self, listen, *extra):
        p = subprocess.Popen([sys.executable, helpers.SERVER_PATH, "--listen", listen,
                              "--token", "secret"] + list(extra),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: (p.kill(), p.wait(), p.stdout.close(), p.stderr.close()))
        return p

    def port(self):
        s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
        return p

    def connect(self, port):
        for _ in range(50):
            try:
                c = socket.create_connection(("127.0.0.1", port), timeout=5)
                self.addCleanup(c.close)
                return c.makefile("rwb")
            except OSError:
                time.sleep(0.1)
        self.fail("agent not listening")

    def test_auth_required_and_failure_limit(self):
        port = self.port(); self.start("127.0.0.1:%d" % port)
        f = self.connect(port)
        r = rpc(f, 1, "fs/stat", {"path": "/"})
        self.assertEqual(r["error"]["code"], -32002)
        for i in range(4):
            self.assertEqual(rpc(f, 10 + i, "auth", {"token": "bad"})["error"]["code"], -32002)
        rpc(f, 20, "auth", {"token": "bad"})
        self.assertIsNone(rpc(f, 21, "hello"), "connection must close after repeated failures")

    def test_non_ascii_token_counts_as_failure(self):
        port = self.port(); self.start("127.0.0.1:%d" % port)
        f = self.connect(port)
        r = rpc(f, 1, "auth", {"token": "caf\u00e9"})
        self.assertEqual(r["error"]["code"], -32002)

    def test_short_token_warns_without_leaking_it(self):
        port = self.port(); p = self.start("127.0.0.1:%d" % port, "--token", "short")
        f = self.connect(port)
        rpc(f, 1, "auth", {"token": "short"})
        p.kill(); err = p.stderr.read().decode()
        self.assertIn("weak", err.lower())
        self.assertNotIn("short\n", err.replace("weak token", ""))

    def test_good_token_works(self):
        port = self.port(); self.start("127.0.0.1:%d" % port)
        f = self.connect(port)
        self.assertTrue(rpc(f, 1, "auth", {"token": "secret"})["result"])
        self.assertIn("protocol", rpc(f, 2, "hello")["result"])

    def test_token_not_in_stderr(self):
        port = self.port(); p = self.start("127.0.0.1:%d" % port)
        f = self.connect(port)
        rpc(f, 1, "auth", {"token": "secret"}); rpc(f, 2, "auth", {"token": "wrongtoken"})
        p.kill(); err = p.stderr.read()
        self.assertNotIn(b"wrongtoken", err)
        self.assertNotIn(b"secret", err.replace(b"--token", b""))

    def test_non_loopback_refused_then_allowed(self):
        port = self.port()
        p = subprocess.run([sys.executable, helpers.SERVER_PATH, "--listen", "0.0.0.0:%d" % port,
                            "--token", "t"], capture_output=True, timeout=10)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b"non-loopback", p.stderr)
        self.start("0.0.0.0:%d" % port, "--allow-non-loopback")
        self.connect(port)


if __name__ == "__main__":
    unittest.main()
