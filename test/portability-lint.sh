#!/bin/sh
# Reject GNU-only constructs in shell snippets embedded in the agent, relay,
# client bootstrap and test scripts (FR-004a).  macOS/BSD userland must work.
set -u
cd "$(dirname "$0")/.." || exit 2
files="rdev-server.py rdev-relay.py rdev.el"
for f in test/*.sh test/e2e/*.sh; do [ -f "$f" ] && files="$files $f"; done
pat='(sed +-i( |$)[^'"'"']|readlink +-f|date +-d|grep +(-[a-zA-Z]*P|--perl)|stat +-c|xargs +-r|sort +-V|cp +-[a-zA-Z]*a[a-zA-Z]* +[^ ]|find .* -printf|--no-run-if-empty|mktemp +--|tar +--)'
rc=0
for f in $files; do
  case "$f" in test/portability-lint.sh) continue;; esac
  if grep -nE "$pat" "$f" | grep -v 'portability-ok'; then
    echo "portability-lint: GNU-only construct in $f (append '# portability-ok' to allow)" >&2
    rc=1
  fi
done
[ $rc -eq 0 ] && echo "portability-lint: ok ($(echo $files | wc -w | tr -d ' ') files)"
exit $rc
