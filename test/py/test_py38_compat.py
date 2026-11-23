"""T126: agent and relay must stay Python 3.8 compatible (FR-004b, Article VI)."""
import ast
import os
import re
import unittest

import helpers

BANNED = [r"\.removeprefix\(", r"\.removesuffix\(", r"\bzoneinfo\b", r"\bmatch\s+\w+\s*:",
          r"\bdict\[", r"\blist\[", r"\btuple\[", r"\bset\[", r"functools\.cache\b",
          r"\bmath\.lcm\b", r"int\.bit_count", r"\bgraphlib\b"]


class Py38(unittest.TestCase):
    def sources(self):
        for p in (helpers.SERVER_PATH, helpers.RELAY_PATH):
            with open(p, encoding="utf-8") as f:
                yield p, f.read()

    def test_parses_as_38(self):
        for p, src in self.sources():
            ast.parse(src, filename=p, feature_version=(3, 8))

    def test_no_39_plus_apis(self):
        for p, src in self.sources():
            code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
            for pat in BANNED:
                m = re.search(pat, code)
                self.assertIsNone(m, "%s uses 3.9+ construct %r" % (os.path.basename(p), pat))


if __name__ == "__main__":
    unittest.main()
