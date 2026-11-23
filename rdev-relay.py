#!/usr/bin/env python3
"""rdev-relay: local stand-in for one remote process.

Emacs runs this as the visible subprocess for `make-process' on an rdev
file name.  It connects back to Emacs over a Unix socket; Emacs forwards
the bytes over the single rdev connection to the remote server.

Socket frames are TYPE(1 byte) LEN(4 bytes, big endian) PAYLOAD.
  relay -> emacs: H hello "chan rows cols", I stdin, C stdin closed,
                  S signal number, W "rows cols"
  emacs -> relay: O stdout, E stderr, X exit code
"""
import fcntl
import os
import select
import signal
import socket
import struct
import sys
import termios
import tty


MAX_FRAME = 4 * 1024 * 1024   # bound buffered payload (Article IV)
EMACS_TYPES = (b"O", b"E", b"X")


def protocol_error(msg):
    try:
        os.write(2, ("rdev-relay: protocol error: %s\n" % msg).encode())
    except OSError:
        pass
    os._exit(255)


def frame(t, payload=b""):
    return t + struct.pack(">I", len(payload)) + payload


def winsize():
    try:
        rows, cols, _, _ = struct.unpack(
            "HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
        return rows, cols
    except OSError:
        return 0, 0


def peer_uid(sock):
    """uid of the process that owns the other end of SOCK, or None if unknown.

    Linux: SO_PEERCRED (struct ucred: pid, uid, gid).  macOS/BSD: LOCAL_PEERCRED
    (struct xucred: version, uid, ...).  Best effort: None where unsupported.
    """
    try:
        if hasattr(socket, "SO_PEERCRED"):
            data = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                   struct.calcsize("3i"))
            return struct.unpack("3i", data)[1]
        # LOCAL_PEERCRED is 1 at level SOL_LOCAL (0) on macOS and FreeBSD.
        data = sock.getsockopt(0, 1, struct.calcsize("2I"))
        return struct.unpack("2I", data[:8])[1]
    except (OSError, struct.error, AttributeError):
        return None


def main():
    sock_path, chan = sys.argv[1], sys.argv[2]
    # The secret comes in the environment (argv is world readable) and is removed so
    # that nothing this process starts can see it.
    token = os.environ.pop("RDEV_RELAY_TOKEN", "")
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    # Only talk to a server owned by the same user (T065): a different uid listening
    # on a path we were pointed at must not receive remote process output or input.
    owner = peer_uid(s)
    if owner is not None and owner != os.getuid():
        sys.stderr.write("rdev-relay: refusing socket owned by uid %d\n" % owner)
        sys.exit(255)
    is_tty = os.isatty(0)
    if is_tty:
        # The remote pty does the line discipline / echo.  TCSANOW, not the
        # default TCSAFLUSH: input Emacs sent before we got here (a comint
        # command written right after make-process) must not be discarded.
        tty.setraw(0, termios.TCSANOW)
    rows, cols = winsize()
    hello = "%s %d %d" % (chan, rows, cols)
    if token:
        hello += " " + token
    s.sendall(frame(b"H", hello.encode()))

    # Signal handlers run in the middle of the main loop's sendall(), so they
    # must never write to the socket themselves: that would interleave a
    # signal frame into a half-sent data frame (R-05, T080).  They only queue
    # the event and poke a self-pipe; the main loop sends it between frames.
    pending = []
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False)
    os.set_blocking(wake_w, False)

    def poke():
        try:
            os.write(wake_w, b"x")
        except (BlockingIOError, OSError):
            pass  # pipe full: a wake-up is already pending

    def on_signal(sig, _frm):
        pending.append(("S", sig))
        poke()

    def on_winch(*_):
        pending.append(("W", None))
        poke()

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP,
                signal.SIGQUIT, signal.SIGTSTP, signal.SIGCONT,
                signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(sig, on_signal)
    signal.signal(signal.SIGWINCH, on_winch)

    def flush_pending():
        try:
            os.read(wake_r, 4096)
        except (BlockingIOError, OSError):
            pass
        while pending:
            kind, sig = pending.pop(0)
            if kind == "S":
                s.sendall(frame(b"S", str(sig).encode()))
            else:
                s.sendall(frame(b"W", ("%d %d" % winsize()).encode()))

    buf = b""
    stdin_open = True
    while True:
        rl = [s, wake_r] + ([0] if stdin_open else [])
        try:
            r, _, _ = select.select(rl, [], [])
        except InterruptedError:
            continue
        if wake_r in r or pending:
            flush_pending()
        if 0 in r:
            data = os.read(0, 65536)
            if data:
                s.sendall(frame(b"I", data))
            else:
                stdin_open = False
                s.sendall(frame(b"C"))
        if s in r:
            data = s.recv(65536)
            if not data:
                os._exit(255)
            buf += data
            while len(buf) >= 5:
                t, n = buf[:1], struct.unpack(">I", buf[1:5])[0]
                if t not in EMACS_TYPES:
                    protocol_error("unknown frame type %r" % t)
                if n > MAX_FRAME:
                    protocol_error("frame length %d exceeds limit" % n)
                if len(buf) < 5 + n:
                    break
                payload, buf = buf[5:5 + n], buf[5 + n:]
                if t == b"O":
                    os.write(1, payload)
                elif t == b"E":
                    os.write(2, payload)
                elif t == b"X":
                    try:
                        code = int(payload) & 0xFF
                    except ValueError:
                        protocol_error("non-numeric exit status")
                    os._exit(code)


if __name__ == "__main__":
    main()
