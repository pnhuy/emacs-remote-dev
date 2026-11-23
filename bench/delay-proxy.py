#!/usr/bin/env python3
"""Latency/bandwidth/loss shaper usable as an ssh ProxyCommand (stdlib only).

    ProxyCommand python3 bench/delay-proxy.py --connect %h:%p --rtt-ms 50

Delays every chunk by RTT/2 in each direction and optionally caps bandwidth.
TCP cannot lose bytes, so --loss models packet loss the way TCP experiences
it: with probability P a chunk is held back an extra retransmission timeout
(--rto-ms, default 200).  This is a coarser model than tc netem; the benchmark
report records which shaper produced each row.
"""
import argparse, os, queue, random, socket, sys, threading, time


def pump(read, write, delay, rate, loss, rto, close):
    q = queue.Queue()

    def reader():
        try:
            while True:
                data = read(65536)
                if not data:
                    break
                extra = rto if loss and random.random() < loss else 0.0
                q.put((time.monotonic() + delay + extra, data))
        finally:
            q.put(None)

    threading.Thread(target=reader, daemon=True).start()
    nxt = 0.0
    while True:
        item = q.get()
        if item is None:
            break
        due, data = item
        now = time.monotonic()
        if due > now:
            time.sleep(due - now)
        if rate:
            now = time.monotonic()
            if nxt > now:
                time.sleep(nxt - now)
            nxt = max(now, nxt) + len(data) / rate
        try:
            write(data)
        except OSError:
            break
    close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--connect", required=True, help="HOST:PORT to forward to")
    ap.add_argument("--rtt-ms", type=float, default=0.0)
    ap.add_argument("--loss", type=float, default=0.0, help="fraction, e.g. 0.01")
    ap.add_argument("--rto-ms", type=float, default=200.0)
    ap.add_argument("--rate-bps", type=float, default=0.0, help="bytes per second cap")
    a = ap.parse_args()
    host, _, port = a.connect.rpartition(":")
    s = socket.create_connection((host, int(port)))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    d = a.rtt_ms / 2000.0
    rto = a.rto_ms / 1000.0
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer

    def out(b):
        stdout.write(b)
        stdout.flush()

    t = threading.Thread(
        target=pump,
        args=(lambda n: os.read(0, n), s.sendall, d, a.rate_bps, a.loss, rto,
              lambda: s.shutdown(socket.SHUT_WR)),
        daemon=True)
    t.start()
    pump(lambda n: s.recv(n), out, d, a.rate_bps, a.loss, rto, lambda: None)
    t.join(timeout=1)


if __name__ == "__main__":
    main()
