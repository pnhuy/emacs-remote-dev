"""The agent refuses to run as uid 0 by default.

The only override is the --allow-root command-line flag, which the Emacs
client passes only for a Docker target with :allow-root set.  No environment
variable or configuration can enable it.
"""
import os
import subprocess
import sys
import textwrap
import unittest

SERVER = os.path.join(os.path.dirname(__file__), "..", "..", "rdev-server.py")


def run_agent(argv, env=None):
    """Run rdev-server.py's main with os.geteuid patched to 0."""
    code = textwrap.dedent(f"""
        import os, runpy, sys
        os.geteuid = lambda: 0
        sys.argv = {argv!r}
        runpy.run_path({SERVER!r}, run_name="__main__")
    """)
    return subprocess.run([sys.executable, "-c", code], capture_output=True,
                          text=True, timeout=30, stdin=subprocess.DEVNULL,
                          env=env)


class RootRefusal(unittest.TestCase):
    def test_refuses_uid0_by_default(self):
        p = run_agent([SERVER, "--stdio"])
        self.assertEqual(p.returncode, 5)
        self.assertIn("refusing to run as root", p.stderr)

    def test_env_override_does_not_enable_root(self):
        env = dict(os.environ, RDEV_ALLOW_ROOT="1")
        p = run_agent([SERVER, "--stdio"], env=env)
        self.assertEqual(p.returncode, 5)
        self.assertIn("refusing to run as root", p.stderr)

    def test_allow_root_flag_reaches_session_startup(self):
        # With the flag the agent must get past the root check: with stdin at
        # EOF the stdio session ends cleanly instead of exiting 5.
        p = run_agent([SERVER, "--stdio", "--allow-root"])
        self.assertNotEqual(p.returncode, 5)
        self.assertNotIn("refusing to run as root", p.stderr)

    def test_allow_root_is_command_line_only(self):
        with open(SERVER) as f:
            src = f.read()
        # The flag exists on the CLI ...
        self.assertIn('"--allow-root"', src)
        # ... but no RDEV_* environment variable can enable it.
        self.assertNotIn("RDEV_ALLOW_ROOT", src)


if __name__ == "__main__":
    unittest.main()
