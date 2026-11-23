"""T089: project/root and project/files (R12, FR-022)."""
import os
import shutil
import subprocess
import tempfile
import unittest

import helpers

HAVE_GIT = shutil.which("git") is not None


class ProjectBase(unittest.TestCase):
    def setUp(self):
        self.d = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d, True)
        self.drv = helpers.Driver()

    def w(self, rel, text="x\n"):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        return p

    def root(self, path, **kw):
        return self.drv.call("project/root", path=path, **kw)


class TestRoot(ProjectBase):
    def test_capability_advertised(self):
        out = helpers.Driver().run_raw(helpers.frame(
            {"jsonrpc": "2.0", "id": 1, "method": "hello", "params": {}}))
        self.assertIn("project.root", out[0]["result"]["capabilities"])

    def test_default_marker_found_walking_up(self):
        self.w("proj/pyproject.toml")
        self.w("proj/src/pkg/mod.py")
        res, err = self.root(os.path.join(self.d, "proj/src/pkg/mod.py"))
        self.assertIsNone(err)
        self.assertEqual(res["root"], os.path.join(self.d, "proj"))
        self.assertEqual(res["marker"], "pyproject.toml")

    def test_directory_argument_and_trailing_slash(self):
        self.w("proj/Makefile")
        os.makedirs(os.path.join(self.d, "proj/a/b"))
        res, _ = self.root(os.path.join(self.d, "proj/a/b/"))
        self.assertEqual(res["root"], os.path.join(self.d, "proj"))

    def test_vcs_marker_beats_nearer_build_marker(self):
        os.makedirs(os.path.join(self.d, "repo/.git"))
        self.w("repo/sub/package.json", "{}")
        self.w("repo/sub/x.js")
        res, _ = self.root(os.path.join(self.d, "repo/sub/x.js"))
        self.assertEqual(res["root"], os.path.join(self.d, "repo"))
        self.assertEqual(res["marker"], ".git")
        self.assertEqual(res["vcs"], "git")

    def test_nearest_vcs_root_wins(self):
        os.makedirs(os.path.join(self.d, "outer/.git"))
        os.makedirs(os.path.join(self.d, "outer/inner/.git"))
        self.w("outer/inner/f")
        res, _ = self.root(os.path.join(self.d, "outer/inner/f"))
        self.assertEqual(res["root"], os.path.join(self.d, "outer/inner"))

    def test_custom_markers_replace_defaults(self):
        self.w("p/.myroot")
        self.w("p/Makefile")
        self.w("p/sub/f")
        res, _ = self.root(os.path.join(self.d, "p/sub/f"), markers=[".myroot"])
        self.assertEqual(res["root"], os.path.join(self.d, "p"))
        self.assertEqual(res["marker"], ".myroot")
        res, _ = self.root(os.path.join(self.d, "p/sub/f"), markers=["nope"])
        self.assertIsNone(res["root"])

    def test_no_marker_gives_null_root(self):
        self.w("lonely/f")
        res, err = self.root(os.path.join(self.d, "lonely/f"), markers=["zzz"])
        self.assertIsNone(err)
        self.assertEqual(res, {"root": None})

    def test_missing_path_still_walks_up(self):
        self.w("proj/.git/HEAD")
        res, err = self.root(os.path.join(self.d, "proj/not/yet/created.py"))
        self.assertIsNone(err)
        self.assertEqual(res["root"], os.path.join(self.d, "proj"))

    def test_invalid_params(self):
        for kw in ({"path": ""}, {"path": 5}, {"path": "a\0b"},
                   {"path": self.d, "markers": "x"},
                   {"path": self.d, "markers": [1]},
                   {"path": self.d, "markers": ["a/b"]},
                   {"path": self.d, "markers": [""]},
                   {"path": self.d, "markers": ["m"] * 65}):
            res, err = self.drv.call("project/root", **kw)
            self.assertIsNone(res, kw)
            self.assertEqual(err["code"], -32602, kw)

    def test_symlinked_start_is_resolved_by_walk_not_followed(self):
        self.w("proj/.git/HEAD")
        os.makedirs(os.path.join(self.d, "elsewhere"))
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.d, "proj/link"))
        res, _ = self.root(os.path.join(self.d, "proj/link"))
        self.assertEqual(res["root"], os.path.join(self.d, "proj"))

    def test_symlinked_dir_with_marker_is_its_own_root(self):
        self.w("outer/.git/HEAD")
        self.w("real/.git/HEAD")
        os.makedirs(os.path.join(self.d, "outer/sub"))
        link = os.path.join(self.d, "outer/sub/link")
        os.symlink(os.path.join(self.d, "real"), link)
        res, _ = self.root(link)
        self.assertEqual(res["root"], link)


class TestFiles(ProjectBase):
    def files(self, **kw):
        return self.drv.result("project/files", root=self.d, **kw)

    def test_plain_walk_lists_files_and_skips_hidden_dirs(self):
        self.w("a.txt")
        self.w("sub/b.txt")
        self.w(".hid/c.txt")
        got = self.drv.result("project/files", root=self.d, engine="walk")
        self.assertEqual(sorted(got), ["a.txt", "sub/b.txt"])

    @unittest.skipUnless(HAVE_GIT, "git not installed")
    def test_git_fast_path_honours_gitignore_and_untracked(self):
        subprocess.run(["git", "init", "-q"], cwd=self.d, check=True)
        self.w(".gitignore", "ignored.txt\nbuild/\n")
        self.w("tracked.txt")
        self.w("ignored.txt")
        self.w("build/out.o")
        subprocess.run(["git", "add", "tracked.txt", ".gitignore"], cwd=self.d, check=True)
        self.w("untracked.txt")
        res = self.drv.result("project/files", root=self.d, detail=True)
        self.assertEqual(res["engine"], "git")
        self.assertEqual(sorted(res["files"]),
                         [".gitignore", "tracked.txt", "untracked.txt"])

    @unittest.skipUnless(HAVE_GIT, "git not installed")
    def test_git_listing_omits_files_deleted_from_disk(self):
        subprocess.run(["git", "init", "-q"], cwd=self.d, check=True)
        self.w("gone.txt")
        self.w("kept.txt")
        subprocess.run(["git", "add", "."], cwd=self.d, check=True)
        os.unlink(os.path.join(self.d, "gone.txt"))
        self.assertEqual(self.files(), ["kept.txt"])

    def test_legacy_shape_is_a_plain_list(self):
        self.w("a.txt")
        self.assertIsInstance(self.files(), list)

    def test_detail_reports_engine(self):
        self.w("a.txt")
        res = self.drv.result("project/files", root=self.d, detail=True, engine="walk")
        self.assertEqual(res, {"files": ["a.txt"], "engine": "walk"})

    def test_unknown_engine_is_invalid_params(self):
        res, err = self.drv.call("project/files", root=self.d, engine="nope")
        self.assertEqual(err["code"], -32602)

    def test_no_file_contents_in_response(self):
        self.w("secret.txt", "TOP-SECRET-CONTENT\n")
        raw = helpers.Driver().run_raw(helpers.frame(
            {"jsonrpc": "2.0", "id": 1, "method": "project/files",
             "params": {"root": self.d}}))
        self.assertNotIn("TOP-SECRET-CONTENT", repr(raw))

    def test_missing_root_is_an_error_not_empty_success(self):
        res, err = self.drv.call("project/files", root=os.path.join(self.d, "nope"))
        self.assertIsNotNone(err)

    def test_max_bounds_the_listing(self):
        for i in range(10):
            self.w("f%d" % i)
        res = self.drv.result("project/files", root=self.d, detail=True, max=3, engine="walk")
        self.assertEqual(len(res["files"]), 3)
        self.assertTrue(res["truncated"])


if __name__ == "__main__":
    unittest.main()
