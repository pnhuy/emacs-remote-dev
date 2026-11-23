#!/bin/sh
# T116 negative path: the fixture's port-hygiene assertions must FAIL when violated.
#  1. a listener on a non-loopback address  -> `start` exits 4
#  2. a listener that survives teardown      -> `stop` exits 3
# A stub "sshd" (python) stands in; it reads Port/PidFile from the generated sshd_config.
set -u
here=$(cd "$(dirname "$0")" && pwd)
fx=$here/e2e/sshd-fixture.sh
tmp=$(mktemp -d /tmp/rdev-portguard.XXXXXX); trap 'kill $(cat "$tmp"/*/sshd.pid 2>/dev/null) 2>/dev/null; rm -rf "$tmp"' EXIT
cat > "$tmp/stub.py" <<'PY'
import os, signal, socket, sys, time
cfg = open(sys.argv[2]).read().split("\n")
kv = dict(l.split(None, 1) for l in cfg if l.strip() and not l.startswith("#") and " " in l.strip())
port = int(kv["Port"]); pid = kv["PidFile"].strip()
addr = os.environ["STUB_ADDR"]
if os.fork():
    time.sleep(0.5); os._exit(0)       # parent returns like a daemonizing sshd
os.setsid()
if os.environ.get("STUB_IGNORE_TERM"): signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((addr, port)); s.listen(1)
open(pid, "w").write(str(os.getpid()))
while True: time.sleep(1)
PY
cat > "$tmp/sshd" <<SH
#!/bin/sh
exec python3 "$tmp/stub.py" "\$@"
SH
chmod +x "$tmp/sshd"
fail=0
SSHD=$tmp/sshd STUB_ADDR=0.0.0.0 sh "$fx" start "$tmp/a" >/dev/null 2>"$tmp/a.err"; rc=$?
if [ $rc -eq 4 ]; then echo "ok   non-loopback listener rejected at start"; else echo "FAIL start rc=$rc (want 4): $(cat "$tmp/a.err")"; fail=1; fi
kill $(cat "$tmp/a/sshd.pid" 2>/dev/null) 2>/dev/null; sh "$fx" stop "$tmp/a" 2>/dev/null
SSHD=$tmp/sshd STUB_ADDR=127.0.0.1 STUB_IGNORE_TERM=1 sh "$fx" start "$tmp/b" >/dev/null 2>"$tmp/b.err" || { echo "FAIL loopback start: $(cat "$tmp/b.err")"; exit 1; }
sh "$fx" stop "$tmp/b" 2>"$tmp/b.err"; rc=$?
if [ $rc -eq 3 ]; then echo "ok   surviving listener rejected at stop"; else echo "FAIL stop rc=$rc (want 3)"; fail=1; fi
pkill -9 -f "$tmp/stub.py" 2>/dev/null
exit $fail
