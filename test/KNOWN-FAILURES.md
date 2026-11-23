# Known failures (FR-006, Constitution Art. VII)

Tests tagged `:expected-result :failed` (ERT) or `@unittest.expectedFailure` (Python) pin
**confirmed** defects on the unmodified code. Each fix task removes its tag; a tag that
starts passing shows up as an *unexpected* result and must be removed in the same change.
Nothing here is silently ignored: `test/run-all.sh` still exits 0 only if every result is
expected, so a fix that lands without removing the tag fails the run.

**Status (T117): no test is currently tagged as an expected failure.** Every defect below was
fixed, its tag was removed in the same change, and the test now runs as an ordinary
regression test (`sh test/run-all.sh`: all results expected, 0 unexpected).

| Defect | Regression test(s) | Fix task |
|---|---|---|
| D-01 ssh injection | `rdev-kf-d01-*` | T062 |
| D-02 truncated install | `rdev-kf-d02-*` | T052 |
| D-03 unsafe write | `test_d03_*` | M1 agent task |
| D-05 framing | `test_d05_*` | T037+ |
| D-06 channel scoping | `rdev-kf-d06-*`, `rdev-chan-scope-test.el` (incl. aliases of one machine) | T073 |
| D-08 bootstrap byte loss | `rdev-kf-d08-*` | T053 |
| D-09 relay frames | `test_d09_*`, `rdev-kf-d09-*` | T064 |
| D-11 TCP gate | `test_d11_*`, `rdev-kf-d11-*` | T063 |

## Not a behavioral defect: D-07

Plan §3 lists D-07 as an exit-code mismatch (`128 - code` vs `128 + sig`). Running both
paths shows **identical values** (`128 - (-15) == 128 + 15 == 143`), and both `exec/run`
and `proc/exit` already carry the `signal` key. No failing test can be written, so there
is none. `test_signalled_exit_code_current_behavior` and
`test_signal_terminates_with_128_plus_sig` pin the agreement. The remaining work is
readability only (one shared helper); reclassify D-07 from defect to cleanup.

## Resolved: pty stdin lost (was "unconfirmed baseline gap")

`rdev-proc-start-file-process-pty-stdin` was tagged expected-failed. Root cause was in
`rdev-relay.py`: `tty.setraw` used TCSAFLUSH, discarding input already typed into the pty.
Fixed with TCSANOW; the test is now a normal passing regression test. Related relay fix:
signal handlers no longer write frames directly (queue + self-pipe), covered by
`test/py/test_relay_signals.py`. A remote `shell-command` with the default output buffer
used to run locally (`call-process-region` was not redirected); fixed and covered by
`rdev-shell-command-default-output-buffer-runs-remotely`.

## Also noted (documented behavior, no test yet)

Resolved: `rdev.el` used to `setq` `tramp-ignored-file-name-regexp`, replacing any user
value. It now only adds an `/rdev:` alternative (`rdev--tramp-ignore-rdev`); covered by
`rdev-tramp-ignore-preserves-user-regexp`.

## Nested synchronous requests inside timers (jsonrpc.el)

`jsonrpc-request` waits with a `catch`; when a reply for an *outer* request
arrives while an *inner* synchronous request (issued from a timer) is
waiting, the throw unwinds the inner wait silently.  RDEV defers its own
file-notify callbacks while a synchronous request is pending
(`rdev--sync-depth`), but Emacs timers it does not control can still nest:
e.g. `auto-revert` on a VC-tracked remote buffer — the revert runs
`vc-refresh-state` (several synchronous requests) and the 2.5 s lockout
timer may call `auto-revert-buffer` meanwhile.  `test/e2e/notify.el` runs
with `vc-handled-backends` nil for that reason.  Proper fix: replace
`jsonrpc-request` in `rdev--req` with an async request plus a flag-based wait
(planned with the M5 round-trip work, T108).
