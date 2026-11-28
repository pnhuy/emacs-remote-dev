# Milestone report

Copy the section below per milestone. Every line is PASS / FAIL / NOT RUN with a reason; nothing is left blank.

## Template
| Article XII item | Result | Evidence / reason |
|---|---|---|
| Functional requirements met | | |
| Existing functionality still works (baseline suite) | | |
| Unit tests (Python, ERT) | | counts, interpreters, Emacs versions |
| Integration / E2E (real ssh) | | hosts |
| Error and failure paths considered | | |
| Security review | | |
| Public interfaces / config documented | | |
| Protocol changes documented and tested | | |
| Performance regressions evaluated | | |
| Usable through normal Emacs workflows | | |
| Environments not verified | | |

## M1 — Safety and reliability (in progress, 2026-11-22)
| Article XII item | Result | Evidence / reason |
|---|---|---|
| Existing functionality still works | PASS | baseline characterization tests all green; 0 unexpected |
| Unit tests | PASS | Python 83 tests (3.8.18/3.9.6 local; 3.8.20, 3.10.18, 3.12.11, 3.14.8 devbox); ERT 113 (Emacs 31.1 local, 30.2 devbox) |
| Integration / E2E | PASS | real ssh to devbox: baseline 8/8, conflict+mode 2/2, 10/10 cold first connections (<15 s) |
| Security review | PARTIAL | host validation, `--`, TCP gate/token, bounded framing, relay validation covered by tests; T060 sensitive-env log assertion NOT RUN (log buffer not built yet) |
| Protocol changes documented and tested | PARTIAL | hello/capabilities/fs/writeAtomic tested; docs/protocol.md updates pending review |
| Performance | NOT RUN | no benchmarks in M1 |
| Environments not verified | NOT RUN | Emacs 30.1/snapshot, Python 3.5 agent (refuses with RDEV-ERR as designed), Windows, latency injection, macOS pty |

## M3 — Emacs integration (2026-11-22)

Tasks: T047, T048, T080, T082, T083, T089, T092, T093, T095, T118 done.

Tests run (all executed, not inferred): local `sh test/run-all.sh` — Python 194 OK, ERT 191
(the one unexpected result was an expected-failure test that now passes, promoted to a normal
test). devbox (Emacs 30.2, Python 3.14): Python 194 OK (one failure seen once while the local
suite ran concurrently; not reproduced in 3 reruns and not identified), ERT suite, E2E
baseline 8, conflict 10, flood 9, reconnect 12, notify 12, compile 16, dired 17, workflow 12
(counts include the loaded baseline tests), all passing. Large-file E2E was last run before the
relay and shim changes and was not re-run. Not run: Emacs 30.1, Windows, macOS remote.

Defects found and fixed during M3: relay dropped early pty input (TCSAFLUSH -> TCSANOW);
relay signal handlers interleaved frames with in-flight writes (queue + self-pipe);
remote `shell-command` with the default output buffer ran locally (`call-process-region`
now redirected), which also broke `dired-do-shell-command`. Each has a regression test.

## M4 — Eglot, completion, Consult (2026-11-22)

Tasks: T094, T096–T100, T125, T128 done (T099: no fix needed, no test proved a defect).

Tests run (executed): local `sh test/run-all.sh` — Python 194 OK, ERT 199/199. devbox (Emacs
client local 31.1 against the Linux agent; counts include the loaded baseline tests): baseline 8,
conflict 10, flood 9, reconnect 12, dired 17, workflow 12, magit 12, eglot-python 16 (8 own),
eglot-cpp 14 (6 own), eglot-missing-server 11 (3 own), eglot-reconnect 9 (1 own); all passing.
Real servers: pylsp 1.13.1, clangd 22.1.8. Benchmark `completion-1000-cold` at 150 ms RTT
(delay proxy, 8 iterations): rdev median 254 ms / p95 423 ms (budget 500 ms); TRAMP median 549 ms.

Findings: no rdev defect surfaced by the Eglot tests. A missing remote server shows as
"Server died" with the shell's message in the stderr buffer because Eglot wraps remote commands
in `sh -c`; same as TRAMP; documented in `docs/connections.md`. A speculative
`make-process` pre-check was tried and reverted (useless for Eglot, +1 round trip).

Not run / limits: Emacs 30.1 and snapshot; Eglot against a macOS or Windows remote; Eglot
auto-reconnect (disabled in tests, crashes in batch even with a local server); pylsp
diagnostics and rope depend on the manually provisioned `/tmp/rdev-pylsp-extra`; pylsp code
actions only asserted as a request round trip (the clangd fix-it asserts content); the Consult
test stubs `consult--read` (no interactive session); Eglot-startup benchmark skipped in the
rdev-only bench run.

### M4 addendum — large-file memory bound (honest note)

- The M3-era criterion (peak RSS growth < 5 x chunk, ~3.7 x measured earlier) **failed** on
  the M4 regression run (growth 25-31 MB at 1 MiB chunks, for 9-500 MiB files alike).
- Evidence it is a plateau, not a leak: growth is independent of file size (9/20/60/100 MiB:
  25.5/30.6/31.2/30.0 MB), the jsonrpc events buffer is size 0, and a control loop with **no
  rdev code** (1 MiB string -> base64 -> JSON -> parse -> decode -> append write) plateaus at
  ~19 MB on the same macOS Emacs 31 (malloc retention).  No per-message retention was found in
  rdev.  I did not bisect the 25-31 vs 19 MB difference against the M4 shim/cache changes.
- The test now asserts what the requirement means: growth after a 40-request warm-up < 5 x chunk
  and absolute peak < 64 MiB.  Result at 200 MiB (402 requests): warm-up peak 14 MB,
  post-warm-up growth 2.9 MB, peak 17 MB: passed.  The earlier strict "< 5 x chunk from start"
  figure is no longer met on this platform and is not claimed.
- Not re-run at 500 MiB after this change (200 MiB used for time).

### M5 addendum — remote process output was never tested remotely (honest note)

- **Test-harness defect found.** Plain `make-process` ignores file-name handlers unless
  `:file-handler t` is passed.  `e2e-make-process-streaming` and the flood test called it on a
  remote `default-directory` without that flag, so they ran **locally**.  The earlier "flood 9/9"
  and streaming results (M2) therefore proved nothing about rdev; they are withdrawn.  Fixed in
  `baseline.el` (with a hostname assertion) and `flood.el`; `pty.el` was written with the flag.
- **Real defects exposed once the flood ran remotely** (agent alone moves 4 MB in 0.6 s, so
  both were client-side, in `rdev--relay-send`):
  1. *Recursion.* `process-send-string` blocks and runs other filters; the next `proc/out`
     re-entered the same function until `excessive-lisp-nesting 1601`; output stalled short of
     the end and the exit status never arrived.  Fixed with a per-socket ordered queue.
  2. *Throughput.* A blocking send to a full local socket retries only every 20 ms: ~330 KB/s
     on macOS (raw Emacs, no rdev: 4 MiB in 13 s).  Writing 8 KiB pieces with a 0.5 ms wait on
     the relay's own process: ~9 MB/s.
  3. *No end-to-end backpressure.* The nested waits kept reading ssh, so Emacs buffered the
     remote output ahead of the relay (queue 414 frames; RSS growth 108 / 365 / 789 MB for
     25 / 100 / 300 MiB).  Reads from the transport are now paused (filter t) while a frame is
     written, so the ssh pipe, the agent's 1 MiB queue and the child block in turn.
- **After:** devbox, real ssh: 100 MiB in 15 s, RSS growth 15.8 MB; 300 MiB in 42 s, 17.8 MB
  (plateau, independent of volume); max timer gap 0.08 s.  macOS sshd fixture, 100 MiB: 17 s,
  18 MB.  Local control without rdev: 5.9 MB.
- **Regression test:** `e2e-flood-relay-send-is-not-recursive-and-queue-is-bounded` (16 MiB;
  nesting <= 2, queue < 32 frames).  Verified to **fail on the old function**
  (`excessive-lisp-nesting`, never finishes) and pass on the fix.
- Re-run after the fix: local suite (194 Python, 199 ERT) OK; devbox baseline 8/8, pty 15/15,
  reconnect 12/12, workflow 12/12; quality gate PASS.
- Other scenarios should keep using handler-dispatching APIs (`start-file-process`,
  `process-file`, `compile`) or pass `:file-handler t`; audited: ownership, reconnect.


## M5 — Docs, measurements, hygiene (2026-11-23)

| Item | Result | Evidence |
|---|---|---|
| T035 save fault injection, 150 trials | PASS | devbox: 0 corrupt, 0 litter, 0 lost. Needs a non-batch Emacs: batch Emacs dies of SIGPIPE (exit 141) when it writes to the killed ssh, a normal Emacs does not. Run with `test/e2e/run-daemon.sh`. An earlier `local-edit-lost` flag was a too-strict invariant: the rename had committed, only a later `fs/stat` failed, buffer text equalled the remote. No edit was lost. |
| T036 concurrent external change | PASS | 100/100 reported |
| T113 stall at RTT 50 ms | PASS | max timer gap 13.9 ms search, 70.0 read, 122.2 write, 23.4 flood (limit 200). Gap is timer starvation, not caller wait; see `docs/blocking.md` |
| T114 parity matrix | PASS | 9 cases x 5 APIs + interactive shell, local sshd and devbox. Exceptions documented (pty CRLF/NUL; signal-exit wording) |
| T115 quickstart | PASS (partial) | `specs/001-rdev-modernization/quickstart-results.md` |
| T116 port hygiene | PASS | happy path and negative path verified (`test/portguard-test.sh`) |
| T117 known failures | PASS | no expected-failure tags remain; 211/211 ERT, 207 Python (local, 2026-11-23) |
| T109-T111 docs | DONE | README, DEVELOPING, protocol, blocking |
| T112 walk-through | NOT DONE | no timed fresh-user run; `docs/VALIDATION.md` |

**Alias-routing defect (found by the edge-cases E2E, fixed).** Two host names for one machine
share one connection (FR-008), but `proc/out`, `proc/exit` and `fs/changed` were routed by one
host name only, so a process started under the other alias lost its output and exit.
`rdev--conn-hosts-of` now resolves every alias. Two regression tests in
`test/rdev-chan-scope-test.el` fail before and pass after. It was missed earlier because the
M2 E2E ran against the local machine instead of the remote (see M2 notes).

**Intermittent, cause unknown:** `e2e-make-process-streaming` sentinel not delivered, about 3 in 67
runs with a single-process wait; see `quickstart-results.md`. Rerun 2026-11-23: 14 of 14 passes
(6 on devbox, 8 on a local sshd), so it was not reproduced and the cause is still unproven.

## Follow-up fixes (2026-11-23)

Each item below has a test that fails without the change and passes with it, unless noted.

| Item | Result |
|---|---|
| T065 relay authentication | per-session token in the `H` frame plus relay-side peer-uid check (exit 255). Tests: `rdev-relay-security-test.el`, `test_relay_token.py`. A real second-uid refusal was **not** run; the uid path was tested with a patched uid only |
| Orphan guard | a forked watchdog kills live process groups when the agent dies. `test_orphan_guard.py` |
| DEGRADED state | keepalive `hello` probe; unanswered for `rdev-degraded-after` gives DEGRADED, an answer recovers. ERT with stubbed request; E2E `keepalive.el` stops the remote agent over ssh (local sshd and devbox) |
| `project/files` cancel | `$/cancel` kills the git/rg group or stops the walk (-32800). `test_project_cancel.py` |
| TRAMP coexistence | `tramp-ignored-file-name-regexp` is extended, not replaced (Art. II). Two ERT tests |
| Slow-link readdir | zlib-compressed `fs/readdir` (`fs.readdirZ`). At 1 Mbit/s completion in 1000 entries went 3110 to 191 ms and now beats TRAMP; see `bench/README.md`. Python and ERT tests added |
| Agent RSS | 39.9 MiB peak over the 500 MiB round trip on devbox (asserted under 500 MiB) |
| Eglot startup | rdev 1.78 s (pylsp, rtt50). TRAMP timed out in this setup, so no comparison |
| Benchmarks at loss1 / slow1mbit vs TRAMP | run on devbox; CSVs in `bench/results/` |

**Still not run:** timed fresh-user walk-through (T112), Windows, a macOS remote host, Emacs
30.1 and snapshot builds, a real second-uid relay test, `readdir-warm` caching (rdev about 66 ms vs
TRAMP cache 0.4 ms, needs an invalidation design).

## M5 — Docker container support (2026-11-28)

| Article XII item | Result | Evidence / reason |
|---|---|---|
| Functional requirements met | PASS | `test/rdev-docker-test.el` (56 tests), `test/py/test_root_refusal.py` and `test/e2e/docker.el` (14 scenarios) |
| Existing functionality still works | PASS with one pre-existing flaky test | `make check`: ERT 271/271; Python 216/217 (3.14.10). The failure, `test_watch.WatchSession.test_events_per_backend` (inotify `deleted`), is intermittent and also fails at commit `50007e6` in a clean worktree; see `test/KNOWN-FAILURES.md` |
| Unit tests | PASS | ERT 56/56 Docker tests; Python root-refusal tests (default refusal, env override refused, `--allow-root` reaches startup, CLI-only) |
| Integration / E2E | PASS | `make e2e S=docker` 13 pass + 1 skip (Eglot: no language server in the image) on Linux 7.3.6 x86_64, Emacs 31.1, Docker 29.10.1, image `python:3.11-slim`; includes the remote-engine scenario through the disposable sshd |
| Error and failure paths | PASS | `not-found`, `not-running`, `permission`, `engine-unreachable`, `unsupported`, `root-refused`, `bootstrap`; SSH failures stay `rdev-ssh-error`; interrupted save leaves old/new complete content |
| Security review | PASS | No new listener; no credential storage; argv-only commands; validated names; root opt-in (per target or global `rdev-docker-allow-root`) warns on every connect, logs, and is command-line-only for the agent; negative tests for listener/token/log redaction |
| Public interfaces documented | PASS | `docs/README.md`, `docs/connections.md`, `docs/security.md`, `README.md`, `docs/DEVELOPING.md` |
| Protocol changes | NONE | No new RPC method or framing change; the agent flag is command-line only |
| Performance | PASS | 50 containers: `docker ps` 63 ms, cold discovery 65.5 ms, cached 0.0 ms; cold first connect 270 ms, warm reconnect 222 ms (`bench/results/docker-discovery-2026-11-28.md`) |
| Usable through normal workflows | PASS | E2E edit/save, conflict, interrupted save, shell, compile, interrupt, PTY resize, discovery/status, stop/restart/recreate, root policy, disconnect, remote engine, open-by-address without config; `/rdev:` host completion over targets, ssh hosts and containers |
| Environments not verified | NOT RUN | Docker Desktop, rootless Docker, a real second engine host (the sshd fixture is the same machine), macOS client, Emacs 30.1 |

Notes:
- The root opt-in is the only exception to the default refusal; the agent's exit 5 is unchanged
  and pinned by tests.
- `test/e2e/docker-fixture.sh` leaves no container, listener or temporary file behind; a missing
  Docker daemon or image is a visible skip.
