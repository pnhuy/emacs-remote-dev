"""T057: session/shutdown and process ownership (FR-021)."""
import os
import tempfile
import time
import unittest

import helpers
import test_methods_proc as tmp


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # zombies count as dead
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().split(")")[-1].split()[0] != "Z"
    except OSError:
        return True


def wait_dead(pid, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return not alive(pid)


class Shutdown(unittest.TestCase):
    def setUp(self):
        self.h = tmp.StreamingProc()
        self.h.start()
        self.pidf = tempfile.NamedTemporaryFile(delete=False).name
        self.addCleanup(os.unlink, self.pidf)

    def tearDown(self):
        self.h.tearDown()

    def spawn(self, script, **kw):
        self.h.send("proc/spawn", id="x", cmd=["sh", "-c", script], **kw)
        for _ in range(100):
            if os.path.getsize(self.pidf):
                break
            time.sleep(0.05)
        return int(open(self.pidf).read())

    def response(self, rid, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            m = self.h.read_one()
            if m.get("id") == rid:
                return m
        self.fail("no response")

    def test_hello_advertises(self):
        d = helpers.Driver()
        caps = d.result("hello")["capabilities"]
        self.assertIn("proc.ownership", caps)
        self.assertIn("session.shutdown", caps)

    def test_shutdown_terminates_group_with_sighup(self):
        pid = self.spawn("echo $$ > %s; sleep 60 & wait" % self.pidf)
        rid = self.h.send("session/shutdown")
        m = self.response(rid)
        self.assertEqual(m["result"]["terminated"], 1)
        self.assertTrue(wait_dead(pid, 3))

    def test_sighup_ignored_gets_sigkill_after_grace(self):
        pid = self.spawn("trap '' HUP; echo $$ > %s; while :; do sleep 1; done"
                         % self.pidf)
        t0 = time.time()
        rid = self.h.send("session/shutdown", grace_ms=500)
        self.response(rid)
        self.assertTrue(wait_dead(pid, 3))
        self.assertGreaterEqual(time.time() - t0, 0.4)

    def test_unowned_process_survives_shutdown(self):
        pid = self.spawn("echo $$ > %s; sleep 30" % self.pidf, owned=False)
        rid = self.h.send("session/shutdown", grace_ms=100)
        self.assertEqual(self.response(rid)["result"]["terminated"], 0)
        time.sleep(0.5)
        self.assertTrue(alive(pid))
        os.kill(pid, 9)

    def test_disconnect_terminates_owned(self):
        pid = self.spawn("trap '' HUP; echo $$ > %s; while :; do sleep 1; done"
                         % self.pidf, grace_ms=300)
        self.h.inp.close()  # EOF => session ends
        self.assertTrue(wait_dead(pid, 5))

    def test_invalid_grace_rejected(self):
        rid = self.h.send("session/shutdown", grace_ms=-1)
        self.assertEqual(self.response(rid)["error"]["code"], -32602)
        rid = self.h.send("session/shutdown", grace_ms="soon")
        self.assertEqual(self.response(rid)["error"]["code"], -32602)


if __name__ == "__main__":
    unittest.main()
