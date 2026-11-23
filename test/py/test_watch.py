"""T047: watch backends and watch/add, watch/remove, watch/event (cap watch)."""
import json
import os
import select
import sys
import tempfile
import threading
import time
import unittest

import helpers


class Live:
    """A Session on real pipes so notifications can be observed while it runs."""

    def __init__(self, backend=None):
        if backend:
            os.environ["RDEV_WATCH_BACKEND"] = backend
        self.m = helpers.load_module()
        self.c2s_r, self.c2s_w = os.pipe()
        self.s2c_r, self.s2c_w = os.pipe()
        self.s = self.m.Session(os.fdopen(self.c2s_r, "rb"), os.fdopen(self.s2c_w, "wb"))
        self.t = threading.Thread(target=self.s.serve, daemon=True)
        self.t.start()
        self.out = os.fdopen(self.s2c_r, "rb")
        self._id = 0
        self.events = []

    def _read(self, timeout):
        r, _, _ = select.select([self.out], [], [], timeout)
        if not r:
            return None
        hdr = b""
        while not hdr.endswith(b"\r\n\r\n"):
            hdr += self.out.read(1)
        n = int(hdr.split(b":")[1].strip())
        return json.loads(self.out.read(n))

    def call(self, method, **params):
        self._id += 1
        os.write(self.c2s_w, helpers.frame({"jsonrpc": "2.0", "id": self._id,
                                            "method": method, "params": params}))
        deadline = time.time() + 5
        while time.time() < deadline:
            msg = self._read(0.2)
            if msg is None:
                continue
            if msg.get("id") == self._id:
                return msg.get("result"), msg.get("error")
            if msg.get("method") == "watch/event":
                self.events.append(msg["params"])
        raise AssertionError("no response")

    def wait_event(self, pred, timeout=5):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for p in self.events:
                for e in p["events"]:
                    if pred(p, e):
                        return p, e
            msg = self._read(0.1)
            if msg and msg.get("method") == "watch/event":
                self.events.append(msg["params"])
        return None

    def close(self):
        os.close(self.c2s_w)
        self.t.join(timeout=5)


def backends():
    names = ["poll"]
    if sys.platform.startswith("linux"):
        names.append("inotify")
    if hasattr(select, "kqueue"):
        names.append("kqueue")
    return names


class WatchSession(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.addCleanup(self.t.cleanup)
        self.addCleanup(os.environ.pop, "RDEV_WATCH_BACKEND", None)

    def live(self, backend):
        lv = Live(backend)
        self.addCleanup(lv.close)
        return lv

    def test_capability(self):
        self.assertIn("watch", helpers.Driver().result("hello")["capabilities"])

    def test_events_per_backend(self):
        for be in backends():
            with self.subTest(backend=be):
                d = os.path.join(self.t.name, be)
                os.mkdir(d)
                lv = self.live(be)
                res, err = lv.call("watch/add", path=d)
                self.assertIsNone(err)
                self.assertEqual(res["backend"], be)
                f = os.path.join(d, "a.txt")
                open(f, "w").write("1")
                self.assertTrue(lv.wait_event(lambda p, e: e["kind"] == "created" and e["path"] == f),
                                "created")
                time.sleep(1.1)
                open(f, "a").write("2")
                self.assertTrue(lv.wait_event(lambda p, e: e["kind"] == "changed" and e["path"] == f),
                                "changed")
                os.unlink(f)
                self.assertTrue(lv.wait_event(lambda p, e: e["kind"] == "deleted" and e["path"] == f),
                                "deleted")

    def test_watch_single_file(self):
        for be in backends():
            with self.subTest(backend=be):
                f = os.path.join(self.t.name, "one-" + be)
                open(f, "w").write("x")
                lv = self.live(be)
                res, _ = lv.call("watch/add", path=f)
                time.sleep(1.1)
                open(f, "a").write("y")
                self.assertTrue(lv.wait_event(lambda p, e: p["id"] == res["id"] and e["path"] == f))

    def test_remove_stops_events(self):
        lv = self.live("poll")
        d = self.t.name
        res, _ = lv.call("watch/add", path=d)
        r2, _ = lv.call("watch/remove", id=res["id"])
        self.assertTrue(r2["removed"])
        r3, _ = lv.call("watch/remove", id=res["id"])
        self.assertFalse(r3["removed"])
        open(os.path.join(d, "late"), "w").close()
        self.assertIsNone(lv.wait_event(lambda p, e: True, timeout=1.5))

    def test_validation_and_errors(self):
        lv = self.live("poll")
        _, err = lv.call("watch/add", path=os.path.join(self.t.name, "missing"))
        self.assertIsNotNone(err)
        _, err = lv.call("watch/add", path="a\0b")
        self.assertEqual(err["code"], -32602)
        _, err = lv.call("watch/remove", id="x")
        self.assertEqual(err["code"], -32602)

    def test_limit(self):
        lv = self.live("poll")
        for _ in range(lv.m.MAX_WATCHES):
            res, err = lv.call("watch/add", path=self.t.name)
            self.assertIsNone(err)
        _, err = lv.call("watch/add", path=self.t.name)
        self.assertEqual(err["code"], -32011)

    def test_session_end_cleans_up(self):
        lv = Live("poll")
        lv.call("watch/add", path=self.t.name)
        before = [t for t in threading.enumerate() if t.name == "rdev-watch"]
        self.assertTrue(before)
        lv.close()
        deadline = time.time() + 5
        while time.time() < deadline and any(t.is_alive() for t in before):
            time.sleep(0.05)
        self.assertFalse(any(t.is_alive() for t in before))


if __name__ == "__main__":
    unittest.main()
