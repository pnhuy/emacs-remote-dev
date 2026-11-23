"""Test helpers: load rdev-server.py and drive a Session over in-memory streams."""
import importlib.util
import io
import json
import os
import sys
import threading

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SERVER_PATH = os.environ.get("RDEV_TEST_SERVER",
                             os.path.join(ROOT, "rdev-server.py"))
RELAY_PATH = os.path.join(ROOT, "rdev-relay.py")


def load_module(path=SERVER_PATH, name="rdev_server_under_test"):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def read_frames(data):
    """Parse a byte string of framed messages into a list of dicts."""
    out, i = [], 0
    while i < len(data):
        j = data.index(b"\r\n\r\n", i)
        hdr = data[i:j].decode()
        n = int([l for l in hdr.split("\r\n")
                 if l.lower().startswith("content-length")][0].split(":")[1])
        out.append(json.loads(data[j + 4:j + 4 + n]))
        i = j + 4 + n
    return out


class Driver:
    """Run one Session against fed-in bytes; collect everything it writes."""

    def __init__(self, module=None, token=None):
        self.m = module or load_module()
        self.token = token
        self._id = 0

    def run_raw(self, data):
        """Feed raw bytes, serve until EOF, return parsed output frames."""
        r, w = io.BytesIO(data), io.BytesIO()
        s = self.m.Session(r, w, self.token) if self.token else self.m.Session(r, w)
        s.serve()
        for t in threading.enumerate():
            if t is not threading.current_thread() and t.daemon:
                t.join(timeout=5)
        return read_frames(w.getvalue())

    def raw(self, data):
        return self.run_raw(data)

    def call(self, method, **params):
        """One request -> (result, error) tuple."""
        self._id += 1
        out = self.run_raw(frame({"jsonrpc": "2.0", "id": self._id,
                                  "method": method, "params": params}))
        for m in out:
            if m.get("id") == self._id:
                return m.get("result"), m.get("error")
        raise AssertionError("no response for %s: %r" % (method, out))

    def result(self, method, **params):
        res, err = self.call(method, **params)
        if err is not None:
            raise AssertionError("%s failed: %r" % (method, err))
        return res
