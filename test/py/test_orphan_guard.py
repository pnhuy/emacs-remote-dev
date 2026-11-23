"""SIGKILL of the agent must not leave its children running (orphan guard)."""
import json
import os
import signal
import subprocess
import sys
import time
import unittest

import helpers


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class OrphanGuardTests(unittest.TestCase):
    def run_case(self, method, params):
        marker = "rdev-orphan-%d" % os.getpid()
        agent = subprocess.Popen([sys.executable, helpers.SERVER_PATH],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(lambda: agent.poll() is None and agent.kill())
        pidfile = "/tmp/%s.%s" % (marker, method.replace("/", "-"))
        self.addCleanup(lambda: os.path.exists(pidfile) and os.unlink(pidfile))
        script = "echo $$ > %s; exec sleep 300" % pidfile
        params = dict(params, cmd=["sh", "-c", script])
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                           "params": params}).encode()
        agent.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        agent.stdin.flush()
        deadline = time.time() + 10
        while time.time() < deadline and not (
                os.path.exists(pidfile) and open(pidfile).read().strip()):
            time.sleep(0.05)
        child = int(open(pidfile).read().strip())
        self.assertTrue(alive(child))
        agent.send_signal(signal.SIGKILL)
        agent.wait()
        deadline = time.time() + 10
        while time.time() < deadline and alive(child):
            time.sleep(0.1)
        if alive(child):
            os.kill(child, signal.SIGKILL)
            self.fail("child %d outlived a SIGKILLed agent" % child)

    def test_proc_spawn_child_dies_with_agent(self):
        self.run_case("proc/spawn", {"id": "g1"})

    def test_exec_run_child_dies_with_agent(self):
        self.run_case("exec/run", {})


if __name__ == "__main__":
    unittest.main()
