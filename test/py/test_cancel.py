"""T071: $/cancel (R8)."""
import io
import json
import os
import tempfile
import threading
import time
import unittest

import helpers
import test_methods_proc as tmp


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class Cancel(unittest.TestCase):
    def setUp(self):
        self.h = tmp.StreamingProc()
        self.h.start()

    def tearDown(self):
        self.h.tearDown()

    def notify(self, method, **params):
        body = json.dumps({"jsonrpc": "2.0", "method": method,
                           "params": params}).encode()
        self.h.inp.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.h.inp.flush()

    def response(self, rid, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = self.h.read_one()
            if m.get("id") == rid:
                return m
        self.fail("no response")

    def test_cancel_exec_run_kills_group(self):
        pidf = tempfile.NamedTemporaryFile(delete=False).name
        self.addCleanup(os.unlink, pidf)
        rid = self.h.send("exec/run", cmd=[
            "sh", "-c", "echo $$ > %s; sleep 30 & wait" % pidf])
        for _ in range(50):
            if os.path.getsize(pidf):
                break
            time.sleep(0.1)
        pid = int(open(pidf).read())
        self.notify("$/cancel", id=rid)
        t0 = time.time()
        m = self.response(rid)
        self.assertEqual(m["error"]["code"], -32800)
        self.assertLess(time.time() - t0, 3)
        time.sleep(0.3)
        self.assertFalse(alive(pid))

    def test_unknown_id_ignored_and_session_survives(self):
        self.notify("$/cancel", id=99999)
        self.notify("$/cancel")                 # malformed: no id
        rid = self.h.send("exec/run", cmd=["echo", "ok"])
        self.assertIn("result", self.response(rid))

    def test_cancel_after_completion_ignored(self):
        rid = self.h.send("exec/run", cmd=["true"])
        self.assertIn("result", self.response(rid))
        self.notify("$/cancel", id=rid)
        rid2 = self.h.send("exec/run", cmd=["true"])
        self.assertIn("result", self.response(rid2))

    def test_queued_request_cancelled_before_start(self):
        m = helpers.load_module()
        cr, sw = os.pipe()
        sr, cw = os.pipe()
        sess = m.Session(os.fdopen(cr, "rb"), os.fdopen(cw, "wb"), workers=1)
        threading.Thread(target=sess.serve, daemon=True).start()
        inp, out = os.fdopen(sw, "wb"), os.fdopen(sr, "rb")

        def send(obj):
            b = json.dumps(obj).encode()
            inp.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
            inp.flush()

        def read():
            n = None
            while True:
                line = out.readline()
                if line in (b"\r\n", b"\n"):
                    break
                if line.lower().startswith(b"content-length"):
                    n = int(line.split(b":")[1])
            return json.loads(out.read(n))

        send({"jsonrpc": "2.0", "id": 1, "method": "exec/run",
              "params": {"cmd": ["sleep", "1"]}})
        send({"jsonrpc": "2.0", "id": 2, "method": "exec/run",
              "params": {"cmd": ["echo", "never"]}})
        send({"jsonrpc": "2.0", "method": "$/cancel", "params": {"id": 2}})
        got = {}
        while len(got) < 2:
            r = read()
            got[r["id"]] = r
        self.assertIn("result", got[1])
        self.assertEqual(got[2]["error"]["code"], -32800)
        inp.close()


if __name__ == "__main__":
    unittest.main()
