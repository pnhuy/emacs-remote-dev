#!/bin/sh
# Measure Docker discovery and first-connect overhead.
#
#   bench/docker-discovery.sh [OUT.md]
#
# Starts RDEV_BENCH_CONTAINERS (default 50) disposable containers, measures
# `docker ps' and the Emacs discovery cache, then measures a cold first
# connect (helper install + hello) and a warm reconnect.  Removes every
# container it created.  A missing Docker daemon or image is reported, not
# silently skipped.
set -eu

here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
n=${RDEV_BENCH_CONTAINERS:-50}
image=${RDEV_TEST_DOCKER_IMAGE:-python:3.11-slim}
prefix="rdev-bench-$$"
out=${1:-"$here/results/docker-discovery-$(date +%Y-%m-%d).md"}
EMACS=${EMACS:-emacs}

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || {
  echo "docker CLI or daemon unavailable" >&2; exit 2; }

names=
cleanup() {
  for c in $names; do docker rm -f "$c" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

echo "starting $n containers from $image ..." >&2
i=0
while [ "$i" -lt "$n" ]; do
  c="$prefix-$i"
  docker run -d --name "$c" --network none --user 1000:1000 \
    -e HOME=/tmp -w /workspace "$image" sleep infinity >/dev/null
  names="$names $c"
  i=$((i + 1))
done

# Median of five `docker ps' runs, in milliseconds.
ps_ms=$(for _ in 1 2 3 4 5; do
  t0=$(date +%s%N)
  docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}' >/dev/null
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 1000000 ))
done | sort -n | sed -n '3p')

# Emacs: cold discovery (empty cache) and warm discovery (TTL hit), in ms.
emacs_ms() {
  "$EMACS" -Q --batch -L "$root" --eval "$1" 2>/dev/null
}
discovery_cold=$(emacs_ms "(progn
  (require 'rdev) (require 'rdev-docker)
  (setq rdev-hosts '((\"bench\" . (:transport docker :container \"$prefix-0\"))))
  (let ((t0 (float-time)))
    (rdev-docker--discovery-for-host \"bench\" t)
    (princ (format \"%.1f\" (* 1000 (- (float-time) t0))))))")
discovery_warm=$(emacs_ms "(progn
  (require 'rdev) (require 'rdev-docker)
  (setq rdev-hosts '((\"bench\" . (:transport docker :container \"$prefix-0\"))))
  (rdev-docker--discovery-for-host \"bench\" t)
  (let ((t0 (float-time)))
    (rdev-docker--discovery-for-host \"bench\")
    (princ (format \"%.1f\" (* 1000 (- (float-time) t0))))))")

# Cold first connect on three fresh containers; warm reconnect on the first.
cold=
i=0
while [ "$i" -lt 3 ]; do
  ms=$(emacs_ms "(progn
    (require 'rdev) (require 'rdev-docker)
    (setq rdev-hosts '((\"bench\" . (:transport docker :container \"$prefix-$i\"))))
    (let ((t0 (float-time)))
      (rdev--connect \"bench\")
      (princ (format \"%.1f\" (* 1000 (- (float-time) t0))))
      (rdev-disconnect \"bench\")))")
  cold="$cold $ms"
  i=$((i + 1))
done
cold_median=$(printf '%s\n' $cold | sort -n | sed -n '2p')
warm=$(emacs_ms "(progn
  (require 'rdev) (require 'rdev-docker)
  (setq rdev-hosts '((\"bench\" . (:transport docker :container \"$prefix-0\"))))
  (rdev--connect \"bench\")
  (rdev-disconnect \"bench\")
  (let ((t0 (float-time)))
    (rdev--connect \"bench\")
    (princ (format \"%.1f\" (* 1000 (- (float-time) t0))))
    (rdev-disconnect \"bench\")))")

mkdir -p "$(dirname "$out")"
{
  echo "# Docker discovery and first-connect benchmark"
  echo
  echo "Recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(uname -srm), Emacs $("$EMACS" --version | head -1 | awk '{print $3}'),"
  echo "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown), image \`$image\`."
  echo
  echo "| Measurement | Value |"
  echo "|---|---|"
  echo "| Containers | $n |"
  echo "| \`docker ps\` (median of 5) | ${ps_ms} ms |"
  echo "| Emacs discovery, cold | ${discovery_cold} ms |"
  echo "| Emacs discovery, cached (TTL) | ${discovery_warm} ms |"
  echo "| First connect, cold (median of 3) | ${cold_median} ms |"
  echo "| Reconnect, warm helper | ${warm} ms |"
  echo
  echo "Cold connect installs and hash-verifies the helper; warm reuses it."
  echo "Target: discovery of 50 containers in <= 3 s."
} > "$out"

echo "wrote $out" >&2
cat "$out"
