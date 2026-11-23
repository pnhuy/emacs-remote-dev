#!/bin/sh
# Benchmark rdev against TRAMP under shaped networks (T104/T105/T106).
#   bench/run.sh HOST OUT.csv [profile ...]            shaper: delay-proxy (default)
#   bench/run.sh --netem OUT.csv [profile ...]         shaper: tc netem in a private netns
#                                                      with a throwaway local sshd (Linux)
# Profiles: rtt0 rtt50 rtt150 loss1 slow1mbit (default: rtt0 rtt50 rtt150).
# Environment: EMACS, PYTHON, RDEV_BENCH_ITER (default 20), RDEV_BENCH_BACKENDS (rdev,tramp).
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
EMACS=${EMACS:-emacs}; PYTHON=${PYTHON:-python3}
mode=proxy
if [ "${1:-}" = "--netem" ]; then mode=netem; shift; fi
if [ "${1:-}" = "--inner" ]; then mode=inner; shift; fi

profile_params() {  # profile -> "rtt_ms loss_pct rate_bytes_per_s"
  case $1 in
    rtt0) echo "0 0 0" ;; rtt50) echo "50 0 0" ;; rtt150) echo "150 0 0" ;;
    loss1) echo "50 1 0" ;; slow1mbit) echo "50 0 125000" ;;
    *) echo "unknown profile $1" >&2; return 1 ;;
  esac
}

run_emacs() {  # host shaper profile out [cfg]
  RDEV_BENCH_HOST=$1 RDEV_BENCH_SHAPER=$2 RDEV_BENCH_PROFILE=$3 RDEV_BENCH_OUT=$4 \
  RDEV_BENCH_SSH_CONFIG=${5:-} \
  "$EMACS" -Q --batch -L "$root" -l rdev-bench --eval '(rdev-bench-main)' 2>&1 \
    | grep -v '^\(Wrote\|rdev:\)' >&2
}

if [ $mode = inner ]; then
  # Runs inside the shaped namespace: start sshd on the shaped loopback, benchmark it.
  out=$1; profile=$2
  fx=$(mktemp -d /tmp/rdev-bench.XXXXXX)
  res=$("$root/test/e2e/sshd-fixture.sh" start "$fx/fx") || { echo "sshd fixture failed" >&2; exit 2; }
  cfg=${res#* }
  trap '"$root/test/e2e/sshd-fixture.sh" stop "$fx/fx"; rm -rf "$fx"' EXIT
  run_emacs rdev-test netem "$profile" "$out" "$cfg"
  exit 0
fi

if [ $mode = netem ]; then
  out=${1:?output csv}; shift
  "$here/netem.sh" --check || exit 2
  [ $# -gt 0 ] || set -- rtt0 rtt50 rtt150
  echo "$(sed -n 1p "$root/rdev-bench.el" >/dev/null; grep -m1 '^(defconst rdev-bench-header' -A1 "$root/rdev-bench.el" | tail -1 | tr -d '" )')" >/dev/null
  [ -s "$out" ] || printf '%s\n' "date,shaper,profile,backend,op,n,median_ms,p95_ms,failures,ui_blocked_ms,emacs_rss_kb,note" > "$out"
  for p in "$@"; do
    set -- $(profile_params "$p") || exit 2
    rtt=$1; loss=$2; rate=$3
    r=none; [ "$rate" != 0 ] && r="$((rate * 8))bit"
    echo "== netem $p" >&2
    "$here/netem.sh" "$rtt" "$loss" "$r" -- sh "$0" --inner "$out" "$p"
  done
  exit 0
fi

host=${1:?host}; out=${2:?output csv}; shift 2
[ $# -gt 0 ] || set -- rtt0 rtt50 rtt150
[ -s "$out" ] || printf '%s\n' "date,shaper,profile,backend,op,n,median_ms,p95_ms,failures,ui_blocked_ms,emacs_rss_kb,note" > "$out"
g=$(ssh -G -- "$host" 2>/dev/null)
field() { printf '%s\n' "$g" | awk -v k="$1" '$1==k{print $2; exit}'; }
hn=$(field hostname); un=$(field user); pt=$(field port)
for p in "$@"; do
  set -- $(profile_params "$p") || exit 2
  rtt=$1; loss=$(awk "BEGIN{print $2/100}"); rate=$3
  cfg=$(mktemp /tmp/rdev-bench-cfg.XXXXXX); chmod 600 "$cfg"
  {
    [ -r "$HOME/.ssh/config" ] && echo "Include $HOME/.ssh/config"
    [ -r /etc/ssh/ssh_config ] && echo "Include /etc/ssh/ssh_config"
    echo "Host bench-$p"
    echo "  HostName $hn"; echo "  User $un"; echo "  Port $pt"
    echo "  ProxyCommand $PYTHON $here/delay-proxy.py --connect %h:%p --rtt-ms $rtt --loss $loss --rate-bps $rate"
  } > "$cfg"
  echo "== delay-proxy $p (rtt ${rtt}ms loss $loss rate ${rate}B/s)" >&2
  run_emacs "bench-$p" delay-proxy "$p" "$out" "$cfg"
  rm -f "$cfg"
done
