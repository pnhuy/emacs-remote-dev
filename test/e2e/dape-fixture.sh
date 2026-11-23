#!/bin/sh
# Create (idempotently) a venv with debugpy on the test remote.  Prints the venv's
# python path on success; exits 1 (tests then skip visibly) if it cannot be installed.
# usage: dape-fixture.sh HOST   (HOST "local" runs here)
set -u
host=${1:-${RDEV_TEST_SSH_TARGET:-local}}
venv=${RDEV_DAPE_VENV:-/tmp/rdev-dape-venv}
script="
set -e
if [ ! -x $venv/bin/python ] || ! $venv/bin/python -c 'import debugpy' 2>/dev/null; then
  python3 -m venv $venv >&2
  $venv/bin/python -m pip install --quiet debugpy >&2
fi
$venv/bin/python -c 'import debugpy' && echo $venv/bin/python
"
if [ "$host" = local ]; then sh -c "$script"; else ssh -o BatchMode=yes "$host" "$script"; fi
