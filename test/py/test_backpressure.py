"""T070: bounded per-process output queue gives backpressure (R7);
exec/run output cap (T076)."""
import os
import sys
import tempfile
import time
import unittest

import helpers
import test_methods_proc as tmp

PRODUCER = r'''
import os, sys
n = 0
blk = b"x" * 65536
while True:
    os.write(1, blk)
    n += 1
    open(sys.argv[1], "w").write(str(n))
'''


class Backpressure(unittest.TestCase):
    def setUp(self):
        self.h = tmp.StreamingProc()

    def tearDown(self):
        self.h.tearDown()

    def test_unread_output_stalls_child(self):
        h = self.h
        h.start()
        counter = tempfile.NamedTemporaryFile(delete=False).name
        self.addCleanup(os.unlink, counter)
        h.send("proc/spawn", id="b1", cmd=[sys.executable, "-c", PRODUCER, counter])
        h.read_one()  # spawn response
        time.sleep(2.0)  # client reads nothing
        p = h.sess.procs["b1"]
        self.assertTrue(p.q.full(), "queue should be full")
        written = int(open(counter).read() or 0) * 65536
        # queue (1 MiB) + kernel pipes + in-flight chunks; far below unbounded
        self.assertLess(written, 8 * 1024 * 1024, written)
        t0 = int(open(counter).read())
        time.sleep(0.5)
        self.assertEqual(t0, int(open(counter).read()), "child must be stalled")
        # Draining resumes the child, then we terminate it.
        got = 0
        deadline = time.time() + 10
        while got < 4 * 1024 * 1024 and time.time() < deadline:
            m = h.read_one()
            if m.get("method") == "proc/out":
                got += len(tmp.unb64(m["params"]["data"]))
        self.assertGreaterEqual(got, 4 * 1024 * 1024)
        h.send("proc/signal", id="b1", sig=9)


class ExecCap(unittest.TestCase):
    def test_exec_run_output_cap(self):
        m = helpers.load_module()
        m.EXEC_MAX_OUTPUT = 100000
        d = helpers.Driver(m)
        _, err = d.call("exec/run", cmd=[sys.executable, "-c",
                        "import sys\nwhile True: sys.stdout.write('y'*10000)"])
        self.assertEqual(err["code"], -32011)

    def test_exec_run_under_cap_ok(self):
        d = helpers.Driver()
        r = d.result("exec/run", cmd=["sh", "-c", "head -c 500000 /dev/zero"])
        self.assertEqual(len(tmp.unb64(r["stdout"])), 500000)


class Workers(unittest.TestCase):
    def test_pool_bounds_concurrency(self):
        m = helpers.load_module()
        pool = m.WorkerPool(2)
        import threading
        cur, peak, lock = [0], [0], threading.Lock()
        done = threading.Event()
        count = [0]

        def work():
            with lock:
                cur[0] += 1
                peak[0] = max(peak[0], cur[0])
            time.sleep(0.05)
            with lock:
                cur[0] -= 1
                count[0] += 1
                if count[0] == 12:
                    done.set()
        for _ in range(12):
            pool.submit(work)
        self.assertTrue(done.wait(10))
        self.assertLessEqual(peak[0], 2)
        pool.close()


if __name__ == "__main__":
    unittest.main()
