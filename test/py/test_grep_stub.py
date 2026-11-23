"""T078 (D-04) superseded by T090: search/grep is now implemented and advertised.
The error contract for an unavailable engine is pinned in test_search.py."""
import unittest

import helpers


class GrepAdvertised(unittest.TestCase):
    def test_advertised(self):
        self.assertIn("search.grep", helpers.Driver().result("hello")["capabilities"])

    def test_no_longer_a_stub(self):
        res, err = helpers.Driver().call("search/grep", pattern="x", root="/tmp",
                                         max_results=1)
        self.assertIsNone(err)
        self.assertIn(res["engine"], ("rg", "python"))


if __name__ == "__main__":
    unittest.main()
