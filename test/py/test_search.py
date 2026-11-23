"""T088: search/grep (R11) -- rg engine, python fallback, batching, limits, errors."""
import os
import shutil
import subprocess
import tempfile
import unittest

import helpers

HAVE_RG = shutil.which("rg") is not None


def grep(root, engine=None, stream=False, **kw):
    """Run search/grep; returns (result, error, streamed_matches)."""
    d = helpers.Driver()
    d._id += 1
    out = d.run_raw(helpers.frame({"jsonrpc": "2.0", "id": 1, "method": "search/grep",
                                   "params": dict(root=root, stream=stream,
                                                  **({"engine": engine} if engine else {}),
                                                  **kw)}))
    res = err = None
    streamed = []
    for m in out:
        if m.get("id") == 1:
            res, err = m.get("result"), m.get("error")
        elif m.get("method") == "search/result":
            assert m["params"]["id"] == 1
            streamed += m["params"]["matches"]
    return res, err, streamed


class Base:
    engine = None

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)
        self.w("a.txt", "hello world\nsecond Hello\nthird\n")
        self.w("sub/b.py", "def hello():\n    return 'hi'\n")
        self.w("bin.dat", "hello\0binary")
        self.w(".hidden", "hello hidden\n")

    def w(self, rel, text):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    def g(self, **kw):
        return grep(self.d, engine=self.engine, **kw)

    def test_basic_and_engine_key(self):
        res, err, _ = self.g(pattern="hello", case="sensitive")
        self.assertIsNone(err)
        self.assertEqual(res["engine"], self.engine)
        self.assertEqual(res["count"], 2)
        self.assertFalse(res["truncated"])
        paths = sorted((m["path"], m["line"]) for m in res["matches"])
        self.assertEqual(paths, [("a.txt", 1), ("sub/b.py", 1)])

    def test_smart_case(self):
        res, _, _ = self.g(pattern="hello")          # lowercase -> insensitive
        self.assertEqual(res["count"], 3)
        res, _, _ = self.g(pattern="Hello")          # has upper -> sensitive
        self.assertEqual(res["count"], 1)

    def test_submatch_columns(self):
        res, _, _ = self.g(pattern="world", case="sensitive")
        m = res["matches"][0]
        self.assertEqual(m["submatches"], [[6, 11]])
        self.assertEqual(m["col"], 7)

    def test_regex_and_literal(self):
        res, _, _ = self.g(pattern="h.llo", regex=True, case="sensitive")
        self.assertEqual(res["count"], 2)
        res, _, _ = self.g(pattern="h.llo", regex=False, case="sensitive")
        self.assertEqual(res["count"], 0)

    def test_invalid_regex(self):
        res, err, _ = self.g(pattern="(unclosed", regex=True)
        self.assertEqual(err["code"], -32602)

    def test_globs(self):
        res, _, _ = self.g(pattern="hello", globs=["*.py"])
        self.assertEqual({m["path"] for m in res["matches"]}, {"sub/b.py"})

    def test_hidden(self):
        res, _, _ = self.g(pattern="hidden", hidden=True)
        self.assertEqual(res["count"], 1)
        res, _, _ = self.g(pattern="hidden")
        self.assertEqual(res["count"], 0)

    def test_binary_skipped(self):
        res, _, _ = self.g(pattern="binary")
        self.assertEqual(res["count"], 0)

    def test_max_results_truncates(self):
        self.w("many.txt", "x\n" * 50)
        res, _, _ = self.g(pattern="x", max_results=10)
        self.assertEqual(res["count"], 10)
        self.assertTrue(res["truncated"])

    def test_exact_limit_not_truncated(self):
        self.w("many.txt", "zzz\n" * 5)
        res, _, _ = self.g(pattern="zzz", max_results=5)
        self.assertEqual(res["count"], 5)
        self.assertFalse(res["truncated"])

    def test_context(self):
        res, _, _ = self.g(pattern="second", context=1, globs=["a.txt"])
        ctx = [m for m in res["matches"] if m.get("context")]
        self.assertEqual(res["count"], 1)
        self.assertEqual(sorted(m["line"] for m in ctx), [1, 3])

    def test_streaming_batches(self):
        self.w("many.txt", "needle\n" * 250)
        res, err, streamed = self.g(pattern="needle", stream=True, max_results=1000)
        self.assertIsNone(err)
        self.assertEqual(res["count"], 250)
        self.assertEqual(len(streamed), 250)
        self.assertNotIn("matches", res)

    def test_bad_root(self):
        _, err, _ = grep(os.path.join(self.d, "nope"), engine=self.engine, pattern="x")
        self.assertIsNotNone(err)

    def test_param_validation(self):
        for kw in ({"pattern": ""}, {"pattern": "x", "case": "bogus"},
                   {"pattern": "x", "max_results": 0},
                   {"pattern": "x", "context": 99},
                   {"pattern": "x", "globs": "*.py"}):
            _, err, _ = self.g(**kw)
            self.assertEqual(err["code"], -32602, kw)

    def test_no_shell_interpretation(self):
        self.w("weird.txt", "a;b $(touch pwned)\n")
        res, _, _ = self.g(pattern="$(touch pwned)")
        self.assertEqual(res["count"], 1)
        self.assertFalse(os.path.exists(os.path.join(self.d, "pwned")))
        self.assertFalse(os.path.exists("pwned"))


class PythonEngine(Base, unittest.TestCase):
    engine = "python"

    def test_git_ignore_honoured(self):
        subprocess.run(["git", "init", "-q"], cwd=self.d, check=True)
        self.w(".gitignore", "ignored.txt\n")
        self.w("ignored.txt", "hello ignored\n")
        res, _, _ = self.g(pattern="ignored")
        self.assertEqual(res["count"], 0)
        res, _, _ = self.g(pattern="ignored", ignore=False)
        self.assertGreaterEqual(res["count"], 1)       # --no-ignore sees ignored.txt


@unittest.skipUnless(HAVE_RG, "ripgrep not installed")
class RgEngine(Base, unittest.TestCase):
    engine = "rg"

    def test_default_picks_rg(self):
        res, _, _ = grep(self.d, pattern="hello")
        self.assertEqual(res["engine"], "rg")


class NoRg(unittest.TestCase):
    def test_default_falls_back_to_python(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        with open(os.path.join(d, "f.txt"), "w") as f:
            f.write("needle\n")
        old = os.environ["PATH"]
        os.environ["PATH"] = "/nonexistent"
        try:
            res, err, _ = grep(d, pattern="needle")
        finally:
            os.environ["PATH"] = old
        self.assertIsNone(err)
        self.assertEqual(res["engine"], "python")
        self.assertEqual(res["count"], 1)

    def test_explicit_rg_missing_is_unsupported(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        old = os.environ["PATH"]
        os.environ["PATH"] = "/nonexistent"
        try:
            _, err, _ = grep(d, engine="rg", pattern="x")
        finally:
            os.environ["PATH"] = old
        self.assertEqual(err["code"], -32012)


class CancelSearch(unittest.TestCase):
    """$/cancel stops a running search promptly with -32800 (both engines)."""

    def run_cancel(self, engine):
        import test_methods_proc as tmp
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        line = "x" * 200 + " needle\n"
        for i in range(60):
            with open(os.path.join(d, "f%d.txt" % i), "w") as f:
                f.write(line * 20000)
        h = tmp.StreamingProc()
        h.start()
        self.addCleanup(h.tearDown)
        rid = h.send("search/grep", root=d, pattern="needle", engine=engine,
                     max_results=100000, stream=False)
        import json, time
        time.sleep(0.3)
        body = json.dumps({"jsonrpc": "2.0", "method": "$/cancel",
                           "params": {"id": rid}}).encode()
        h.inp.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        h.inp.flush()
        t0 = time.time()
        while time.time() - t0 < 10:
            m = h.read_one()
            if m.get("id") == rid:
                self.assertEqual(m["error"]["code"], -32800)
                return
        self.fail("no response to cancelled search")

    def test_cancel_python(self):
        self.run_cancel("python")

    @unittest.skipUnless(HAVE_RG, "ripgrep not installed")
    def test_cancel_rg(self):
        self.run_cancel("rg")


class Capability(unittest.TestCase):
    def test_advertised(self):
        self.assertIn("search.grep", helpers.Driver().result("hello")["capabilities"])


if __name__ == "__main__":
    unittest.main()
