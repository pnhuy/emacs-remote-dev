#!/bin/sh
# First-connection E2E (T049/SC-004): wipe the cached agent, connect over real ssh,
# assert success in < 15 s.   Usage: RDEV_TEST_SSH_TARGET=host test/e2e/bootstrap.sh [trials]
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
host=${RDEV_TEST_SSH_TARGET:?set RDEV_TEST_SSH_TARGET}; trials=${1:-5}; EMACS=${EMACS:-emacs}
ok=0
i=0
while [ "$i" -lt "$trials" ]; do
  i=$((i+1))
  ssh -o BatchMode=yes "$host" 'rm -rf "$HOME/.cache/rdev"' || exit 2
  start=$(date +%s)
  if (cd "$root" && "$EMACS" -Q --batch -L . --eval "(progn (require 'rdev) (setq rdev-ssh-args (append rdev-ssh-args '(\"-o\" \"ConnectTimeout=15\"))) (rdev--connect \"$host\") (kill-emacs 0))" >/dev/null 2>&1); then
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -lt 15 ]; then ok=$((ok+1)); fi
    echo "trial $i: ok in ${elapsed}s"
  else
    echo "trial $i: FAILED"
  fi
done
echo "first-connection successes: $ok/$trials"
[ "$ok" -eq "$trials" ]
