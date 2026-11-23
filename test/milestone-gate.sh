#!/bin/sh
# Milestone-close gate (T133, Article XII).  Runs every automated check available
# here and prints an explicit PASS / FAIL / NOT RUN line per item.
# Optional env: RDEV_TEST_SSH_TARGET=host (real-ssh E2E), PYTHON38=/path/to/python3.8
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0
line() { printf '%-34s %s\n' "$1" "$2"; }
if sh test/portability-lint.sh >/dev/null 2>&1; then line "portability lint" PASS; else line "portability lint" FAIL; rc=1; fi
log=$(mktemp /tmp/rdev-gate.XXXXXX)
if sh test/run-all.sh >"$log" 2>&1; then line "unit + ERT suites" PASS; else line "unit + ERT suites" FAIL; rc=1; fi
grep -E '^== python 3.8' "$log" | grep -q 'not run' && line "python 3.8 run" "NOT RUN (no interpreter)" || line "python 3.8 run" PASS
grep -E '^Ran [0-9]+ tests' "$log" | sed 's/^/  /'
if [ -n "${RDEV_TEST_SSH_TARGET:-}" ]; then
  for s in baseline conflict; do
    if sh test/e2e/run.sh "$s" >"$log.$s" 2>&1; then line "e2e $s ($RDEV_TEST_SSH_TARGET)" PASS; else line "e2e $s ($RDEV_TEST_SSH_TARGET)" FAIL; rc=1; fi
  done
else
  sh test/e2e/run.sh baseline >"$log.local" 2>&1 && line "e2e baseline (local sshd)" PASS || line "e2e baseline (local sshd)" "FAIL or NOT RUN"
  line "e2e real remote host" "NOT RUN (set RDEV_TEST_SSH_TARGET)"
fi
line "benchmarks (Article V)" "NOT RUN (bench/ not in this gate)"
line "security review / docs / protocol" "MANUAL: fill test/MILESTONE-REPORT.md"
rm -f "$log" "$log".*
[ $rc -eq 0 ] && echo "GATE: automated checks passed" || echo "GATE: FAILED"
exit $rc
