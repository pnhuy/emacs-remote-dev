#!/bin/sh
# Start an unprivileged sshd on 127.0.0.1:<free port> with throwaway keys.
# Usage: sshd-fixture.sh start DIR   -> prints "PORT CONFIG" and leaves sshd running
#        sshd-fixture.sh stop  DIR   -> stops it and removes DIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:?start|stop}; dir=${2:?dir}
SSHD=${SSHD:-$(command -v sshd || echo /usr/sbin/sshd)}
# listeners PORT -> one line per listening socket on PORT ("addr:port"), via ss or lsof.
listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk -v p=":$1" '{a=$4; if (substr(a, length(a)-length(p)+1)==p) print a}'
  else
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}'
  fi
}
case $cmd in
stop)
  # Port hygiene (T116): the fixture's listener must be gone after teardown.
  port=$(awk '$1=="Port"{print $2}' "$dir/sshd_config" 2>/dev/null || true)
  [ -f "$dir/sshd.pid" ] && kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true
  rm -rf "$dir"
  if [ -n "$port" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -z "$(listeners "$port")" ] && exit 0
      sleep 0.3
    done
    echo "port hygiene: listener still on port $port after teardown: $(listeners "$port")" >&2
    exit 3
  fi
  exit 0;;
start) ;;
*) echo "usage" >&2; exit 2;;
esac
mkdir -p "$dir"; chmod 700 "$dir"
ssh-keygen -q -t ed25519 -N '' -f "$dir/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$dir/user_key"
cp "$dir/user_key.pub" "$dir/authorized_keys"; chmod 600 "$dir/authorized_keys"
# A different login user must be able to read its authorized_keys (sshd reads it as that user).
[ -n "${SSHD_LOGIN_USER:-}" ] && chmod 755 "$dir" "$(dirname "$dir")" && chmod 644 "$dir/authorized_keys"
used=$( (ss -ltn 2>/dev/null || netstat -an -p tcp 2>/dev/null) | tr -s ' ' | tr ':.' '  ' || true)
port=
for _ in $(seq 1 50); do
  p=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 30000 ))
  grep -qx "$p" "$here/reserved-ports.txt" && continue
  echo "$used" | grep -qw "$p" && continue
  port=$p; break
done
[ -n "$port" ] || { echo "no free port" >&2; exit 1; }
cat > "$dir/sshd_config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin yes
LogLevel ${SSHD_LOGLEVEL:-ERROR}
CFG
cat > "$dir/ssh_config" <<CFG
Host rdev-test
  HostName 127.0.0.1
  Port $port
  User ${SSHD_LOGIN_USER:-$(id -un)}
  IdentityFile $dir/user_key
  IdentitiesOnly yes
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  BatchMode yes
CFG
"$SSHD" -f "$dir/sshd_config" -E "$dir/sshd.log"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$dir/sshd.pid" ] && break; sleep 0.3; done
# Port hygiene (T116): the listener must be loopback-only, on the chosen random port.
bad=$(listeners "$port" | grep -v '^127\.0\.0\.1:' || true)
if [ -n "$bad" ] || [ -z "$(listeners "$port")" ]; then
  echo "port hygiene: sshd listener on port $port is not 127.0.0.1-only: '$(listeners "$port")'" >&2
  [ -f "$dir/sshd.pid" ] && kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true
  exit 4
fi
echo "$port $dir/ssh_config"
