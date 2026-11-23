# Quickstart validation results (T115)

Run on 2026-11-23. Client: macOS, Emacs 31.1, Python 3.9.6. Remote: `devbox` (Linux, Emacs 30.2,
Python 3.14.8) over real ssh, plus a throwaway local sshd (`127.0.0.1`, random port).
"Local sshd" = `sh test/e2e/run.sh SCENARIO`; "devbox" = `RDEV_TEST_SSH_TARGET=devbox` form.

| § | What | Result | Evidence |
|---|---|---|---|
| 1 | Baseline: Python + ERT suites | PASS | `sh test/run-all.sh`: 194 Python OK, 201 ERT, 0 unexpected; quality gate PASS |
| 2 | Defect-fix verification D-01, D-02, D-03, D-05, D-06 (incl. aliases of one machine), D-08, D-09, D-11; D-07 (143 both paths) | PASS | regression tests in the suites above; no expected-failure tag remains (`test/KNOWN-FAILURES.md`) |
| 2 | Legacy agent compatibility | PASS | `test/rdev-legacy-compat-test.el` inside the 201 |
| 3 | Real Emacs over ssh, all scenarios | PASS | devbox, 20 scenarios, all results expected (table below); local sshd: baseline, edge-cases, parity, others earlier in the session |
| 4 | Tools: compile, magit, project.el, Eglot (pylsp, clangd), search, Dape | PASS | devbox `compile` 16/16, `magit` 12/12, `eglot-python` 16/16, `eglot-cpp` 14/14, `dape` 13/13, `workflow` 12/12 |
| 5 | Reliability: kill ssh and reconnect | PASS | `reconnect` 12/12, `eglot-reconnect` 9/9 |
| 5 | Save under connection kill, 150 trials | PASS | `save-fault`: 0 corrupt, 0 litter, 0 lost edits (33 saved, 117 failed, 11 of those had committed) |
| 5 | Concurrent external change, 100 trials | PASS | `save-conflict` 9/9 (100/100 reported) |
| 5 | Large file, bounded memory | PASS | `large-file` 10/10 on devbox (424 s). The 500 MiB figure is the earlier run; it was not repeated |
| 5 | Process flood, bounded RSS | PASS | `flood` 10/10; RSS plateau recorded in `test/MILESTONE-REPORT.md` |
| 6 | Performance vs TRAMP at RTT 0/50/150 | PASS (partial) | `bench/results/*.csv`; not run: 1% loss on TRAMP, 1 Mbit/s, Eglot-startup scenario, agent RSS |
| 7 | Blocking behaviour | PASS | `docs/blocking.md`: max timer gap 122 ms at RTT 50 (limit 200) |
| — | Response parity across process APIs | PASS | `parity` 10/10 on devbox and local sshd |

## devbox scenario results (2026-11-23)

baseline 8/8, conflict 10/10, flood 10/10, large-file 10/10, reconnect 12/12, dired 17/17,
compile 16/16, workflow 12/12, magit 12/12 (see note), eglot-python 16/16, eglot-cpp 14/14,
eglot-missing-server 11/11, eglot-reconnect 9/9, dape 13/13, pty 15/15, save-conflict 9/9,
notify 12/12, ownership 14/14, edge-cases 12/12, parity 10/10, stall 4/4 (search test re-run once after adding a missing `require`), save-fault 1/1 (150).
Zero skipped in every scenario that was run (no scenario reported a skip).

**Note, one intermittent failure.** In the all-scenarios pass, `e2e-make-process-streaming`
(shared by every scenario file) failed once, in `magit`: the process was dead with exit status 3
and its output complete, but the user's sentinel had not run. It reproduced about 3 times in 67
isolated runs while the test waited with `(accept-process-output p ...)` for that one process.
Stock Emacs did not reproduce it (0 of 300, with and without a background process and timer),
so **the cause is not established**. After changing the test to wait on all processes (as the
command loop does) it failed 0 of 60. Treat as an open observation, not a fixed defect.

## Not run

Emacs 30.1 and a development snapshot; Windows; a macOS remote host over real ssh; the
Eglot-startup benchmark; agent RSS under the 500 MiB transfer; a timed fresh-user walk-through
(see `docs/VALIDATION.md`).
