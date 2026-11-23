"""T067: signalled exit code is 128+sig and `signal` is present for exec/run and proc/exit (D-07)."""
import signal
import unittest

import helpers
import test_methods_proc


class ExitCodes(unittest.TestCase):
    def test_exec_run_signalled(self):
        d = helpers.Driver()
        r = d.result("exec/run", cmd=["sh", "-c", "kill -TERM $$"])
        self.assertEqual((r["signal"], r["code"]), (15, 128 + 15))

    def test_exec_run_plain_exit_has_no_signal(self):
        d = helpers.Driver()
        r = d.result("exec/run", cmd=["sh", "-c", "exit 7"])
        self.assertEqual(r["code"], 7)
        self.assertFalse(r.get("signal"))

    def test_proc_exit_matches_exec_run(self):
        t = test_methods_proc.StreamingProc()
        t.start()
        t.send("proc/spawn", id="x1", cmd=["sh", "-c", "kill -KILL $$"])
        ex, _ = t.wait_exit()
        d = helpers.Driver()
        r = d.result("exec/run", cmd=["sh", "-c", "kill -KILL $$"])
        self.assertEqual((ex["signal"], ex["code"]), (r["signal"], r["code"]))
        self.assertEqual(ex["code"], 128 + signal.SIGKILL)
        t.tearDown()


if __name__ == "__main__":
    unittest.main()
