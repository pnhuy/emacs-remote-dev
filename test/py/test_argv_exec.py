"""T130: commands run via argv; metacharacters are never shell-interpreted."""
import base64
import os
import re
import tempfile
import unittest

import helpers

EVIL = ["a;touch PWNED", "$(touch PWNED)", "`touch PWNED`", "a'b\"c", "line1\nline2", "a b  c"]


class ArgvExec(unittest.TestCase):
    def test_args_are_literal(self):
        d = helpers.Driver()
        with tempfile.TemporaryDirectory() as t:
            r = d.result("exec/run", cmd=["printf", "%s\\0"] + EVIL, cwd=t)
            out = base64.b64decode(r["stdout"]).decode()
            self.assertEqual(out.split("\0")[:-1], EVIL)
            self.assertFalse(os.path.exists(os.path.join(t, "PWNED")))

    def test_env_values_literal(self):
        d = helpers.Driver()
        r = d.result("exec/run", cmd=["sh", "-c", 'printf %s "$V"'], env={"V": "$(id);`id`"})
        self.assertEqual(base64.b64decode(r["stdout"]), b"$(id);`id`")

    def test_cwd_with_metacharacters(self):
        d = helpers.Driver()
        with tempfile.TemporaryDirectory() as t:
            odd = os.path.join(t, "a;b $(x)")
            os.mkdir(odd)
            r = d.result("exec/run", cmd=["pwd"], cwd=odd)
            self.assertTrue(base64.b64decode(r["stdout"]).decode().strip().endswith("a;b $(x)"))

    def test_no_shell_true_in_agent(self):
        src = open(helpers.SERVER_PATH).read()
        self.assertIsNone(re.search(r"shell\s*=\s*True", src))
        self.assertNotIn("os.system(", src)


if __name__ == "__main__":
    unittest.main()
