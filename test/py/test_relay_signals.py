"""T080 (R-05): relay frames must never interleave when signals arrive
while a large stdin frame is being sent."""
import os
import signal
import struct
import time
import unittest

from test_relay import FakeEmacs, frame


class RelaySignalInterleave(unittest.TestCase):
    def test_signals_during_large_sends_keep_frames_whole(self):
        e = FakeEmacs().launch()
        self.addCleanup(e.close)
        t, _ = e.read_frame()
        self.assertEqual(t, b"H")
        chunk = b"x" * 65536
        total_chunks = 60
        nsignals = 200
        e.conn.settimeout(30)

        # Do not read for a moment so the relay's socket buffer fills and
        # sendall() of a big frame blocks mid-frame; then fire signals.
        import threading

        def feed():
            for _ in range(total_chunks):
                e.p.stdin.write(chunk)
                e.p.stdin.flush()
            e.p.stdin.close()

        th = threading.Thread(target=feed, daemon=True)
        th.start()
        time.sleep(0.5)
        for _ in range(nsignals):
            os.kill(e.p.pid, signal.SIGUSR1)
            time.sleep(0.002)

        got_bytes, got_sigs, closed = 0, 0, False
        deadline = time.time() + 40
        while not closed and time.time() < deadline:
            t, payload = e.read_frame()  # raises/desyncs if frames were corrupted
            if t == b"I":
                self.assertTrue(set(payload) <= {ord("x")}, "I frame payload corrupted")
                got_bytes += len(payload)
            elif t == b"S":
                self.assertEqual(payload, str(int(signal.SIGUSR1)).encode())
                got_sigs += 1
            elif t == b"C":
                closed = True
            else:
                self.fail("unexpected frame type %r" % t)
        self.assertTrue(closed, "stdin-closed frame never arrived")
        self.assertEqual(got_bytes, len(chunk) * total_chunks)
        self.assertGreater(got_sigs, 0)


if __name__ == "__main__":
    unittest.main()
