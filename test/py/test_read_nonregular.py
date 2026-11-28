"""fs/read and fs/readChunk refuse non-regular files without blocking."""
import os
import socket
import tempfile
import time
import unittest

import helpers


class ReadNonRegular(unittest.TestCase):
    def setUp(self):
        self.d = helpers.Driver()
        self.tmp = tempfile.mkdtemp(prefix="rdev-py-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, True))

    def p(self, *a):
        return os.path.join(self.tmp, *a)

    def assert_refused(self, path):
        for method, extra in (("fs/read", {}),
                              ("fs/readChunk", {"offset": 0, "length": 16})):
            t0 = time.monotonic()
            _, err = self.d.call(method, path=path, **extra)
            self.assertLess(time.monotonic() - t0, 5, method)
            self.assertEqual(err["code"], -32001, method)
            self.assertEqual(err["message"], "not a regular file", method)
            self.assertEqual(err["data"]["errno"], "EINVAL", method)

    def test_socket(self):
        s = socket.socket(socket.AF_UNIX)
        self.addCleanup(s.close)
        s.bind(self.p("sock"))
        self.assert_refused(self.p("sock"))

    def test_fifo_does_not_block(self):
        os.mkfifo(self.p("fifo"))
        self.assert_refused(self.p("fifo"))
        # the connection is still usable afterwards
        self.assertIsNone(self.d.result("fs/stat", path=self.p("none")))

    def test_endless_device(self):
        self.assert_refused("/dev/zero")

    def test_regular_file_still_reads(self):
        with open(self.p("f"), "wb") as f:
            f.write(b"abc")
        self.assertIn("data", self.d.result("fs/read", path=self.p("f")))
        self.assertIn("data", self.d.result("fs/readChunk", path=self.p("f"),
                                            offset=0, length=3))


if __name__ == "__main__":
    unittest.main()
