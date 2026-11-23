#!/bin/sh
# Run a command inside a private network namespace whose loopback has tc-netem
# shaping (T105).  No root needed: `unshare -rn` gives a user+net namespace.
#   bench/netem.sh --check
#   bench/netem.sh RTT_MS LOSS_PCT RATE -- cmd args...      (RATE like 1mbit, or "none")
# Loopback carries both directions, so the one-way delay is RTT/2.  The command
# must find its own sshd inside the namespace (see test/e2e/sshd-fixture.sh).
set -u
if [ "${1:-}" = "--check" ]; then
  command -v unshare >/dev/null && command -v tc >/dev/null || { echo "netem unavailable: need unshare and tc" >&2; exit 2; }
  unshare -nm --map-root-user --map-auto sh -c 'ip link set lo up && tc qdisc add dev lo root netem delay 1ms' >/dev/null 2>&1 \
    || { echo "netem unavailable: cannot create shaped namespace (no user namespaces?)" >&2; exit 2; }
  echo netem-ok; exit 0
fi
rtt=${1:?rtt ms}; loss=${2:?loss pct}; rate=${3:?rate}; shift 3
[ "${1:-}" = "--" ] && shift
half=$(awk "BEGIN{print $rtt/2}")
opts="delay ${half}ms"
[ "$loss" != "0" ] && opts="$opts loss ${loss}%"
[ "$rate" != "none" ] && opts="$opts rate $rate"
# --map-auto adds the subuid range so sshd's privilege separation can setgroups/setuid.
# sshd also refuses "locked" accounts and root's shadow entry is usually `!`; shadow a copy with `*`.
# /root (the namespace's "root" home) is unwritable for the same reason, so shadow it too.
# The agent refuses to run as uid 0, and "root" is all this namespace has by default, so add
# an unprivileged `bench` login (uid 1000, inside the --map-auto range) with its own home.
# sshd insists that its privilege-separation dir be root-owned; inside the user
# namespace the real root looks like "nobody", so shadow it with a private dir.
exec unshare -nm --map-root-user --map-auto sh -c 'ip link set lo up && tc qdisc add dev lo root netem '"$opts"' \
  && { for d in /usr/share/empty.sshd /run/sshd /var/empty /root; do \
         [ -d "$d" ] && { e=$(mktemp -d) && chmod 755 "$e" && mount --bind "$e" "$d" 2>/dev/null; }; done; true; } \
  && { f=$(mktemp) && echo "root:*:19000:0:99999:7:::" > "$f" && mount --bind "$f" /etc/shadow 2>/dev/null; true; } \
  && { h=$(mktemp -d) && chown 1000:1000 "$h" && chmod 755 "$h" \
       && p=$(mktemp) && cp /etc/passwd "$p" && echo "bench:x:1000:1000::$h:/bin/sh" >> "$p" \
       && mount --bind "$p" /etc/passwd \
       && g=$(mktemp) && cp /etc/shadow "$g" && echo "bench:*:19000:0:99999:7:::" >> "$g" \
       && mount --bind "$g" /etc/shadow && export SSHD_LOGIN_USER=bench; } \
  && exec "$@"' sh "$@"
