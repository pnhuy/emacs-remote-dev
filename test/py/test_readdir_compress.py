"""fs/readdir can return a zlib-compressed listing (slow links); plain form is unchanged."""
import base64
import json
import os
import tempfile
import unittest
import zlib

import test_concurrency as tc


class ReaddirCompress(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rdev-rdz-")
        for i in range(200):
            open(os.path.join(self.d, "file%03d.txt" % i), "w").close()
        self.a = tc.Agent()
        self.addCleanup(self.a.kill)

    def call(self, n, **p):
        self.a.request(n, "fs/readdir", path=self.d, **p)
        self.assertTrue(self.a.wait_responses([n], 10))
        return self.a.responses[n]

    def test_capability_advertised(self):
        self.a.request(90, "hello")
        self.assertTrue(self.a.wait_responses([90], 10))
        self.assertIn("fs.readdirZ", self.a.responses[90]["result"]["capabilities"])

    def test_plain_form_unchanged(self):
        r = self.call(1, attrs=True)["result"]
        self.assertIsInstance(r, list)
        self.assertEqual(len(r), 200)

    def test_compressed_roundtrip_and_smaller(self):
        plain = self.call(2, attrs=True)["result"]
        z = self.call(3, attrs=True, compress=True)["result"]
        self.assertEqual(set(z), {"z"})
        raw = zlib.decompress(base64.b64decode(z["z"]))
        got = json.loads(raw)
        self.assertEqual(sorted(e[0] for e in got), sorted(e[0] for e in plain))
        self.assertLess(len(z["z"]), len(json.dumps(plain)) // 3)

    def test_small_listing_not_compressed(self):
        for n in os.listdir(self.d)[10:]:
            os.remove(os.path.join(self.d, n))
        r = self.call(4, attrs=True, compress=True)["result"]
        self.assertIsInstance(r, list)

    def test_bad_compress_type_rejected(self):
        r = self.call(5, compress="yes")
        self.assertIn("error", r)


if __name__ == "__main__":
    unittest.main()
