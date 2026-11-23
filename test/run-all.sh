#!/bin/sh
# Run the full RDEV test suite: Python unit tests, then Emacs ERT tests.
# Exits non-zero on any failure or unexpected skip.
set -u
cd "$(dirname "$0")/.." || exit 2
PY=${PYTHON:-python3}
export PYTHONWARNINGS=ignore::ResourceWarning
EMACS=${EMACS:-emacs}
rc=0
echo "== python ($($PY --version 2>&1)) =="
$PY -m unittest discover -s test/py -t test/py -v || rc=1
# Minimum supported Python (3.8): run the agent tests under it when available.
PY38=${PYTHON38:-$(command -v python3.8 2>/dev/null || true)}
if [ -n "$PY38" ] && "$PY38" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 8))' 2>/dev/null; then
  if [ "$PY38" != "$PY" ]; then
    echo "== python 3.8 ($($PY38 --version 2>&1)) =="
    $PY38 -m unittest discover -s test/py -t test/py || rc=1
  fi
else
  echo "== python 3.8: not run (no python3.8 interpreter found) =="
fi
echo "== port hygiene negative path (T116) =="
sh test/portguard-test.sh || rc=1
echo "== emacs ($($EMACS --version | head -1)) =="
$EMACS -Q --batch -L . -L test -l ert -l test/rdev-all-tests.el \
  -f ert-run-tests-batch-and-exit || rc=1
exit $rc
