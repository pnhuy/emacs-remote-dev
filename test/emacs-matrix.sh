#!/bin/sh
# Run the suite under each Emacs binary given as arguments, e.g.
#   test/emacs-matrix.sh emacs /opt/emacs-30.1/bin/emacs
# Appends a line per binary to test/emacs-matrix.md (pass/fail + version).
cd "$(dirname "$0")/.." || exit 2
rc=0
for e in "$@"; do
  v=$("$e" --version | head -1)
  if EMACS="$e" test/run-all.sh >/tmp/rdev-matrix.$$ 2>&1; then r=pass; else r=FAIL; rc=1; fi
  echo "- $(date +%Y-%m-%d) $v: $r" >> test/emacs-matrix.md
  echo "$v: $r"
done
rm -f /tmp/rdev-matrix.$$
exit $rc
