#!/bin/sh
# Start/stop the disposable Docker containers used by test/e2e/docker.el.
#
# Usage: docker-fixture.sh start DIR
#          -> prints shell assignments for the container names
#        docker-fixture.sh stop DIR
#          -> removes both containers and DIR
#
# Environment:
#   RDEV_TEST_DOCKER_IMAGE  image with sh + Python >= 3.8 (default python:3.11-slim)
#
# Exit 77 means "Docker is unavailable": the caller reports a skip, never a
# silent pass.  The fixture creates no listener and publishes no port.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:?start|stop}; dir=${2:?dir}
image=${RDEV_TEST_DOCKER_IMAGE:-python:3.11-slim}
prefix="rdev-e2e-$$"
dev="$prefix-dev"
root="$prefix-root"

docker_ok() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

cleanup_containers() {
  docker rm -f "$dev" >/dev/null 2>&1 || true
  docker rm -f "$root" >/dev/null 2>&1 || true
}

case $cmd in
  stop)
    # The names were chosen by the `start' process; read them back so a
    # different PID can still remove exactly those containers.
    if [ -f "$dir/containers" ]; then
      dev=$(sed -n '1p' "$dir/containers")
      root=$(sed -n '2p' "$dir/containers")
    fi
    if docker_ok; then
      cleanup_containers
    fi
    rm -rf "$dir"
    exit 0 ;;
  start) ;;
  *) echo "usage: docker-fixture.sh start|stop DIR" >&2; exit 2 ;;
esac

if ! docker_ok; then
  echo "SKIP: docker CLI or daemon unavailable" >&2
  exit 77
fi

mkdir -p "$dir"
printf '%s\n%s\n' "$dev" "$root" > "$dir/containers"
trap 'cleanup_containers; rm -rf "$dir"' EXIT INT TERM

# Unprivileged container: uid 1000 with a writable HOME.  The seed commands
# run as root through `docker exec -u 0' because the container's own user
# cannot create the directories.
if ! docker run -d --name "$dev" --user 1000:1000 -e HOME=/home/dev \
     -w /workspace "$image" sleep infinity >/dev/null; then
  echo "SKIP: cannot start $image (pull it first or set RDEV_TEST_DOCKER_IMAGE)" >&2
  exit 77
fi
docker exec -u 0 "$dev" sh -c \
  'mkdir -p /workspace /home/dev && chown 1000:1000 /workspace /home/dev &&
   printf "hello\n" > /workspace/hello.txt && chown 1000:1000 /workspace/hello.txt' \
  >/dev/null

# Root-only container: no unprivileged account is created, so the default
# root policy must refuse it and :allow-root must be the only way in.
docker run -d --name "$root" -w /workspace "$image" sleep infinity >/dev/null
docker exec "$root" sh -c \
  'mkdir -p /workspace && printf "root\n" > /workspace/hello.txt' >/dev/null

# The containers are ready; the trap must not remove them on success.
trap - EXIT INT TERM
printf 'RDEV_TEST_DOCKER_DEV=%s\nRDEV_TEST_DOCKER_ROOT=%s\n' "$dev" "$root"
