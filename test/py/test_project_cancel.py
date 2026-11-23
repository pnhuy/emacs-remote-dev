"""project/files honours $/cancel while its git/rg subprocess runs (was: ran to completion)."""
import os
import stat
import tempfile
import time
import unittest
from unittest import mock

import test_concurrency as tc


class ProjectFilesCancel(unittest.TestCase):
    def test_cancel_kills_running_listing(self):
        marker = "RDEVPROJCANCEL%d" % os.getpid()
        # pgrep -f matches the command line, which includes the script's path
        bin_dir = tempfile.mkdtemp(prefix=marker)
        root = tempfile.mkdtemp(prefix="rdev-proj-")
        fake = os.path.join(bin_dir, "git")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\nsleep 60\n")
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        env = dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"])
        with mock.patch.dict(os.environ, env, clear=True):
            a = tc.Agent()
        self.addCleanup(a.kill)
        a.request(1, "project/files", root=root)
        for _ in range(100):
            if tc.leftovers(marker):
                break
            time.sleep(0.05)
        self.assertTrue(tc.leftovers(marker), "fake git never started")
        t0 = time.time()
        a.notify("$/cancel", id=1)
        self.assertTrue(a.wait_responses([1], 10), "no response after cancel")
        self.assertLess(time.time() - t0, 5)
        self.assertEqual(a.responses[1]["error"]["code"], -32800)
        for _ in range(60):
            if not tc.leftovers(marker):
                break
            time.sleep(0.1)
        self.assertFalse(tc.leftovers(marker), "listing subprocess survived cancel")


if __name__ == "__main__":
    unittest.main()
