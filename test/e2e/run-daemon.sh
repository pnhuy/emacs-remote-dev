#!/bin/sh
# run-daemon.sh FILE SELECTOR [TIMEOUT-SECS]  -- run an E2E file inside a non-batch Emacs daemon.
# Batch-mode Emacs dies of SIGPIPE when written to a killed process; a normal Emacs does not.
# Fault-injection tests that kill ssh therefore need a real (daemon) Emacs.
# Env: RDEV_TEST_HOST etc. are inherited.  Exit 0 = all tests as expected.
f=$1; sel=$2; secs=${3:-3000}
cd "$(dirname "$0")/../.." || exit 2
name=rdevtest$$
log=${RDEV_DAEMON_LOG:-/tmp/rdev-daemon-$name.log}
emacs -Q --daemon="$name" -L "$PWD" -L "$PWD/test" --eval "(require 'ert)" >"$log" 2>&1 || { cat "$log"; exit 2; }
trap 'emacsclient -s "$name" --eval "(kill-emacs)" >/dev/null 2>&1' EXIT
out=$(timeout "$secs" emacsclient -s "$name" --eval "(progn (load \"$PWD/test/e2e/$f.el\" nil t) (let ((s (ert-run-tests-batch '$sel))) (with-current-buffer \"*Messages*\" (write-region nil nil \"$log.msgs\" nil 0)) (ert-stats-completed-unexpected s)))" 2>&1)
rc=$?
grep -a "save-fault:\|passed\|FAILED\|Ran \|STALL\|BLOCK\|PARITY" "$log.msgs" | cut -c1-2000
echo "unexpected: $out (emacsclient rc=$rc)  log: $log"
[ "$out" = 0 ]
