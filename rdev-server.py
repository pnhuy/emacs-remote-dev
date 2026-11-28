#!/usr/bin/env python3
"""rdev-server: headless remote-development server for Emacs.

Speaks JSON-RPC 2.0 with LSP-style Content-Length framing (so Emacs can
use the built-in jsonrpc.el).  One connection multiplexes everything:
filesystem operations, synchronous command execution, streaming
processes (pipes or PTYs), and project file listing.

Transports:
  --stdio                     one session on stdin/stdout (bootstrapped over ssh)
  --listen HOST:PORT --token T  long-running daemon, token-authenticated TCP

Pure standard library, Python >= 3.8.
"""

import argparse
import base64
import errno
import fcntl
import fnmatch
import grp
import hmac
import json
import os
import pty
import pwd
import queue
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import threading
import zlib
import time

VERSION = "0.1.0"
# --- orphan guard -----------------------------------------------------------
# If the agent is killed with SIGKILL it cannot clean up, and every child runs in
# its own session, so nothing else would stop them.  A tiny watchdog process holds
# the read end of a pipe; the agent reports each child's process group as it is
# started ("+PGID") and reaped ("-PGID").  When the agent dies, however it dies,
# the pipe reaches EOF and the watchdog kills the groups still listed.
_guard = {"fd": None, "lock": threading.Lock(), "pid": None}


def _watchdog(rfd):
    os.setsid()
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    live = set()
    buf = b""
    while True:
        try:
            d = os.read(rfd, 4096)
        except OSError:
            d = b""
        if not d:
            break
        buf += d
        *lines, buf = buf.split(b"\n")
        for ln in lines:
            try:
                n = int(ln[1:])
            except ValueError:
                continue
            (live.add if ln[:1] == b"+" else live.discard)(n)
    for n in live:
        try:
            os.killpg(n, signal.SIGKILL)
        except OSError:
            pass
    os._exit(0)


def _guard_note(op, pgid):
    with _guard["lock"]:
        if _guard["fd"] is None:
            try:
                r, w = os.pipe()
                pid = os.fork()
            except OSError:
                _guard["fd"] = -1
                return
            if pid == 0:
                try:
                    os.closerange(0, r)       # drop the agent's stdio and sockets
                    os.closerange(r + 1, 4096)
                    _watchdog(r)
                finally:
                    os._exit(1)
            os.close(r)
            fcntl.fcntl(w, fcntl.F_SETFD, fcntl.FD_CLOEXEC)
            _guard["fd"], _guard["pid"] = w, pid
            # No reaper thread: the watchdog only exits once this process has.
        if _guard["fd"] < 0:
            return
        try:
            os.write(_guard["fd"], b"%s%d\n" % (op, pgid))
        except OSError:
            pass


class GuardedPopen(subprocess.Popen):
    """Popen whose process group is killed if the agent itself dies."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        _guard_note(b"+", self.pid)

    def wait(self, *a, **kw):
        rc = super().wait(*a, **kw)
        if not getattr(self, "_guard_done", False):
            self._guard_done = True
            _guard_note(b"-", self.pid)
        return rc


READDIR_COMPRESS_MIN = 32   # fewer entries are not worth compressing
CHUNK = 65536
MAX_CHUNK = 4 * 1024 * 1024        # per fs/readChunk|writeChunk payload
MAX_TRANSFER = 4 * 1024 ** 3        # per beginWrite session
MAX_STAT_MANY = 4096                # paths per fs/statMany
OUT_QUEUE_BYTES = 1024 * 1024       # per-process unsent output bound (R7)
DRAIN_GRACE = 10.0                  # seconds to drain after the group is dead
IDLE_ABANDON = 2.0                  # exited child, group alive, no output
EXEC_MAX_OUTPUT = 16 * 1024 * 1024  # exec/run stdout+stderr cap (raw bytes)
DEFAULT_WORKERS = 8
GREP_BATCH = 100                    # matches per search/result notification
GREP_BATCH_SECS = 0.05
GREP_MAX_FILE = 32 * 1024 * 1024    # python engine skips larger files
GREP_SKIP_DIRS = {".git", ".hg", ".svn", "node_modules", "__pycache__"}
MAX_TRANSFERS = 8                   # concurrent open writes per session
TRANSFER_IDLE = 120.0               # seconds before an idle write is aborted
MAX_HEADER = 8192
MAX_HEADER_LINES = 32
MAX_MESSAGE = 33554432
MAX_AUTH_FAILURES = 5
_GLOBAL_AUTH_FAILURES = 0  # process-wide, for reconnect backoff
PROJECT_MAX_FILES = 1000000
VCS_MARKERS = {".git": "git", ".hg": "hg", ".svn": "svn"}
PROJECT_MARKERS = (".git", ".hg", ".svn", "pyproject.toml", "package.json",
                   "Cargo.toml", "go.mod", "Makefile", "CMakeLists.txt",
                   ".project", ".projectile")


PROTOCOL = "1.1"
# Only capabilities actually implemented may be advertised.
CAPABILITIES = ("fs.writeAtomic", "fs.chunk", "fs.statMany", "cancel",
                "proc.ownership", "session.shutdown", "search.grep",
                "watch", "project.root", "fs.readdirZ")


def agent_hash():
    import hashlib
    try:
        with open(os.path.abspath(__file__), "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def b64(data):
    return base64.b64encode(data).decode("ascii")


def unb64(s):
    return base64.b64decode(s) if s else b""


class RpcError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def _is_arg_error(fn, params, exc):
    """True if TypeError came from binding params, not from inside fn."""
    import inspect
    try:
        inspect.signature(fn).bind(**params)
    except TypeError:
        return True
    return False


def os_error(e):
    return RpcError(-32001, e.strerror or str(e),
                    {"errno": errno.errorcode.get(e.errno, str(e.errno)),
                     "filename": getattr(e, "filename", None)})


_uname, _gname = {}, {}


def user_name(uid):
    if uid not in _uname:
        try:
            _uname[uid] = pwd.getpwuid(uid).pw_name
        except KeyError:
            _uname[uid] = str(uid)
    return _uname[uid]


def group_name(gid):
    if gid not in _gname:
        try:
            _gname[gid] = grp.getgrgid(gid).gr_name
        except KeyError:
            _gname[gid] = str(gid)
    return _gname[gid]


def version_of(st):
    """FileVersion: identity + change markers of a stat result (R-07)."""
    return {"mtime": st.st_mtime_ns, "size": st.st_size,
            "ino": st.st_ino, "dev": st.st_dev}


def version_check(st, expected, force, create, path):
    """Shared optimistic-concurrency check for atomic writes (R3)."""
    if st is None:
        if expected is not None and not force:
            raise RpcError(-32010, "file was deleted since it was read",
                           {"current": None})
        if not create:
            raise RpcError(-32001, "No such file or directory",
                           {"errno": "ENOENT", "filename": path})
    elif expected is not None and not force:
        if not isinstance(expected, dict) or any(
                expected.get(k) != v for k, v in version_of(st).items()):
            raise RpcError(-32010, "file changed since it was read",
                           {"current": version_of(st)})


def stat_dict(path, st=None):
    """lstat-based attributes plus follow-symlink type and access bits."""
    if st is None:
        st = os.lstat(path)
    mode = st.st_mode
    if stat.S_ISLNK(mode):
        kind = "symlink"
        try:
            target = os.readlink(path)
        except OSError:
            target = ""
        try:
            fst = os.stat(path)
            ftype = "dir" if stat.S_ISDIR(fst.st_mode) else (
                "file" if stat.S_ISREG(fst.st_mode) else "other")
        except OSError:
            ftype = None  # dangling
    else:
        target = None
        kind = ftype = ("dir" if stat.S_ISDIR(mode) else
                        "file" if stat.S_ISREG(mode) else "other")
    return {
        "type": kind, "ftype": ftype, "target": target,
        "nlink": st.st_nlink, "uid": st.st_uid, "gid": st.st_gid,
        "user": user_name(st.st_uid), "group": group_name(st.st_gid),
        "atime": st.st_atime_ns, "mtime": st.st_mtime_ns,
        "ctime": st.st_ctime_ns, "size": st.st_size,
        "mode": stat.S_IMODE(mode), "modestr": stat.filemode(mode),
        "ino": st.st_ino, "dev": st.st_dev, "version": version_of(st),
        "r": os.access(path, os.R_OK), "w": os.access(path, os.W_OK),
        "x": os.access(path, os.X_OK),
    }


class Proc:
    """A streaming child process (pipe or pty)."""

    def __init__(self, session, pid_id, params):
        self.s, self.id = session, pid_id
        cmd = params["cmd"]
        cwd = params.get("cwd") or None
        env = dict(os.environ)
        env.update(params.get("env") or {})
        # Ownership (FR-021): owned processes die with the session, SIGHUP
        # first and SIGKILL after grace_ms.
        self.owned = params.get("owned", True) is not False
        grace = params.get("grace_ms", 2000)
        self.grace_ms = grace if isinstance(grace, (int, float)) \
            and not isinstance(grace, bool) and 0 <= grace <= 60000 else 2000
        self.pty = bool(params.get("pty"))
        self.merge = bool(params.get("mergeStderr", True))
        self.master = None
        if self.pty:
            env.setdefault("TERM", "dumb")
            master, slave = pty.openpty()
            rows, cols = params.get("rows") or 24, params.get("cols") or 80
            fcntl.ioctl(master, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, cols, 0, 0))
            # Like Emacs's own ptys: no echo (comint already shows the input).
            attrs = termios.tcgetattr(slave)
            attrs[3] &= ~termios.ECHO
            termios.tcsetattr(slave, termios.TCSANOW, attrs)

            def setup():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            self.p = GuardedPopen(cmd, cwd=cwd, env=env, stdin=slave,
                                      stdout=slave, stderr=slave,
                                      preexec_fn=setup, close_fds=True)
            os.close(slave)
            self.master = master
            readers = [(master, "out")]
        else:
            self.p = GuardedPopen(
                cmd, cwd=cwd, env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if self.merge else subprocess.PIPE,
                start_new_session=True, close_fds=True)
            readers = [(self.p.stdout.fileno(), "out")]
            if not self.merge:
                readers.append((self.p.stderr.fileno(), "err"))
        # Register before the pump/reap threads start so a fast-exiting
        # child cannot pop an entry that was never added (T010).
        with self.s.plock:
            self.s.procs[self.id] = self
        # Output path (R7): pumps -> bounded queue -> single sender thread.
        # A full queue blocks the pumps, so the child blocks on its pipe:
        # that is the backpressure.  One sender keeps out->exit ordering.
        self.q = queue.Queue(maxsize=max(1, OUT_QUEUE_BYTES // CHUNK))
        self.abandon = False
        self.last_read = time.time()
        self.threads = [threading.Thread(target=self._pump, args=r, daemon=True)
                        for r in readers]
        self.sender = threading.Thread(target=self._send_loop, daemon=True)
        self.sender.start()
        for t in self.threads:
            t.start()
        threading.Thread(target=self._reap, daemon=True).start()

    def _pump(self, fd, stream):
        while True:
            try:
                data = os.read(fd, CHUNK)
            except OSError:  # EIO on pty when child exits
                break
            if not data:
                break
            self.last_read = time.time()
            while not self.abandon:
                try:
                    self.q.put((stream, data), timeout=0.1)
                    break
                except queue.Full:
                    continue
            if self.abandon:
                break

    def _send_loop(self):
        while True:
            item = self.q.get()
            if item is None:
                return
            stream, data = item
            self.s.notify("proc/out", {"id": self.id, "stream": stream,
                                       "data": b64(data)})

    def _group_alive(self):
        try:
            os.killpg(self.p.pid, 0)  # pgid == pid (setsid / new session)
            return True
        except ProcessLookupError:
            return False
        except OSError:
            return True

    def _reap(self):
        code = self.p.wait()
        # Drain: wait until both pumps hit EOF.  Give up 10 s after the
        # process group is gone, or after IDLE_ABANDON of silence while a
        # surviving descendant holds the pipe open (T075).
        dead_at = None
        t0 = time.time()
        while any(t.is_alive() for t in self.threads):
            for t in self.threads:
                t.join(timeout=0.05)
            now = time.time()
            if not self._group_alive():
                dead_at = dead_at or now
                if now - dead_at > DRAIN_GRACE:
                    break
            elif (now - max(self.last_read, t0) > IDLE_ABANDON
                  and self.q.empty()):
                break
        pumps_alive = any(t.is_alive() for t in self.threads)
        truncated = pumps_alive and not self.q.empty()
        if pumps_alive:
            self.abandon = True
        try:
            self.q.put(None, timeout=DRAIN_GRACE)
        except queue.Full:
            truncated = True  # client stopped reading; sender is wedged
        self.sender.join(timeout=DRAIN_GRACE + 5)
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
        sig = -code if code < 0 else None
        params = {"id": self.id, "code": 128 + sig if sig else code,
                  "signal": sig}
        if truncated:
            params["truncated"] = True
        self.s.notify("proc/exit", params)
        with self.s.plock:
            self.s.procs.pop(self.id, None)

    def write(self, data):
        if self.master is not None:
            os.write(self.master, data)
        elif self.p.stdin:
            self.p.stdin.write(data)
            self.p.stdin.flush()

    def close_stdin(self):
        if self.master is not None:
            os.write(self.master, b"\x04")  # EOF char
        elif self.p.stdin:
            self.p.stdin.close()

    def signal(self, sig):
        try:
            if self.master is not None:
                pgrp = os.tcgetpgrp(self.master)  # foreground job
            else:
                pgrp = os.getpgid(self.p.pid)
            os.killpg(pgrp, sig)
        except OSError:
            try:
                self.p.send_signal(sig)
            except OSError:
                pass

    def kill_group(self):
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except OSError:
            pass

    def resize(self, rows, cols):
        if self.master is not None:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, cols, 0, 0))


_PATH_PARAMS = ("path", "src", "dst", "link", "target", "root")


def _validate_fs_params(params):
    """Reject malformed filesystem params with -32602 (T045, FR-035).

    Paths must be strings without NUL bytes; mode must be an int and
    mtime_ns an int (bool is not accepted).  Relative paths stay accepted
    (resolved against the agent's cwd) to preserve existing behaviour.
    """
    for key in _PATH_PARAMS:
        if key in params:
            v = params[key]
            if not isinstance(v, str):
                raise RpcError(-32602, "invalid params: %s must be a string" % key)
            if "\0" in v:
                raise RpcError(-32602, "invalid params: %s contains a NUL byte" % key)
            if v == "" and key != "target":
                raise RpcError(-32602, "invalid params: %s is empty" % key)
    if "paths" in params:
        ps = params["paths"]
        if not isinstance(ps, list):
            raise RpcError(-32602, "invalid params: paths must be an array")
        if len(ps) > MAX_STAT_MANY:
            raise RpcError(-32011, "too many paths", {"max": MAX_STAT_MANY})
        for v in ps:
            if not isinstance(v, str) or v == "" or "\0" in v:
                raise RpcError(-32602, "invalid params: paths must be non-empty "
                               "strings without NUL bytes")
    for key in ("mode", "mtime_ns"):
        if params.get(key) is not None:
            v = params[key]
            if isinstance(v, bool) or not isinstance(v, int):
                raise RpcError(-32602, "invalid params: %s must be an integer" % key)


class FramingError(Exception):
    def __init__(self, code, message, fatal=False):
        super().__init__(message)
        self.code, self.message, self.fatal = code, message, fatal


class _GrepOut:
    """Collects search matches: batches notifications, enforces max_results."""

    def __init__(self, session, mid, stream, max_results):
        self.s, self.mid, self.stream = session, mid, stream
        self.max, self.count, self.truncated = max_results, 0, False
        self.buf, self.kept, self.last = [], [], time.time()

    def add(self, path, line, col, text, subs, is_context):
        """Record one line.  Returns False once the result limit is hit."""
        if not is_context:
            if self.count >= self.max:
                self.truncated = True
                return False
            self.count += 1
        m = {"path": path, "line": line, "col": col, "text": text,
             "submatches": subs}
        if is_context:
            m["context"] = True
        (self.buf if self.stream else self.kept).append(m)
        if self.stream and (len(self.buf) >= GREP_BATCH
                            or time.time() - self.last >= GREP_BATCH_SECS):
            self.flush()
        if not is_context and self.count >= self.max:
            # limit reached; the next real match (if any) marks truncation
            return True
        return True

    def flush(self):
        if self.buf and self.mid is not None:
            self.s.notify("search/result", {"id": self.mid, "matches": self.buf})
        self.buf = []
        self.last = time.time()


class WorkerPool:
    """Bounded pool of daemon threads for slow requests (T076).

    Work beyond ``n`` concurrent tasks queues instead of spawning threads,
    so a request flood cannot exhaust threads (Article V).
    """

    def __init__(self, n):
        self.n, self.q = max(1, int(n)), queue.Queue()
        self.lock = threading.Lock()
        self.threads = self.idle = 0

    def submit(self, fn, *args):
        with self.lock:
            self.q.put((fn, args))
            # Spawn only when every currently-blocked worker is already
            # spoken for by queued work.
            if self.idle < self.q.qsize() and self.threads < self.n:
                self.threads += 1
                threading.Thread(target=self._work, daemon=True).start()

    def close(self):
        """Let idle workers exit; running tasks finish on their own."""
        with self.lock:
            for _ in range(self.threads):
                self.q.put(None)

    def _work(self):
        while True:
            with self.lock:
                self.idle += 1
            item = self.q.get()
            with self.lock:
                self.idle -= 1
            if item is None:
                return
            fn, args = item
            try:
                fn(*args)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write("rdev-server: worker error: %r\n" % (e,))


class Cancel:
    """In-flight request handle for ``$/cancel`` (R8)."""

    def __init__(self):
        self.cancelled = False
        self.proc = None
        self.lock = threading.Lock()

    def cancel(self):
        with self.lock:
            self.cancelled = True
            p = self.proc
        if p is not None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass


# --- file watching (T047, FR-017) --------------------------------------------
# A WatchBackend isolates the platform-specific part (Article VI): add() starts
# watching a path and returns a backend token, remove() stops it, poll() waits
# up to `timeout` seconds and returns [(token, kind, path), ...] where kind is
# "created", "changed" or "deleted".  Backends are chosen in order inotify
# (Linux, ctypes), kqueue (BSD/macOS), polling (anywhere).

MAX_WATCHES = 256
WATCH_POLL_INTERVAL = 0.5


def _snapshot(path):
    """Cheap fingerprint of PATH: {name: (mtime_ns, size, ino)}; a file maps
    its own name; a missing path is an empty snapshot."""
    try:
        st = os.lstat(path)
    except OSError:
        return {}
    if not stat.S_ISDIR(st.st_mode):
        return {"": (st.st_mtime_ns, st.st_size, st.st_ino)}
    out = {}
    try:
        with os.scandir(path) as it:
            for e in it:
                try:
                    es = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                out[e.name] = (es.st_mtime_ns, es.st_size, es.st_ino)
    except OSError:
        pass
    return out


def _diff(path, old, new):
    ev = []
    for name, sig in new.items():
        full = os.path.join(path, name) if name else path
        if name not in old:
            ev.append(("created", full))
        elif old[name] != sig:
            ev.append(("changed", full))
    for name in old:
        if name not in new:
            ev.append(("deleted", os.path.join(path, name) if name else path))
    return ev


class WatchBackend:
    name = "base"

    def add(self, path):
        raise NotImplementedError

    def remove(self, token):
        raise NotImplementedError

    def poll(self, timeout):
        raise NotImplementedError

    def close(self):
        pass


class PollBackend(WatchBackend):
    """Portable fallback: compare directory snapshots every interval."""
    name = "poll"

    def __init__(self, interval=WATCH_POLL_INTERVAL):
        self.interval = interval
        self.watches = {}           # token -> (path, snapshot)
        self.next = 1
        self.lock = threading.Lock()
        self.last = 0.0

    def add(self, path):
        os.lstat(path)              # raises OSError for a missing path
        with self.lock:
            tok = self.next
            self.next += 1
            self.watches[tok] = (path, _snapshot(path))
        return tok

    def remove(self, token):
        with self.lock:
            self.watches.pop(token, None)

    def poll(self, timeout):
        wait = max(0.0, self.last + self.interval - time.time())
        time.sleep(min(wait, timeout))
        if time.time() < self.last + self.interval:
            return []
        self.last = time.time()
        out = []
        with self.lock:
            items = list(self.watches.items())
        for tok, (path, old) in items:
            new = _snapshot(path)
            for kind, full in _diff(path, old, new):
                out.append((tok, kind, full))
            with self.lock:
                if tok in self.watches:
                    self.watches[tok] = (path, new)
        return out


class InotifyBackend(WatchBackend):
    name = "inotify"
    _MASK = (0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800)

    def __init__(self):
        import ctypes
        import ctypes.util
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6",
                           use_errno=True)
        self._libc, self._ct = libc, ctypes
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.paths = {}             # wd -> path
        self.lock = threading.Lock()

    def add(self, path):
        wd = self._libc.inotify_add_watch(self.fd, os.fsencode(path), self._MASK)
        if wd < 0:
            e = self._ct.get_errno()
            raise OSError(e, os.strerror(e), path)
        with self.lock:
            self.paths[wd] = path
        return wd

    def remove(self, token):
        with self.lock:
            self.paths.pop(token, None)
        self._libc.inotify_rm_watch(self.fd, token)

    def poll(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return []
        try:
            buf = os.read(self.fd, 65536)
        except BlockingIOError:
            return []
        out, i = [], 0
        while i + 16 <= len(buf):
            wd, mask, _cookie, ln = struct.unpack_from("iIII", buf, i)
            name = buf[i + 16:i + 16 + ln].split(b"\0", 1)[0]
            i += 16 + ln
            with self.lock:
                base = self.paths.get(wd)
            if base is None or mask & 0x8000:      # IN_IGNORED
                continue
            full = os.path.join(base, os.fsdecode(name)) if name else base
            if mask & (0x100 | 0x80):
                kind = "created"
            elif mask & (0x200 | 0x40 | 0x400 | 0x800):
                kind = "deleted"
            else:
                kind = "changed"
            out.append((wd, kind, full))
        return out

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


class KqueueBackend(WatchBackend):
    """kqueue reports that a directory changed, not what changed, so each
    wake-up is resolved with a snapshot diff (same helper as PollBackend)."""
    name = "kqueue"

    def __init__(self):
        self.kq = select.kqueue()
        self.last_scan = 0.0
        self.watches = {}           # fd -> (path, snapshot)
        self.lock = threading.Lock()

    def add(self, path):
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_EVTONLY", 0))
        flags = (select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE |
                 select.KQ_NOTE_RENAME | select.KQ_NOTE_ATTRIB |
                 select.KQ_NOTE_EXTEND)
        ev = select.kevent(fd, select.KQ_FILTER_VNODE,
                           select.KQ_EV_ADD | select.KQ_EV_CLEAR, flags)
        try:
            self.kq.control([ev], 0, 0)
        except OSError:
            os.close(fd)
            raise
        with self.lock:
            self.watches[fd] = (path, _snapshot(path))
        return fd

    def remove(self, token):
        with self.lock:
            self.watches.pop(token, None)
        try:
            os.close(token)
        except OSError:
            pass

    def poll(self, timeout):
        # A directory's vnode only fires for entry changes (create, delete,
        # rename), not for in-place writes to existing files, so every wake-up
        # and a slow periodic rescan both resolve through the snapshot diff.
        try:
            evs = self.kq.control(None, 64, timeout)
        except (OSError, ValueError):
            evs = []
        now = time.time()
        woke = {e.ident for e in evs}
        if now - self.last_scan >= WATCH_POLL_INTERVAL * 2:
            self.last_scan = now
            with self.lock:
                woke = set(self.watches)
        out = []
        for ident in woke:
            with self.lock:
                w = self.watches.get(ident)
            if w is None:
                continue
            path, old = w
            new = _snapshot(path)
            for kind, full in _diff(path, old, new):
                out.append((ident, kind, full))
            with self.lock:
                if ident in self.watches:
                    self.watches[ident] = (path, new)
        return out

    def close(self):
        with self.lock:
            fds = list(self.watches)
        for fd in fds:
            self.remove(fd)
        self.kq.close()


def make_watch_backend(prefer=None):
    """First working backend; RDEV_WATCH_BACKEND (or PREFER) forces one."""
    prefer = prefer or os.environ.get("RDEV_WATCH_BACKEND")
    order = {"inotify": [InotifyBackend], "kqueue": [KqueueBackend],
             "poll": [PollBackend]}.get(
        prefer, [InotifyBackend, KqueueBackend, PollBackend])
    for cls in order:
        try:
            if cls is InotifyBackend and not sys.platform.startswith("linux"):
                continue
            if cls is KqueueBackend and not hasattr(select, "kqueue"):
                continue
            return cls()
        except (OSError, ImportError, AttributeError):
            continue
    return PollBackend()


class Session:
    def __init__(self, rfile, wfile, token=None, max_message=MAX_MESSAGE,
                 workers=DEFAULT_WORKERS):
        self.r, self.w = rfile, wfile
        self.max_message = max_message
        self.wlock = threading.Lock()
        self.auth_failures = 0
        self.closing = False
        self.plock = threading.Lock()  # guards procs and next_id
        self.procs = {}
        self.next_id = 1
        self.xfers = {}                # tid -> open chunked write
        self.xlock = threading.Lock()
        self.pool = WorkerPool(workers)
        self.inflight = {}             # request id -> Cancel
        self.ilock = threading.Lock()
        self.tl = threading.local()
        self.authed = token is None
        self.token = token
        self.wlock2 = threading.Lock()   # guards the watch table
        self.watch_backend = None        # created on first watch/add
        self.watch_thread = None
        self.watches = {}                # id -> (backend token, path)
        self.next_watch = 1
        self.watch_stop = threading.Event()

    # --- framing -------------------------------------------------------
    def send(self, msg):
        body = json.dumps(msg, separators=(",", ":")).encode("utf-8")
        with self.wlock:
            self.w.write(b"Content-Length: %d\r\n\r\n" % len(body))
            self.w.write(body)
            self.w.flush()

    def notify(self, method, params):
        try:
            self.send({"jsonrpc": "2.0", "method": method, "params": params})
        except (BrokenPipeError, OSError, ValueError):
            pass

    def read_message(self):
        """Read one framed message.

        Returns a dict, or None at EOF.  Raises FramingError for malformed
        input; ``fatal`` errors mean stream sync is lost and the session
        must close.  Header and body sizes are bounded (Article IV).
        """
        length, nbytes, nlines = None, 0, 0
        while True:
            line = self.r.readline(MAX_HEADER + 1)
            if not line:
                return None
            nbytes += len(line)
            nlines += 1
            if nbytes > MAX_HEADER or nlines > MAX_HEADER_LINES:
                raise FramingError(-32600, "header too large", fatal=True)
            line = line.strip()
            if not line:
                break
            k, _, v = line.partition(b":")
            if k.strip().lower() == b"content-length":
                v = v.strip()
                if not v.isdigit() or len(v) > 12:
                    length = -1
                else:
                    length = int(v)
        if length is None or length < 0:
            raise FramingError(-32600, "missing or invalid Content-Length")
        if length > self.max_message:
            raise FramingError(-32600, "message exceeds %d bytes" %
                               self.max_message, fatal=True)
        body = self.r.read(length)
        if len(body) < length:
            return None
        try:
            msg = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise FramingError(-32700, "parse error")
        if not isinstance(msg, dict):
            raise FramingError(-32600, "message must be a JSON object")
        return msg

    # --- dispatch ------------------------------------------------------
    def serve(self):
        try:
            while True:
                try:
                    msg = self.read_message()
                except FramingError as e:
                    self._send_error(None, e.code, e.message)
                    if e.fatal:
                        sys.stderr.write("rdev-server: closing: %s\n" % e.message)
                        break
                    continue
                except (OSError, ValueError):
                    break
                if msg is None:
                    break
                if "method" not in msg:
                    continue  # responses to our (non-existent) requests
                if not isinstance(msg["method"], str):
                    self._send_error(msg.get("id"), -32600, "method must be a string")
                    continue
                # Process requests in order on one thread except the slow,
                # streaming-friendly ones, which get their own thread.
                if msg["method"] == "$/cancel":
                    self._cancel(msg.get("params"))
                elif msg["method"] in ("exec/run", "project/files",
                                       "search/grep"):
                    mid = msg.get("id")
                    if mid is not None and isinstance(mid, (int, str)):
                        with self.ilock:
                            self.inflight[mid] = Cancel()
                    self.pool.submit(self.handle, msg)
                else:
                    self.handle(msg)
                if self.closing:
                    break
        except Exception as e:  # noqa: BLE001  never escape serve()
            sys.stderr.write("rdev-server: session error: %r\n" % (e,))
        finally:
            self._close_watches()
            self._terminate_owned()
            self._abort_all_transfers()
            self.pool.close()

    def _terminate_owned(self, grace_ms=None):
        """SIGHUP every owned process group, SIGKILL survivors after the grace
        period.  Returns the number of processes that were targeted."""
        with self.plock:
            procs = [p for p in self.procs.values() if p.owned]
        for p in procs:
            p.signal(signal.SIGHUP)
        grace = max([(p.grace_ms if grace_ms is None else grace_ms)
                     for p in procs] or [0]) / 1000.0
        deadline = time.time() + grace
        while time.time() < deadline and any(p._group_alive() for p in procs):
            time.sleep(0.02)
        for p in procs:
            if p._group_alive():
                p.kill_group()
        return len(procs)

    def m_session_shutdown(self, grace_ms=None):
        if grace_ms is not None and (isinstance(grace_ms, bool)
                                     or not isinstance(grace_ms, (int, float))
                                     or not 0 <= grace_ms <= 60000):
            raise RpcError(-32602, "invalid params: grace_ms must be 0..60000")
        n = self._terminate_owned(grace_ms)
        self.closing = True
        return {"terminated": n}

    def _cancel(self, params):
        """``$/cancel {id}``: unknown or finished ids are ignored."""
        mid = params.get("id") if isinstance(params, dict) else None
        if not isinstance(mid, (int, str)) or isinstance(mid, bool):
            return
        with self.ilock:
            c = self.inflight.get(mid)
        if c is not None:
            c.cancel()

    def _send_error(self, mid, code, message):
        try:
            self.send({"jsonrpc": "2.0", "id": mid,
                       "error": {"code": code, "message": message}})
        except (BrokenPipeError, OSError, ValueError):
            pass

    def handle(self, msg):
        try:
            self._handle(msg)
        finally:
            mid = msg.get("id")
            if isinstance(mid, (int, str)):
                with self.ilock:
                    self.inflight.pop(mid, None)

    def _handle(self, msg):
        mid, method = msg.get("id"), msg["method"]
        self.tl.cancel = None
        self.tl.mid = mid
        try:
            if not self.authed and method != "auth":
                raise RpcError(-32002, "not authenticated")
            fn = getattr(self, "m_" + method.replace("/", "_"), None)
            if fn is None:
                raise RpcError(-32601, "method not found: " + method)
            params = msg.get("params") or {}
            if not isinstance(params, dict):
                raise RpcError(-32602, "params must be an object")
            if method.startswith("fs/") or method == "watch/add" or method in ("project/files",
                                                      "project/root",
                                                      "search/grep"):
                _validate_fs_params(params)
            try:
                with self.ilock:
                    c = self.inflight.get(mid) if mid is not None else None
                if c is not None and c.cancelled:
                    raise RpcError(-32800, "request cancelled")
                self.tl.cancel = c
                result = fn(**params)
            except TypeError as e:
                if _is_arg_error(fn, params, e):
                    raise RpcError(-32602, "invalid params: %s" % e)
                raise
            if mid is not None:
                self.send({"jsonrpc": "2.0", "id": mid, "result": result})
        except RpcError as e:
            if mid is not None:
                err = {"code": e.code, "message": e.message}
                if e.data is not None:
                    err["data"] = e.data
                self.send({"jsonrpc": "2.0", "id": mid, "error": err})
        except OSError as e:
            if mid is not None:
                e2 = os_error(e)
                self.send({"jsonrpc": "2.0", "id": mid, "error":
                           {"code": e2.code, "message": e2.message,
                            "data": e2.data}})
        except Exception as e:  # noqa: BLE001
            if mid is not None:
                self.send({"jsonrpc": "2.0", "id": mid, "error":
                           {"code": -32603, "message": "%s: %s" %
                            (type(e).__name__, e)}})

    # --- methods: session ---------------------------------------------
    def m_auth(self, token):
        if self.token is not None and not hmac.compare_digest(
                str(token).encode("utf-8", "surrogatepass"),
                self.token.encode("utf-8", "surrogatepass")):
            self.auth_failures += 1
            global _GLOBAL_AUTH_FAILURES
            _GLOBAL_AUTH_FAILURES += 1
            if _GLOBAL_AUTH_FAILURES > MAX_AUTH_FAILURES:
                # Reconnecting must not reset the guess budget: back off.
                time.sleep(min(2.0, 0.1 * (_GLOBAL_AUTH_FAILURES - MAX_AUTH_FAILURES)))
            if self.auth_failures >= MAX_AUTH_FAILURES:
                self.closing = True  # serve() drops the connection
            raise RpcError(-32002, "bad token")
        self.authed = True
        return True

    def m_hello(self, client=None):
        """Handshake.  Zero-param calls (legacy clients) stay valid; the
        added fields are purely additive (protocol.md, T011)."""
        return {"version": VERSION, "home": os.path.expanduser("~"),
                "user": user_name(os.getuid()), "uid": os.getuid(),
                "host": socket.gethostname(),
                "path": os.environ.get("PATH", "").split(":"),
                "python": sys.version.split()[0],
                "protocol": PROTOCOL,
                "capabilities": list(CAPABILITIES),
                "limits": {"max_message": self.max_message,
                           "max_header": MAX_HEADER, "chunk": CHUNK,
                           "max_chunk": MAX_CHUNK,
                           "max_transfer": MAX_TRANSFER},
                "agent_hash": agent_hash(),
                "platform": sys.platform}


    # --- methods: watch (T047, FR-017) ------------------------------------
    def m_watch_add(self, path):
        with self.wlock2:
            if len(self.watches) >= MAX_WATCHES:
                raise RpcError(-32011, "too many watches", {"max": MAX_WATCHES})
            if self.watch_backend is None:
                self.watch_backend = make_watch_backend()
                self.watch_thread = threading.Thread(
                    target=self._watch_loop, name="rdev-watch", daemon=True)
                self.watch_thread.start()
            tok = self.watch_backend.add(path)
            wid = self.next_watch
            self.next_watch += 1
            self.watches[wid] = (tok, path)
            return {"id": wid, "backend": self.watch_backend.name}

    def m_watch_remove(self, id):
        if isinstance(id, bool) or not isinstance(id, int):
            raise RpcError(-32602, "invalid params: id must be an integer")
        with self.wlock2:
            w = self.watches.pop(id, None)
            if w is not None:
                self.watch_backend.remove(w[0])
        return {"removed": w is not None}

    def _watch_loop(self):
        be = self.watch_backend
        while not self.watch_stop.is_set():
            try:
                raw = be.poll(0.2)
            except Exception:  # noqa: BLE001  a backend failure must not kill the agent
                time.sleep(0.2)
                continue
            if not raw:
                continue
            with self.wlock2:
                by_id = {tok: wid for wid, (tok, _p) in self.watches.items()}
            grouped, seen = {}, set()
            for tok, kind, full in raw:
                wid = by_id.get(tok)
                if wid is None or (wid, kind, full) in seen:
                    continue
                seen.add((wid, kind, full))
                grouped.setdefault(wid, []).append({"kind": kind, "path": full})
            for wid, events in grouped.items():
                self.notify("watch/event", {"id": wid, "events": events})

    def _close_watches(self):
        self.watch_stop.set()
        t = self.watch_thread
        if t is not None:
            t.join(timeout=2)
        with self.wlock2:
            be, self.watch_backend = self.watch_backend, None
            self.watches.clear()
        if be is not None:
            be.close()

    # --- methods: filesystem ------------------------------------------
    def m_fs_stat(self, path):
        try:
            return stat_dict(path)
        except FileNotFoundError:
            return None
        except NotADirectoryError:
            return None

    def m_fs_statMany(self, paths):
        """Stat PATHS in one round trip; a failing path reports its own error."""
        out = []
        for p in paths:
            try:
                out.append({"path": p, "stat": self.m_fs_stat(p)})
            except OSError as e:
                out.append({"path": p, "error": {
                    "errno": errno.errorcode.get(e.errno, str(e.errno)),
                    "message": e.strerror or str(e)}})
        return {"results": out}

    def m_fs_readdir(self, path, attrs=False, compress=False):
        if not isinstance(compress, bool):
            raise RpcError(-32602, "compress must be a boolean")
        out = []
        with os.scandir(path) as it:
            for e in it:
                if attrs:
                    try:
                        out.append([e.name, stat_dict(e.path, e.stat(follow_symlinks=False))])
                    except OSError:
                        out.append([e.name, None])
                else:
                    try:
                        d = e.is_dir()
                    except OSError:
                        d = False
                    out.append([e.name, d])
        if compress and len(out) >= READDIR_COMPRESS_MIN:
            # Slow links: an attribute listing is ~400 bytes/entry of very
            # repetitive JSON; zlib shrinks it by an order of magnitude.
            raw = json.dumps(out, separators=(",", ":")).encode("utf-8")
            return {"z": b64(zlib.compress(raw, 6))}
        return out

    def m_fs_read(self, path):
        with open(path, "rb") as f:
            st = os.fstat(f.fileno())      # version from the same open fd
            data = f.read()
        return {"data": b64(data), "mtime": st.st_mtime_ns,
                "ino": st.st_ino, "dev": st.st_dev, "version": version_of(st)}

    def m_fs_write(self, path, data, append=False, excl=False, mode=None):
        flags = os.O_WRONLY | os.O_CREAT
        flags |= os.O_APPEND if append else os.O_TRUNC
        if excl:
            flags |= os.O_EXCL
        fd = os.open(path, flags, mode if mode is not None else 0o666)
        try:
            payload = unb64(data)
            view = memoryview(payload)
            while view:
                n = os.write(fd, view)
                view = view[n:]
            st = os.fstat(fd)
        finally:
            os.close(fd)
        return {"mtime": st.st_mtime_ns, "ino": st.st_ino, "dev": st.st_dev,
                "version": version_of(st)}

    def m_fs_writeAtomic(self, path, data, expected=None, create=True,
                         mode=None, force=False, follow_symlinks=True,
                         sha256=None):
        """Version-checked whole-file replace (D-03, research R3).

        Writes a temp file in the destination directory, fsyncs it, then
        re-checks the version immediately before os.replace().  Hard-linked
        or non-regular destinations fall back to an in-place write and are
        reported with atomic=false.
        """
        import hashlib
        import uuid
        payload = unb64(data)
        if sha256 is not None and hashlib.sha256(payload).hexdigest() != sha256:
            raise RpcError(-32013, "checksum mismatch in transferred data")
        if not isinstance(path, str) or "\0" in path:
            raise RpcError(-32602, "invalid path")
        target = os.path.realpath(path) if follow_symlinks else path

        def current():
            try:
                return os.lstat(target)
            except FileNotFoundError:
                return None

        def check(st):
            version_check(st, expected, force, create, path)

        st = current()
        check(st)
        is_link = st is not None and stat.S_ISLNK(st.st_mode)

        def in_place():
            # O_NOFOLLOW: never write through a symlink we were told not
            # to follow (it is replaced atomically instead, see below).
            fd = os.open(target, os.O_WRONLY | os.O_TRUNC
                         | getattr(os, "O_NOFOLLOW", 0))
            try:
                view = memoryview(payload)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
                nst = os.fstat(fd)
            finally:
                os.close(fd)
            return {"version": version_of(nst), "atomic": False,
                    "bytes": len(payload)}

        if st is not None and not is_link and (
                not stat.S_ISREG(st.st_mode) or st.st_nlink > 1):
            # Cannot replace without breaking the link/special file.
            return in_place()
        d = os.path.dirname(target) or "."
        self._sweep_stale_tmp(d)
        if mode is not None:
            fmode = mode
        elif st is not None and not is_link:
            fmode = stat.S_IMODE(st.st_mode)
        else:
            um = os.umask(0); os.umask(um)
            fmode = 0o666 & ~um
        tmp = os.path.join(d, ".rdev-tmp-%d-%s" % (os.getpid(), uuid.uuid4().hex[:8]))
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as e:
            if (e.errno in (errno.EACCES, errno.EPERM, errno.EROFS)
                    and st is not None and not is_link):
                # Read-only directory, writable file: plain Emacs and
                # TRAMP still save; same version check, atomic=false.
                return in_place()
            raise
        try:
            try:
                view = memoryview(payload)
                while view:
                    view = view[os.write(fd, view):]
                os.fchmod(fd, fmode)
                if st is not None and not is_link:
                    try:
                        os.fchown(fd, st.st_uid, st.st_gid)
                    except OSError:
                        pass  # non-root cannot chown; keep our own ids
                os.fsync(fd)
            finally:
                os.close(fd)
            check(current())          # last check before the swap
            os.replace(tmp, target)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        try:
            dfd = os.open(d, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
        return {"version": version_of(os.lstat(target)), "atomic": True,
                "bytes": len(payload)}

    @staticmethod
    def _sweep_stale_tmp(d):
        """Remove ``.rdev-tmp-<pid>-<hex>`` left by a killed agent (dead pid,
        older than a minute).  Best effort; never raises."""
        try:
            names = os.listdir(d)
        except OSError:
            return
        now = time.time()
        for n in names:
            parts = n.split("-")
            if not (n.startswith(".rdev-tmp-") and len(parts) == 4
                    and parts[2].isdigit()):
                continue
            pid = int(parts[2])
            try:
                os.kill(pid, 0)
                continue                   # owner alive
            except ProcessLookupError:
                pass
            except OSError:
                continue
            try:
                full = os.path.join(d, n)
                if now - os.lstat(full).st_mtime > 60:
                    os.unlink(full)
            except OSError:
                pass

    # --- methods: chunked transfer (cap fs.chunk, FR-015) ---------------
    def _sweep_transfers(self):
        """Abort writes idle longer than TRANSFER_IDLE (lazy: runs per request)."""
        now = time.monotonic()
        with self.xlock:
            stale = [t for t, x in self.xfers.items()
                     if now - x["last"] > TRANSFER_IDLE]
        for tid in stale:
            self.m_fs_abortWrite(tid)

    def _abort_all_transfers(self):
        with self.xlock:
            tids = list(self.xfers)
        for tid in tids:
            self.m_fs_abortWrite(tid)

    def _xfer(self, tid):
        with self.xlock:
            x = self.xfers.get(tid)
        if x is None:
            raise RpcError(-32013, "unknown or expired transfer id")
        x["last"] = time.monotonic()
        return x

    def m_fs_readChunk(self, path, offset, length, expected=None):
        if (not isinstance(offset, int) or isinstance(offset, bool) or offset < 0
                or not isinstance(length, int) or isinstance(length, bool)
                or length < 0):
            raise RpcError(-32602, "offset/length must be non-negative integers")
        if length > MAX_CHUNK:
            raise RpcError(-32011, "length exceeds max_chunk",
                           {"max_chunk": MAX_CHUNK})
        with open(path, "rb") as f:
            st = os.fstat(f.fileno())
            ver = version_of(st)
            if expected is not None and any(
                    expected.get(k) != v for k, v in ver.items()):
                raise RpcError(-32010, "file changed during read",
                               {"current": ver})
            f.seek(offset)
            data = f.read(length)
        return {"data": b64(data), "eof": offset + len(data) >= st.st_size,
                "version": ver}

    def m_fs_beginWrite(self, path, expected=None, size=None, mode=None,
                        create=True, force=False, follow_symlinks=True):
        import hashlib
        import uuid
        self._sweep_transfers()
        if size is not None and (not isinstance(size, int) or size < 0):
            raise RpcError(-32602, "size must be a non-negative integer")
        if size is not None and size > MAX_TRANSFER:
            raise RpcError(-32011, "size exceeds max_transfer",
                           {"max_transfer": MAX_TRANSFER})
        with self.xlock:
            if len(self.xfers) >= MAX_TRANSFERS:
                raise RpcError(-32011, "too many concurrent transfers",
                               {"max": MAX_TRANSFERS})
        target = os.path.realpath(path) if follow_symlinks else path
        try:
            st = os.lstat(target)
        except FileNotFoundError:
            st = None
        version_check(st, expected, force, create, path)
        if st is not None and (not stat.S_ISREG(st.st_mode) or st.st_nlink > 1):
            raise RpcError(-32012, "destination cannot be replaced atomically; "
                           "use fs/writeAtomic", {"reason": "non-regular-or-hardlinked"})
        d = os.path.dirname(target) or "."
        tmp = os.path.join(d, ".rdev-tmp-%d-%s" % (os.getpid(), uuid.uuid4().hex[:8]))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        tid = uuid.uuid4().hex
        with self.xlock:
            self.xfers[tid] = {"fd": fd, "tmp": tmp, "target": target, "path": path,
                               "st": st, "expected": expected, "force": force,
                               "create": create, "mode": mode, "size": size,
                               "offset": 0, "hash": hashlib.sha256(),
                               "last": time.monotonic()}
        return {"tid": tid, "chunk": MAX_CHUNK}

    def m_fs_writeChunk(self, tid, offset, data):
        x = self._xfer(tid)
        payload = unb64(data)
        if len(payload) > MAX_CHUNK:
            self.m_fs_abortWrite(tid)
            raise RpcError(-32011, "chunk exceeds max_chunk", {"max_chunk": MAX_CHUNK})
        if offset != x["offset"]:
            self.m_fs_abortWrite(tid)
            raise RpcError(-32013, "non-contiguous chunk offset",
                           {"expected_offset": x["offset"], "got": offset})
        total = x["offset"] + len(payload)
        limit = MAX_TRANSFER if x["size"] is None else min(x["size"], MAX_TRANSFER)
        if total > limit:
            self.m_fs_abortWrite(tid)
            raise RpcError(-32011, "transfer exceeds declared size or max_transfer")
        view = memoryview(payload)
        try:
            while view:
                view = view[os.write(x["fd"], view):]
        except OSError:
            self.m_fs_abortWrite(tid)
            raise
        x["hash"].update(payload)
        x["offset"] = total
        return {"received": total}

    def m_fs_commitWrite(self, tid, sha256=None, size=None):
        x = self._xfer(tid)
        try:
            if size is not None and size != x["offset"]:
                raise RpcError(-32013, "size mismatch",
                               {"received": x["offset"], "declared": size})
            if x["size"] is not None and x["size"] != x["offset"]:
                raise RpcError(-32013, "size mismatch with beginWrite",
                               {"received": x["offset"], "declared": x["size"]})
            if sha256 is not None and sha256 != x["hash"].hexdigest():
                raise RpcError(-32013, "checksum mismatch in transferred data")
            st, target = x["st"], x["target"]
            if x["mode"] is not None:
                fmode = x["mode"]
            elif st is not None:
                fmode = stat.S_IMODE(st.st_mode)
            else:
                um = os.umask(0); os.umask(um)
                fmode = 0o666 & ~um
            os.fchmod(x["fd"], fmode)
            if st is not None:
                try:
                    os.fchown(x["fd"], st.st_uid, st.st_gid)
                except OSError:
                    pass
            os.fsync(x["fd"])
            try:
                cur = os.lstat(target)
            except FileNotFoundError:
                cur = None
            version_check(cur, x["expected"], x["force"], x["create"], x["path"])
            os.replace(x["tmp"], target)
            x["tmp"] = None
        except BaseException:
            self.m_fs_abortWrite(tid)
            raise
        with self.xlock:
            self.xfers.pop(tid, None)
        os.close(x["fd"])
        d = os.path.dirname(target) or "."
        try:
            dfd = os.open(d, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
        return {"version": version_of(os.lstat(target)), "atomic": True,
                "bytes": x["offset"]}

    def m_fs_abortWrite(self, tid):
        with self.xlock:
            x = self.xfers.pop(tid, None)
        if x is not None:
            try:
                os.close(x["fd"])
            except OSError:
                pass
            if x["tmp"]:
                try:
                    os.unlink(x["tmp"])
                except OSError:
                    pass
        return {}

    # --- methods: search ----------------------------------------------
    def m_search_grep(self, root, pattern, regex=False, case="smart",
                      globs=None, ignore=True, hidden=False,
                      max_results=1000, context=0, stream=True, engine=None):
        if not isinstance(pattern, str) or not pattern:
            raise RpcError(-32602, "invalid params: pattern must be a non-empty string")
        if "\0" in pattern:
            raise RpcError(-32602, "invalid params: NUL in pattern")
        if case not in ("smart", "sensitive", "insensitive"):
            raise RpcError(-32602, "invalid params: case")
        globs = globs or []
        if (not isinstance(globs, list)
                or not all(isinstance(g, str) and g and "\0" not in g
                           for g in globs)):
            raise RpcError(-32602, "invalid params: globs must be strings")
        for name, v, lo, hi in (("max_results", max_results, 1, 100000),
                                ("context", context, 0, 5)):
            if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
                raise RpcError(-32602, "invalid params: %s must be %d..%d"
                               % (name, lo, hi))
        if engine not in (None, "rg", "python"):
            raise RpcError(-32602, "invalid params: engine")
        if regex:
            try:
                re.compile(pattern)
            except re.error as ex:
                raise RpcError(-32602, "invalid regex: %s" % ex)
        if not os.path.isdir(root):
            raise OSError(errno.ENOTDIR if os.path.exists(root) else errno.ENOENT,
                          os.strerror(errno.ENOTDIR if os.path.exists(root)
                                      else errno.ENOENT), root)
        use_rg = engine == "rg" or (engine is None and shutil.which("rg"))
        if engine == "rg" and not shutil.which("rg"):
            raise RpcError(-32012, "ripgrep (rg) is not installed on the remote host")
        out = _GrepOut(self, getattr(self.tl, "mid", None), bool(stream),
                       max_results)
        cancel = getattr(self.tl, "cancel", None)
        opts = dict(root=root, pattern=pattern, regex=bool(regex), case=case,
                    globs=globs, ignore=bool(ignore), hidden=bool(hidden),
                    context=context)
        if use_rg:
            self._grep_rg(out, cancel, **opts)
            name = "rg"
        else:
            self._grep_python(out, cancel, **opts)
            name = "python"
        out.flush()
        if cancel is not None and cancel.cancelled:
            raise RpcError(-32800, "request cancelled")
        res = {"count": out.count, "truncated": out.truncated, "engine": name}
        if not stream:
            res["matches"] = out.kept
        return res

    def _grep_rg(self, out, cancel, root, pattern, regex, case, globs, ignore,
                 hidden, context):
        cmd = ["rg", "--json", "--no-config", "--no-messages",
               {"smart": "-S", "sensitive": "-s", "insensitive": "-i"}[case]]
        if not regex:
            cmd.append("-F")
        if not ignore:
            cmd.append("--no-ignore")
        if hidden:
            cmd.append("--hidden")
        if context:
            cmd += ["-C", str(context)]
        for g in globs:
            cmd += ["-g", g]
        cmd += ["-e", pattern, "--", "."]
        p = GuardedPopen(cmd, cwd=root, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
        if cancel is not None:
            with cancel.lock:
                cancel.proc = p
            if cancel.cancelled:
                cancel.cancel()
        errbuf = []
        et = threading.Thread(target=lambda: errbuf.append(p.stderr.read(65536)),
                              daemon=True)
        et.start()

        def kill():
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass

        def text(d):
            if "text" in d:
                return d["text"]
            return base64.b64decode(d.get("bytes", "")).decode("utf-8", "replace")

        try:
            for line in p.stdout:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                kind, d = ev.get("type"), ev.get("data", {})
                if kind not in ("match", "context"):
                    continue
                path = text(d["path"])
                if path.startswith("./"):
                    path = path[2:]
                body = text(d["lines"]).rstrip("\r\n")
                subs = []
                if kind == "match":
                    raw = text(d["lines"]).encode("utf-8", "replace")
                    for sm in d.get("submatches", []):
                        s0 = len(raw[:sm["start"]].decode("utf-8", "replace"))
                        e0 = len(raw[:sm["end"]].decode("utf-8", "replace"))
                        subs.append([s0, e0])
                if not out.add(path, d.get("line_number"),
                               subs[0][0] + 1 if subs else 1, body, subs,
                               kind == "context"):
                    kill()
                    break
                if cancel is not None and cancel.cancelled:
                    kill()
                    break
        finally:
            p.stdout.close()
            rc = p.wait()
            et.join(timeout=1)
        if (rc == 2 and not out.truncated
                and not (cancel is not None and cancel.cancelled)):
            msg = (errbuf[0] if errbuf else b"").decode("utf-8", "replace").strip()
            if msg and out.count == 0:
                raise RpcError(-32602, "rg: %s" % msg.splitlines()[0])

    def _grep_python(self, out, cancel, root, pattern, regex, case, globs,
                     ignore, hidden, context):
        flags = 0
        if case == "insensitive" or (case == "smart" and pattern == pattern.lower()):
            flags |= re.IGNORECASE
        rx = re.compile(pattern if regex else re.escape(pattern), flags)
        inc = [g for g in globs if not g.startswith("!")]
        exc = [g[1:] for g in globs if g.startswith("!")]

        def wanted(rel):
            base = os.path.basename(rel)
            if any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(base, g) for g in exc):
                return False
            return not inc or any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(base, g)
                                  for g in inc)

        def files():
            if ignore:
                try:
                    r = subprocess.run(
                        ["git", "ls-files", "-z", "-co", "--exclude-standard"],
                        cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        stdin=subprocess.DEVNULL)
                    if r.returncode == 0:
                        for f in r.stdout.decode("utf-8", "replace").split("\0"):
                            if f and (hidden or not any(
                                    part.startswith(".") for part in f.split("/"))):
                                yield f
                        return
                except OSError:
                    pass
            for d, dirs, fs in os.walk(root):
                dirs[:] = sorted(x for x in dirs
                                 if (hidden or not x.startswith("."))
                                 and not (ignore and x in GREP_SKIP_DIRS))
                for f in sorted(fs):
                    if hidden or not f.startswith("."):
                        yield os.path.relpath(os.path.join(d, f), root)

        for rel in files():
            if cancel is not None and cancel.cancelled:
                return
            if not wanted(rel):
                continue
            full = os.path.join(root, rel)
            try:
                if (not os.path.isfile(full)
                        or os.path.getsize(full) > GREP_MAX_FILE):
                    continue
                with open(full, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if b"\0" in data[:8192]:
                continue
            lines = data.decode("utf-8", "replace").split("\n")
            if lines and lines[-1] == "":
                lines.pop()
            emitted = -1
            for i, ln in enumerate(lines):
                ms = list(rx.finditer(ln))
                if not ms:
                    continue
                for j in range(max(emitted + 1, i - context), i):
                    if not out.add(rel, j + 1, 1, lines[j].rstrip("\r"), [], True):
                        return
                subs = [[m.start(), m.end()] for m in ms]
                if not out.add(rel, i + 1, subs[0][0] + 1, ln.rstrip("\r"), subs,
                               False):
                    return
                emitted = i
                for j in range(i + 1, min(len(lines), i + 1 + context)):
                    # trailing context is emitted lazily only if not a match
                    if rx.search(lines[j]):
                        break
                    if not out.add(rel, j + 1, 1, lines[j].rstrip("\r"), [], True):
                        return
                    emitted = j


    def m_fs_mkdir(self, path, parents=False):
        if parents:
            existed = os.path.isdir(path)
            os.makedirs(path, exist_ok=True)
            return existed
        os.mkdir(path)
        return False

    def m_fs_delete(self, path, recursive=False):
        if os.path.isdir(path) and not os.path.islink(path):
            if recursive:
                shutil.rmtree(path)
            else:
                os.rmdir(path)
        else:
            os.unlink(path)
        return True

    def m_fs_rename(self, src, dst, overwrite=True):
        if not overwrite and os.path.lexists(dst):
            raise RpcError(-32001, "File exists", {"errno": "EEXIST", "filename": dst})
        os.replace(src, dst)
        return True

    def m_fs_copy(self, src, dst, preserve=False):
        if os.path.isdir(src) and not os.path.islink(src):
            shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
        elif preserve:
            shutil.copy2(src, dst, follow_symlinks=False)
        else:
            shutil.copyfile(src, dst, follow_symlinks=True)
        return True

    def m_fs_chmod(self, path, mode, follow=True):
        os.chmod(path, mode, follow_symlinks=follow)
        return True

    def m_fs_utime(self, path, mtime_ns, follow=True):
        os.utime(path, ns=(mtime_ns, mtime_ns), follow_symlinks=follow)
        return True

    def m_fs_symlink(self, target, link, overwrite=False):
        if overwrite and os.path.lexists(link):
            os.unlink(link)
        os.symlink(target, link)
        return True

    def m_fs_link(self, src, dst, overwrite=False):
        if overwrite and os.path.lexists(dst):
            os.unlink(dst)
        os.link(src, dst)
        return True

    def m_fs_realpath(self, path):
        return os.path.realpath(path)

    def m_fs_statvfs(self, path):
        v = os.statvfs(path)
        return [v.f_blocks * v.f_frsize, v.f_bfree * v.f_frsize,
                v.f_bavail * v.f_frsize]

    # --- methods: execution -------------------------------------------
    def m_exec_run(self, cmd, cwd=None, stdin=None, env=None,
                   mergeStderr=False, timeout=None):
        e = dict(os.environ)
        e.update(env or {})
        cancel = getattr(self.tl, "cancel", None)
        try:
            p = GuardedPopen(
                cmd, cwd=cwd or None, env=e, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if mergeStderr else subprocess.PIPE,
                start_new_session=True, close_fds=True)
        except FileNotFoundError as ex:
            raise RpcError(-32003, "Searching for program: No such file or directory",
                           {"errno": "ENOENT", "filename": ex.filename or cmd[0]})
        if cancel is not None:
            with cancel.lock:
                cancel.proc = p
            if cancel.cancelled:       # cancelled between check and spawn
                cancel.cancel()
        total, over = [0], threading.Event()
        bufs = {"out": [], "err": []}
        lock = threading.Lock()

        def kill():
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass

        def read(f, key):
            while True:
                d = os.read(f.fileno(), CHUNK)
                if not d:
                    return
                with lock:
                    total[0] += len(d)
                    if total[0] > EXEC_MAX_OUTPUT:
                        over.set()
                        kill()
                        continue    # keep draining so the child can die
                    bufs[key].append(d)

        def feed():
            try:
                p.stdin.write(unb64(stdin))
            except (BrokenPipeError, OSError):
                pass
            finally:
                try:
                    p.stdin.close()
                except OSError:
                    pass

        ts = [threading.Thread(target=read, args=(p.stdout, "out"), daemon=True),
              threading.Thread(target=feed, daemon=True)]
        if not mergeStderr:
            ts.append(threading.Thread(target=read, args=(p.stderr, "err"),
                                       daemon=True))
        for t in ts:
            t.start()
        try:
            code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill()
            p.wait()
            for t in ts:
                t.join(timeout=2)
            raise RpcError(-32603, "TimeoutExpired: command timed out after %s seconds"
                           % timeout)
        kill_rest = False  # reap stray members holding the pipes open
        for t in ts:
            t.join(timeout=2)
            kill_rest = kill_rest or t.is_alive()
        if kill_rest:
            kill()
            for t in ts:
                t.join(timeout=2)
        if cancel is not None and cancel.cancelled:
            raise RpcError(-32800, "request cancelled")
        if over.is_set():
            raise RpcError(-32011, "exec/run output exceeds %d bytes; use proc/spawn"
                           % EXEC_MAX_OUTPUT, {"limit": EXEC_MAX_OUTPUT})
        return {"code": 128 - code if code < 0 else code,
                "signal": -code if code < 0 else None,
                "stdout": b64(b"".join(bufs["out"])),
                "stderr": b64(b"".join(bufs["err"]))}

    def m_proc_spawn(self, **params):
        with self.plock:
            pid_id = params.get("id")
            if pid_id is None:
                pid_id = "s%d" % self.next_id
                self.next_id += 1
        try:
            proc = Proc(self, pid_id, params)
        except FileNotFoundError as ex:
            raise RpcError(-32003, "Searching for program: No such file or directory",
                           {"errno": "ENOENT", "filename": ex.filename or params["cmd"][0]})
        return {"id": pid_id, "pid": proc.p.pid}

    def _proc(self, id):
        with self.plock:
            p = self.procs.get(id)
        if p is None:
            raise RpcError(-32004, "no such process")
        return p

    def m_proc_write(self, id, data):
        self._proc(id).write(unb64(data))
        return True

    def m_proc_eof(self, id):
        self._proc(id).close_stdin()
        return True

    def m_proc_signal(self, id, sig):
        self._proc(id).signal(int(sig))
        return True

    def m_proc_resize(self, id, rows, cols):
        self._proc(id).resize(rows, cols)
        return True

    # --- methods: project ---------------------------------------------
    def m_project_files(self, root, detail=False, engine=None, max=None):
        """List project files relative to ROOT.  Default result is a plain
        list (legacy shape); with DETAIL it is {files, engine[, truncated]}.
        ENGINE forces git, rg or walk.  Only names are returned, never
        file contents."""
        if engine is not None and engine not in ("git", "rg", "walk"):
            raise RpcError(-32602, "invalid params: unknown engine")
        if max is not None and (isinstance(max, bool) or not isinstance(max, int)
                                or max < 1):
            raise RpcError(-32602, "invalid params: max must be a positive integer")
        if not os.path.isdir(root):
            raise RpcError(-32000, "not a directory: " + root)
        limit = max if max is not None else PROJECT_MAX_FILES
        cancel = getattr(self.tl, "cancel", None)

        def cancelled():
            return cancel is not None and cancel.cancelled

        cmds = {"git": ["git", "ls-files", "-z", "-co", "--exclude-standard"],
                "rg": ["rg", "--files", "--hidden", "-g", "!.git", "-0"]}
        files, used = None, None
        for name in ([engine] if engine else ["git", "rg", "walk"]):
            if name == "walk":
                break
            try:
                # Popen (own session) so $/cancel can kill the whole group.
                proc = GuardedPopen(cmds[name], cwd=root, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, start_new_session=True)
            except FileNotFoundError:
                continue
            if cancel is not None:
                with cancel.lock:
                    cancel.proc = proc
                if cancel.cancelled:
                    cancel.cancel()
            out_bytes = proc.stdout.read()
            proc.wait()
            if cancelled():
                raise RpcError(-32800, "request cancelled")
            if proc.returncode == 0:
                files = [f for f in out_bytes.decode("utf-8", "replace").split("\0") if f]
                if name == "git":
                    # ls-files still lists tracked files deleted from disk
                    files = [f for f in files
                             if os.path.lexists(os.path.join(root, f))]
                used = name
                break
        if files is None:
            files, used = [], "walk"
            for d, dirs, fs in os.walk(root):
                if cancelled():
                    raise RpcError(-32800, "request cancelled")
                dirs[:] = [x for x in dirs if not x.startswith(".")]
                files.extend(os.path.relpath(os.path.join(d, f), root) for f in fs)
                if len(files) > limit:
                    break
        truncated = len(files) > limit
        if truncated:
            files = files[:limit]
        if not detail:
            return files
        res = {"files": files, "engine": used}
        if truncated:
            res["truncated"] = True
        return res

    def m_project_root(self, path, markers=None):
        """Find the project root enclosing PATH.  The nearest VCS root wins;
        otherwise the nearest ancestor holding any marker.  Only directory
        entries are inspected."""
        if markers is None:
            markers = list(PROJECT_MARKERS)
        else:
            if (not isinstance(markers, list) or len(markers) > 64
                    or not all(isinstance(m, str) and m and "/" not in m
                               and "\0" not in m and len(m) <= 64
                               for m in markers)):
                raise RpcError(-32602, "invalid params: markers must be an array "
                               "of up to 64 plain names")
        d = os.path.abspath(path)
        # A symlink to a directory is a directory: look for markers inside it
        # (the returned root keeps the path the caller gave, not the target).
        if not os.path.isdir(d):
            d = os.path.dirname(d)
        first = None
        while True:
            for m in markers:
                if os.path.lexists(os.path.join(d, m)):
                    if m in VCS_MARKERS:
                        return {"root": d, "marker": m, "vcs": VCS_MARKERS[m]}
                    if first is None:
                        first = (d, m)
                    break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if first:
            return {"root": first[0], "marker": first[1]}
        return {"root": None}


def is_loopback(host):
    import ipaddress
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def serve_tcp(host, port, token, workers=DEFAULT_WORKERS):
    srv = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(8)
    sys.stderr.write("rdev-server %s listening on %s:%d\n" % (VERSION, host, port))
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        rf, wf = conn.makefile("rb"), conn.makefile("wb")

        def run(rf=rf, wf=wf, conn=conn):
            try:
                Session(rf, wf, token, workers=workers).serve()
            finally:
                try:
                    conn.shutdown(socket.SHUT_RDWR)  # makefile() refs keep fd open
                except OSError:
                    pass
                conn.close()
        threading.Thread(target=run, daemon=True).start()


def resolve_token(args, port):
    """Pick the auth token: --token-file, then $RDEV_TOKEN, then --token,
    else generate one (>= 256 bits) and store it in a 0600 file.  The token
    value itself is never written to stdout/stderr (T063, FR-034)."""
    token = None
    if args.token_file:
        with open(os.path.expanduser(args.token_file)) as f:
            token = f.read().strip()
    elif os.environ.get("RDEV_TOKEN"):
        token = os.environ["RDEV_TOKEN"]
    elif args.token:
        token = args.token
    if token:
        if len(token) < 16:
            sys.stderr.write("warning: weak token (< 16 characters); use at "
                             "least 128 bits, e.g. omit --token to generate one\n")
        return token
    import secrets
    token = secrets.token_urlsafe(32)
    d = os.path.expanduser("~/.cache/rdev")
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "token-%d" % port)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    sys.stderr.write("generated auth token written to %s (mode 0600)\n" % path)
    return token


def main():
    if sys.version_info < (3, 8):
        sys.stderr.write("RDEV-ERR python>=3.8 required, found %s\n" %
                         sys.version.split()[0])
        sys.exit(3)
    # Python < 3.9 block-buffers stderr when it is a pipe; warnings must be
    # visible immediately.
    try:
        sys.stderr.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdio", action="store_true")
    ap.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                    help="max concurrent exec/run and project/files requests")
    ap.add_argument("--listen", metavar="HOST:PORT")
    ap.add_argument("--token")
    ap.add_argument("--token-file")
    ap.add_argument("--allow-non-loopback", action="store_true",
                    help="permit --listen on a non-loopback address "
                         "(plaintext; prefer ssh)")
    ap.add_argument("--allow-root", action="store_true",
                    help="permit running as root inside a container "
                         "(explicit per-target opt-in; not accepted via "
                         "environment variables or RPC)")
    a = ap.parse_args()
    # Root refusal.  The default is unconditional; the only override is the
    # --allow-root command-line flag, which the Emacs client passes only for a
    # target with :allow-root set.  It is never read from the environment, a
    # configuration file or RPC, so an ordinary ssh or TCP deployment cannot
    # become root by accident.
    if os.geteuid() == 0 and not a.allow_root:
        sys.stderr.write("RDEV-ERR refusing to run as root (uid 0): the rdev agent "
                         "must run as an unprivileged user\n")
        sys.exit(5)
    if os.geteuid() == 0 and a.allow_root:
        sys.stderr.write("WARNING: running as root by explicit --allow-root "
                         "(container opt-in); the agent has full privileges\n")
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if a.listen:
        host, _, port = a.listen.rpartition(":")
        host = host or "127.0.0.1"
        token = resolve_token(a, int(port))
        if not is_loopback(host) and not a.allow_non_loopback:
            sys.exit("refusing to listen on non-loopback %s without "
                     "--allow-non-loopback (traffic is unencrypted)" % host)
        if not is_loopback(host):
            sys.stderr.write("WARNING: listening on non-loopback %s, "
                             "unencrypted\n" % host)
        if a.token:
            sys.stderr.write("WARNING: --token is visible in the process "
                             "list; prefer --token-file\n")
        serve_tcp(host, int(port), token, a.workers)
    else:
        # Keep the real stdout for the protocol; anything else that writes
        # to fd 1 by accident would corrupt the stream.
        out = os.fdopen(os.dup(1), "wb")
        os.dup2(2, 1)

        def _terminate(signum, _frame):
            # Unwind through Session.serve() so its `finally' ends the
            # processes this session owns (FR-021) before the agent exits.
            raise SystemExit(128 + signum)
        signal.signal(signal.SIGTERM, _terminate)
        signal.signal(signal.SIGHUP, _terminate)
        Session(sys.stdin.buffer, out, workers=a.workers).serve()


if __name__ == "__main__":
    main()
