#!/bin/sh
# Quality gate (T132, Article IX): byte-compile with warnings as errors, checkdoc,
# docstrings on every public function/defcustom/defvar, and comments on
# concurrency/lifecycle code.  Usage: sh test/check-quality.sh   (EMACS=emacs)
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
EMACS=${EMACS:-emacs}; cd "$root"
exec "$EMACS" -Q --batch -L . -l "$here/check-quality.el"
