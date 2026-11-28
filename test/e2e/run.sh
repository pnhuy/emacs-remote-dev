#!/bin/sh
# Run one E2E scenario: test/e2e/run.sh SCENARIO   (file test/e2e/SCENARIO.el)
# Uses a throwaway local sshd, or RDEV_TEST_SSH_TARGET=host to use an external host.
# `S=docker` (SCENARIO=docker) starts the disposable Docker containers and, for
# the remote-engine scenario, the sshd fixture as the engine host.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
scn=${1:?scenario name}; EMACS=${EMACS:-emacs}
dir=
docker_dir=
ssh_dir=
status=0

cleanup() {
  if [ -n "$docker_dir" ]; then
    "$here/docker-fixture.sh" stop "$docker_dir" || status=$?
    docker_dir=
  fi
  if [ -n "$ssh_dir" ]; then
    "$here/sshd-fixture.sh" stop "$ssh_dir" || status=$?
    ssh_dir=
  fi
  if [ -n "$dir" ]; then
    rm -rf "$dir"; dir=
  fi
}

if [ "$scn" = docker ]; then
  dir=$(mktemp -d /tmp/rdev-e2e-docker.XXXXXX)
  docker_dir=$dir/docker
  out=$("$here/docker-fixture.sh" start "$docker_dir")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 77 ]; then
      echo "SKIP: docker fixture unavailable" >&2
      rm -rf "$dir"; dir=
      exit 0
    fi
    echo "docker fixture failed" >&2
    rm -rf "$dir"; dir=
    exit 2
  fi
  # Export the fixture's container names to the Emacs child process.
  set -a
  eval "$out"
  set +a
  # The remote-engine scenario uses the disposable sshd as the engine host.
  ssh_dir=$dir/ssh
  if sshout=$("$here/sshd-fixture.sh" start "$ssh_dir"); then
    export RDEV_TEST_SSH_CONFIG=${sshout#* } RDEV_TEST_HOST=rdev-test
  else
    echo "SKIP: sshd fixture unavailable; remote-engine scenario will skip" >&2
    ssh_dir=
  fi
elif [ -n "${RDEV_TEST_SSH_TARGET:-}" ]; then
  export RDEV_TEST_HOST=$RDEV_TEST_SSH_TARGET; dir=
else
  dir=$(mktemp -d /tmp/rdev-e2e.XXXXXX)
  ssh_dir=$dir/fx
  if ! out=$("$here/sshd-fixture.sh" start "$ssh_dir"); then
    echo "sshd fixture failed" >&2
    rm -rf "$dir"; dir=
    exit 2
  fi
  export RDEV_TEST_SSH_CONFIG=${out#* } RDEV_TEST_HOST=rdev-test
fi

trap 'cleanup; exit $status' EXIT
trap 'status=130; exit 130' INT TERM
cd "$root"
# RDEV_TEST_SELECTOR: an ERT selector (e.g. "\"two-aliases\"" or "(or \"a\" \"b\")"); default all.
"$EMACS" -Q --batch -L . -L test -l ert -l "test/e2e/$scn.el" \
  --eval "(ert-run-tests-batch-and-exit '${RDEV_TEST_SELECTOR:-t})" || status=$?
