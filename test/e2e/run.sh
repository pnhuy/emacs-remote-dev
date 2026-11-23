#!/bin/sh
# Run one E2E scenario: test/e2e/run.sh SCENARIO   (file test/e2e/SCENARIO.el)
# Uses a throwaway local sshd, or RDEV_TEST_SSH_TARGET=host to use an external host.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
scn=${1:?scenario name}; EMACS=${EMACS:-emacs}
if [ -n "${RDEV_TEST_SSH_TARGET:-}" ]; then
  export RDEV_TEST_HOST=$RDEV_TEST_SSH_TARGET; dir=
else
  dir=$(mktemp -d /tmp/rdev-e2e.XXXXXX)
  out=$("$here/sshd-fixture.sh" start "$dir/fx") || { echo "sshd fixture failed" >&2; exit 2; }
  export RDEV_TEST_SSH_CONFIG=${out#* } RDEV_TEST_HOST=rdev-test
fi
status=0
cleanup() {
  if [ -n "$dir" ]; then
    "$here/sshd-fixture.sh" stop "$dir/fx" || status=$?   # T116: fails if a listener lingers
    rm -rf "$dir"; dir=
  fi
}
trap 'cleanup; exit $status' EXIT
trap 'status=130; exit 130' INT TERM
cd "$root"
# RDEV_TEST_SELECTOR: an ERT selector (e.g. "\"two-aliases\"" or "(or \"a\" \"b\")"); default all.
"$EMACS" -Q --batch -L . -L test -l ert -l "test/e2e/$scn.el" \
  --eval "(ert-run-tests-batch-and-exit '${RDEV_TEST_SELECTOR:-t})" || status=$?
