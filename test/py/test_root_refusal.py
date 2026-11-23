"""T120: the agent refuses to run as uid 0, with no override."""
import os
import subprocess
import sys
import textwrap
import unittest

SERVER = os.path.join(os.path.dirname(__file__), "..", "..", "rdev-server.py")


class RootRefusal(unittest.TestCase):
    def test_refuses_uid0(self):
        code = textwrap.dedent(f"""
            import os, runpy, sys
            os.geteuid = lambda: 0
            sys.argv = [{SERVER!r}, "--stdio"]
            runpy.run_path({SERVER!r}, run_name="__main__")
        """)
        p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                           timeout=20, stdin=subprocess.DEVNULL)
        self.assertEqual(p.returncode, 5)
        self.assertIn("refusing to run as root", p.stderr)

    def test_no_override_flag(self):
        with open(SERVER) as f:
            src = f.read()
        self.assertNotIn("--allow-root", src)


if __name__ == "__main__":
    unittest.main()
