"""T122: deadlock/race stress (FR-019).

Drives a real agent process over stdio with 200 concurrent mixed requests
(exec/run, proc/spawn flood, fs/*, cancel) and ends each round with
session/shutdown.  A 30 s watchdog turns any deadlock into a failure.
RDEV_STRESS_ROUNDS (default 20) sets the repetitions.
"""
import base64
import json
import os
import subprocess
import subprocess as sp
import sys
import threading
import time
import unittest

import helpers

ROUNDS = int(os.environ.get("RDEV_STRESS_ROUNDS", "20"))
WATCHDOG = 30
N = 200


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


class Agent:
    def __init__(self):
        self.p = sp.Popen([sys.executable, "-u", helpers.SERVER_PATH, "--stdio"],
                          stdin=sp.PIPE, stdout=sp.PIPE, stderr=sp.DEVNULL)
        self.responses = {}
        self.exits = 0
        self.cv = threading.Condition()
        self.wlock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        out = self.p.stdout
        while True:
            n = None
            while True:
                line = out.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                if line.lower().startswith(b"content-length"):
                    n = int(line.split(b":")[1])
            if n is None:
                return
            m = json.loads(out.read(n))
            with self.cv:
                if "id" in m and ("result" in m or "error" in m):
                    self.responses[m["id"]] = m
                elif m.get("method") == "proc/exit":
                    self.exits += 1
                self.cv.notify_all()

    def send(self, obj):
        with self.wlock:
            try:
                self.p.stdin.write(frame(obj))
                self.p.stdin.flush()
            except (BrokenPipeError, ValueError):
                pass

    def request(self, rid, method, **params):
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})

    def notify(self, method, **params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_responses(self, ids, timeout):
        deadline = time.time() + timeout
        with self.cv:
            while not all(i in self.responses for i in ids):
                left = deadline - time.time()
                if left <= 0:
                    return False
                self.cv.wait(left)
        return True

    def kill(self):
        try:
            self.p.kill()
        except OSError:
            pass


def leftovers(marker):
    r = sp.run(["pgrep", "-f", marker], stdout=sp.PIPE, stderr=sp.DEVNULL)
    return [x for x in r.stdout.decode().split() if x]


class Stress(unittest.TestCase):
    def one_round(self, rnd, clean):
        marker = "RDEVSTRESS%d_%d" % (os.getpid(), rnd)
        a = Agent()
        self.addCleanup(a.kill)
        sleepers = []
        for i in range(1, N + 1):
            k = i % 5
            if k == 0:
                a.request(i, "exec/run", cmd=["echo", str(i)])
            elif k == 1:
                a.request(i, "exec/run", cmd=["sh", "-c", "sleep 20 # %s" % marker])
                sleepers.append(i)
            elif k == 2:
                # Output flood: must be drained, never deadlock the writer.
                a.request(i, "proc/spawn",
                          cmd=["sh", "-c", "head -c 400000 /dev/zero | base64; sleep 0.1 # " + marker])
            elif k == 3:
                a.request(i, "fs/stat", path="/tmp")
            else:
                a.request(i, "fs/readdir", path="/tmp")
        # Slow requests share a bounded pool (--workers); sleepers that are
        # never cancelled would legitimately hold it, so clean rounds cancel
        # all of them and busy rounds cancel half and shut down mid-flight.
        cancelled = sleepers if clean else sleepers[: len(sleepers) // 2]
        for i in cancelled:
            a.notify("$/cancel", id=i)
        if clean:
            others = [i for i in range(1, N + 1) if i not in sleepers]
            self.assertTrue(a.wait_responses(others + cancelled, WATCHDOG),
                            "round %d: requests unanswered (deadlock?)" % rnd)
            for i in cancelled:
                self.assertIn("error", a.responses[i])
                self.assertEqual(a.responses[i]["error"]["code"], -32800)
        a.request(N + 1, "session/shutdown", grace_ms=300)
        try:
            a.p.wait(timeout=WATCHDOG)
        except sp.TimeoutExpired:
            self.fail("round %d: agent did not exit after session/shutdown" % rnd)
        # The agent must take its process groups with it.
        for _ in range(60):
            if not leftovers(marker):
                break
            time.sleep(0.1)
        self.assertEqual(leftovers(marker), [], "round %d: orphaned children" % rnd)

    def test_stress_rounds(self):
        t0 = time.time()
        for rnd in range(ROUNDS):
            self.one_round(rnd, clean=(rnd % 2 == 0))
        sys.stderr.write("concurrency: %d rounds in %.1fs\n" % (ROUNDS, time.time() - t0))


if __name__ == "__main__":
    unittest.main()
