"""T069: proc/exit is sent only after all proc/out; truncated flag (T075)."""
import json
import os
import threading
import time
import unittest

import helpers
import test_methods_proc as tmp


class Drain(unittest.TestCase):
    """Composes the StreamingProc driver (avoids re-running its tests)."""

    def setUp(self):
        self.h = tmp.StreamingProc()

    def tearDown(self):
        self.h.tearDown()

    def start(self):
        return self.h.start()

    def send(self, *a, **k):
        return self.h.send(*a, **k)

    @property
    def msgs(self):
        return self.h.msgs

    def wait_exit(self, timeout=10):
        return self.h.wait_exit(timeout)

    def test_all_output_precedes_exit(self):
        self.start()
        self.send("proc/spawn", id="d1", cmd=[
            "sh", "-c", "head -c 3000000 /dev/zero | tr '\\0' x; exit 3"])
        ex, data = self.wait_exit(30)
        self.assertEqual(len(data), 3000000)
        self.assertEqual(ex["code"], 3)
        self.assertNotIn("truncated", ex)
        # nothing may arrive after proc/exit
        idx = [i for i, m in enumerate(self.msgs) if m.get("method") == "proc/exit"]
        self.assertEqual(idx, [len(self.msgs) - 1])

    def test_background_holder_does_not_hang_exit(self):
        # A daemonised grandchild keeps the pipe open after the child exits.
        self.start()
        t0 = time.time()
        self.send("proc/spawn", id="d2", cmd=[
            "sh", "-c", "echo hi; (sleep 30 &) ; exit 0"])
        ex, data = self.wait_exit(15)
        self.assertEqual(data, b"hi\n")
        self.assertLess(time.time() - t0, 8)
        self.assertNotIn("truncated", ex)
        os.system("pkill -f 'sleep 30' >/dev/null 2>&1")

    def test_group_killed_then_exit(self):
        self.start()
        self.send("proc/spawn", id="d3", cmd=["sh", "-c", "echo a; sleep 30"])
        time.sleep(0.3)
        self.send("proc/signal", id="d3", sig=15)
        ex, data = self.wait_exit(15)
        self.assertEqual(ex["signal"], 15)
        self.assertEqual(data, b"a\n")


if __name__ == "__main__":
    unittest.main()
