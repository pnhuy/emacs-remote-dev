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
import grp
import hmac
import json
import os
import pty
import pwd
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
import time

VERSION = "0.1.0"
CHUNK = 65536


def b64(data):
    return base64.b64encode(data).decode("ascii")


def unb64(s):
    return base64.b64decode(s) if s else b""


class RpcError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


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
        "ino": st.st_ino, "dev": st.st_dev,
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

            self.p = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=slave,
                                      stdout=slave, stderr=slave,
                                      preexec_fn=setup, close_fds=True)
            os.close(slave)
            self.master = master
            readers = [(master, "out")]
        else:
            self.p = subprocess.Popen(
                cmd, cwd=cwd, env=env, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if self.merge else subprocess.PIPE,
                start_new_session=True, close_fds=True)
            readers = [(self.p.stdout.fileno(), "out")]
            if not self.merge:
                readers.append((self.p.stderr.fileno(), "err"))
        self.threads = [threading.Thread(target=self._pump, args=r, daemon=True)
                        for r in readers]
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
            self.s.notify("proc/out", {"id": self.id, "stream": stream,
                                       "data": b64(data)})

    def _reap(self):
        code = self.p.wait()
        for t in self.threads:
            t.join(timeout=2)
        if self.master is not None:
            os.close(self.master)
        sig = -code if code < 0 else None
        self.s.notify("proc/exit", {"id": self.id,
                                    "code": 128 + sig if sig else code,
                                    "signal": sig})
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

    def resize(self, rows, cols):
        if self.master is not None:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, cols, 0, 0))


class Session:
    def __init__(self, rfile, wfile, token=None):
        self.r, self.w = rfile, wfile
        self.wlock = threading.Lock()
        self.procs = {}
        self.next_id = 1
        self.authed = token is None
        self.token = token

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
        length = None
        while True:
            line = self.r.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            k, _, v = line.decode("ascii").partition(":")
            if k.lower() == "content-length":
                length = int(v)
        return json.loads(self.r.read(length))

    # --- dispatch ------------------------------------------------------
    def serve(self):
        try:
            while True:
                msg = self.read_message()
                if msg is None:
                    break
                if "method" not in msg:
                    continue  # responses to our (non-existent) requests
                # Process requests in order on one thread except the slow,
                # streaming-friendly ones, which get their own thread.
                if msg["method"] in ("exec/run", "project/files", "search/grep"):
                    threading.Thread(target=self.handle, args=(msg,),
                                     daemon=True).start()
                else:
                    self.handle(msg)
        finally:
            for p in list(self.procs.values()):
                p.signal(signal.SIGHUP)

    def handle(self, msg):
        mid, method = msg.get("id"), msg["method"]
        try:
            if not self.authed and method != "auth":
                raise RpcError(-32002, "not authenticated")
            fn = getattr(self, "m_" + method.replace("/", "_"), None)
            if fn is None:
                raise RpcError(-32601, "method not found: " + method)
            result = fn(**(msg.get("params") or {}))
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
                str(token), self.token):
            raise RpcError(-32002, "bad token")
        self.authed = True
        return True

    def m_hello(self):
        return {"version": VERSION, "home": os.path.expanduser("~"),
                "user": user_name(os.getuid()), "uid": os.getuid(),
                "host": socket.gethostname(),
                "path": os.environ.get("PATH", "").split(":"),
                "python": sys.version.split()[0]}

    # --- methods: filesystem ------------------------------------------
    def m_fs_stat(self, path):
        try:
            return stat_dict(path)
        except FileNotFoundError:
            return None
        except NotADirectoryError:
            return None

    def m_fs_readdir(self, path, attrs=False):
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
        return out

    def m_fs_read(self, path):
        with open(path, "rb") as f:
            data = f.read()
        st = os.stat(path)
        return {"data": b64(data), "mtime": st.st_mtime_ns}

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
        finally:
            os.close(fd)
        return {"mtime": os.stat(path).st_mtime_ns}

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
        try:
            p = subprocess.run(
                cmd, cwd=cwd or None, env=e, input=unb64(stdin),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT if mergeStderr else subprocess.PIPE,
                timeout=timeout)
        except FileNotFoundError as ex:
            raise RpcError(-32003, "Searching for program: No such file or directory",
                           {"errno": "ENOENT", "filename": ex.filename or cmd[0]})
        code = p.returncode
        return {"code": 128 - code if code < 0 else code,
                "signal": -code if code < 0 else None,
                "stdout": b64(p.stdout), "stderr": b64(p.stderr or b"")}

    def m_proc_spawn(self, **params):
        pid_id = params.get("id")
        if pid_id is None:
            pid_id = "s%d" % self.next_id
            self.next_id += 1
        try:
            proc = Proc(self, pid_id, params)
        except FileNotFoundError as ex:
            raise RpcError(-32003, "Searching for program: No such file or directory",
                           {"errno": "ENOENT", "filename": ex.filename or params["cmd"][0]})
        self.procs[pid_id] = proc
        return {"id": pid_id, "pid": proc.p.pid}

    def _proc(self, id):
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
    def m_project_files(self, root):
        for cmd in (["git", "ls-files", "-z", "-co", "--exclude-standard"],
                    ["rg", "--files", "--hidden", "-g", "!.git", "-0"]):
            try:
                p = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
            except FileNotFoundError:
                continue
            if p.returncode == 0:
                return [f for f in p.stdout.decode("utf-8", "replace").split("\0") if f]
        out = []
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            out.extend(os.path.relpath(os.path.join(d, f), root) for f in files)
        return out


def serve_tcp(host, port, token):
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
                Session(rf, wf, token).serve()
            finally:
                conn.close()
        threading.Thread(target=run, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdio", action="store_true")
    ap.add_argument("--listen", metavar="HOST:PORT")
    ap.add_argument("--token")
    ap.add_argument("--token-file")
    a = ap.parse_args()
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if a.listen:
        host, _, port = a.listen.rpartition(":")
        token = a.token
        if a.token_file:
            with open(os.path.expanduser(a.token_file)) as f:
                token = f.read().strip()
        if not token:
            sys.exit("--listen requires --token or --token-file")
        serve_tcp(host or "127.0.0.1", int(port), token)
    else:
        # Keep the real stdout for the protocol; anything else that writes
        # to fd 1 by accident would corrupt the stream.
        out = os.fdopen(os.dup(1), "wb")
        os.dup2(2, 1)
        Session(sys.stdin.buffer, out).serve()


if __name__ == "__main__":
    main()
