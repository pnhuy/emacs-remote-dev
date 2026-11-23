"""Characterization tests for exec/run, proc/*, project/files (T024)."""
import base64
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import helpers


def b64(b):
    return base64.b64encode(b).decode()


def unb64(s):
    return base64.b64decode(s)


class ExecRun(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()

    def test_stdout_stderr_split(self):
        r = self.d.result("exec/run", cmd=["sh", "-c", "echo out; echo err >&2"])
        self.assertEqual(unb64(r["stdout"]), b"out\n")
        self.assertEqual(unb64(r["stderr"]), b"err\n")
        self.assertEqual(r["code"], 0)

    def test_merge_stderr(self):
        r = self.d.result("exec/run", cmd=["sh", "-c", "echo out; echo err >&2"],
                          mergeStderr=True)
        self.assertEqual(sorted(unb64(r["stdout"]).split()), [b"err", b"out"])
        self.assertEqual(unb64(r["stderr"]), b"")

    def test_exit_code_stdin_cwd_env(self):
        r = self.d.result("exec/run", cmd=["sh", "-c", "cat; echo $FOO; pwd; exit 3"],
                          stdin=b64(b"in\n"), cwd="/tmp", env={"FOO": "bar"})
        self.assertEqual(r["code"], 3)
        lines = unb64(r["stdout"]).decode().split("\n")
        self.assertEqual(lines[:2], ["in", "bar"])
        self.assertTrue(lines[2].endswith("tmp"))

    def test_missing_program(self):
        _, err = self.d.call("exec/run", cmd=["/no/such/prog"])
        self.assertEqual(err["code"], -32003)
        self.assertEqual(err["data"]["errno"], "ENOENT")

    def test_signalled_exit_code_current_behavior(self):
        # Baseline: exec/run reports 128 - code for signalled children (D-07).
        r = self.d.result("exec/run", cmd=["sh", "-c", "kill -TERM $$"])
        self.assertEqual(r["signal"], 15)
        self.assertEqual(r["code"], 128 - (-15))  # == 143 only by accident of arithmetic

    def test_timeout(self):
        _, err = self.d.call("exec/run", cmd=["sleep", "5"], timeout=0.2)
        self.assertIsNotNone(err)


class StreamingProc(unittest.TestCase):
    """Drive a real Session over OS pipes so notifications interleave."""

    def start(self):
        m = helpers.load_module()
        self.cr, self.sw = os.pipe()   # test -> session
        self.sr, self.cw = os.pipe()   # session -> test
        self.sess = m.Session(os.fdopen(self.cr, "rb"), os.fdopen(self.cw, "wb"))
        self.t = threading.Thread(target=self.sess.serve, daemon=True)
        self.t.start()
        self.out = os.fdopen(self.sr, "rb")
        self.inp = os.fdopen(self.sw, "wb")
        self.msgs = []
        self._id = 0

    def tearDown(self):
        try:
            self.inp.close()
        except Exception:
            pass

    def send(self, method, **params):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method,
                           "params": params}).encode()
        self.inp.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.inp.flush()
        return self._id

    def read_one(self):
        n = None
        while True:
            line = self.out.readline()
            if line in (b"\r\n", b"\n"):
                break
            if line.lower().startswith(b"content-length"):
                n = int(line.split(b":")[1])
        return json.loads(self.out.read(n))

    def wait_exit(self, timeout=10):
        deadline = time.time() + timeout
        data = b""
        while time.time() < deadline:
            m = self.read_one()
            self.msgs.append(m)
            if m.get("method") == "proc/out":
                data += unb64(m["params"]["data"])
            if m.get("method") == "proc/exit":
                return m["params"], data
        self.fail("no proc/exit")

    def test_pipe_echo_and_exit(self):
        self.start()
        self.send("proc/spawn", id="p1", cmd=["sh", "-c", "echo hi; exit 4"], pty=False)
        ex, data = self.wait_exit()
        self.assertEqual(ex["code"], 4)
        self.assertEqual(data, b"hi\n")

    def test_stdin_eof(self):
        self.start()
        self.send("proc/spawn", id="p2", cmd=["cat"])
        self.send("proc/write", id="p2", data=b64(b"abc"))
        self.send("proc/eof", id="p2")
        ex, data = self.wait_exit()
        self.assertEqual(data, b"abc")
        self.assertEqual(ex["code"], 0)

    def test_pty_echo_off_and_resize(self):
        self.start()
        self.send("proc/spawn", id="p3", cmd=["sh", "-c", "stty size; exit 0"],
                  pty=True, rows=30, cols=100)
        ex, data = self.wait_exit()
        self.assertIn(b"30 100", data)

    def test_signal_terminates_with_128_plus_sig(self):
        self.start()
        self.send("proc/spawn", id="p4", cmd=["sleep", "30"])
        time.sleep(0.3)
        self.send("proc/signal", id="p4", sig=signal.SIGTERM)
        ex, _ = self.wait_exit()
        self.assertEqual(ex["signal"], 15)
        self.assertEqual(ex["code"], 128 + 15)

    def test_unknown_proc_error(self):
        self.start()
        self.send("proc/write", id="nope", data=b64(b"x"))
        m = self.read_one()
        self.assertEqual(m["error"]["code"], -32004)

    def test_stderr_separate_stream(self):
        self.start()
        self.send("proc/spawn", id="p5", cmd=["sh", "-c", "echo e >&2"], mergeStderr=False)
        self.wait_exit()
        streams = {m["params"]["stream"] for m in self.msgs if m.get("method") == "proc/out"}
        self.assertEqual(streams, {"err"})


class ProjectFiles(unittest.TestCase):
    def test_git_repo_and_plain_dir(self):
        d = helpers.Driver()
        tmp = tempfile.mkdtemp()
        os.mkdir(os.path.join(tmp, "sub"))
        for f in ("a.txt", "sub/b.txt", ".hidden"):
            open(os.path.join(tmp, f), "w").close()
        files = set(d.result("project/files", root=tmp))
        self.assertIn("a.txt", files)
        self.assertIn(os.path.join("sub", "b.txt"), files)
        subprocess.run(["git", "init", "-q"], cwd=tmp, check=True)
        open(os.path.join(tmp, ".gitignore"), "w").write("a.txt\n")
        files = set(d.result("project/files", root=tmp))
        self.assertNotIn("a.txt", files)
        self.assertIn("sub/b.txt", files)


if __name__ == "__main__":
    unittest.main()
