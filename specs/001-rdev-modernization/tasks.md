---
description: "Task list for RDEV 2.0 incremental modernization"
---

# Tasks: RDEV 2.0 — Incremental Modernization

**Input**: `specs/001-rdev-modernization/` — plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md
**Tests**: REQUESTED by the spec (FR-006, FR-038, SC-012). Test tasks are included and, where stated, written **before** the fix.
**Organization**: By user story. Milestone tags (M1–M5) from plan.md §7 are noted per task; M1 work is spread across US1/US2/US3/US8 and is called out in the MVP section.

## Format: `- [ ] T### [P?] [US#?] Description with file path`

Paths: Elisp in ``, tests in `test/`, Python tests in `test/py/`, E2E in `test/e2e/`, benchmarks in `bench/`, docs in `docs/`. Defect IDs (D-xx, R-xx) refer to plan.md §3.

---

## Phase 1: Setup

- [X] T001 Create directory skeleton `test/`, `test/py/`, `test/e2e/`, `test/fixtures/`, `bench/`, `docs/` with `.gitkeep` where empty
- [X] T002 Copy the **unmodified** `rdev-server.py` to `test/fixtures/legacy-server.py` and record its sha256 in `test/fixtures/legacy-server.sha256` (pinned legacy agent, contracts/protocol.md §6)
- [X] T003 [P] Add `test/run-all.sh` running `python3 -m unittest discover -s test/py -v` then `emacs -Q --batch -L . -L test -l ert -l test/rdev-all-tests.el -f ert-run-tests-batch-and-exit`; exit non-zero on any failure or unexpected skip
- [X] T004 [P] Add `test/rdev-all-tests.el` that loads every `test/rdev-*-test.el`
- [X] T005 [P] Add `test/emacs-matrix.sh` (container/build runner) and `.github/workflows/rdev-tests.yml` running the suite on Emacs 30.1 and latest, plus `test/emacs-matrix.md` recording which versions were actually run (FR-004)

---

## Phase 2: Foundational harness (blocks all stories; contains NO behavior changes)

- [X] T006 Write `test/rdev-test-helpers.el`: macro `rdev-test-with-server` that starts the real `rdev-server.py --stdio` as a local pipe subprocess and registers it as a connection for host `test` (no ssh); also `rdev-test-with-twin-dir` creating a tree plus an identical native copy for contract comparison (research R14)
- [X] T007 [P] Write `test/py/helpers.py`: import `rdev-server.py` via `importlib.util` with in-memory stream pair and a `Session` driver (`call(method, **params)`, `raw(bytes)`) for unit tests
- [X] T008 [P] Write `test/e2e/sshd-fixture.sh`: start unprivileged `sshd` on `127.0.0.1:<random free port>` (check with `ss -ltnp` and never a port listed in `test/e2e/reserved-ports.txt`, created here with 8080, 3007, 8989, 8990, 8384, mirroring `~/AGENTS.md`), throwaway host/user keys, generated `ssh_config`, teardown on exit; prints the port and config path. Also write `test/e2e/run.sh` (starts the fixture, runs the named `test/e2e/*.el` scenario with `emacs --batch`, tears down; extended later by T116 and T124)

**Checkpoint**: harness exists; code under `` is still unmodified. Behavior-changing foundation tasks T009–T013 live in Phase 3b, after the baseline (T030).

---

## Phase 3: User Story 1 — Audit and regression safety net (P1) 🎯 M1

**Goal**: Pin current behavior before any behavior-changing fix; deliver the audit report.
**Independent test**: `test/run-all.sh` passes on the commit that contains only tests (before fixes).

- [X] T014 [US1] Write the audit report `docs/audit.md` from plan.md §3 (client, agent, relay sections; each finding P0–P3 and confirmed vs needs-runtime-verification; missing features, architecture limits, security, performance, compatibility risks) (FR-005)
- [X] T015 [P] [US1] Characterization tests for path parsing, `expand-file-name`, `file-remote-p` and handler dispatch/fall-through in `test/rdev-path-test.el`
- [X] T016 [P] [US1] Handler contract tests comparing results/errors with native Emacs on the twin dir for predicates, attributes, modes, truename, `file-newer-than-file-p` (R-04, R-06) in `test/rdev-handlers-attrs-test.el`
- [X] T017 [P] [US1] Handler contract tests for `insert-file-contents` (visit, beg, end, replace), `write-region` (append, visit, mustbenew), `file-local-copy`, buffer identity after visit, coding systems/encoding in `test/rdev-handlers-io-test.el`
- [X] T018 [P] [US1] Handler contract tests for directory ops (`directory-files(-and-attributes)`, completion, `insert-directory`, make/delete-directory) in `test/rdev-handlers-dir-test.el`
- [X] T019 [P] [US1] Handler contract tests for `copy-file`, `rename-file`, `delete-file`, `set-file-modes/times`, symlink ops (same-host, cross-host, overwrite flags) in `test/rdev-handlers-mutate-test.el`
- [X] T020 [P] [US1] Table test asserting every one of the 53 `rdev-defop` operations has a contract test or an explicit "documented difference" entry in `test/rdev-handlers-coverage-test.el`; unsupported ops signal rather than succeed; the 7 deliberate no-op stubs (`file-acl`, `file-selinux-context`, `set-file-acl`, `set-file-selinux-context`, `lock-file`, `unlock-file`, `file-locked-p`) are listed as documented differences, each stating its return value (FR-001, FR-003, FR-012)
- [X] T021 [P] [US1] Cache tests: hit/miss, TTL, per-conn isolation, disappearing file, invalidation after each mutating op (enumerate mutators) in `test/rdev-cache-test.el`
- [X] T022 [P] [US1] Error mapping tests (ENOENT, EACCES, EEXIST, ENOTDIR, timeout) in `test/rdev-errors-test.el`
- [X] T023 [P] [US1] Python tests for every frozen RPC method against a temp dir in `test/py/test_methods_fs.py`
- [X] T024 [P] [US1] Python tests for `exec/run`, `proc/*`, `project/files` (incl. exit codes, pty, signals, stdin/EOF) in `test/py/test_methods_proc.py`
- [X] T025 [P] [US1] Relay frame tests (encode/decode, partial reads, signal forwarding, resize, EOF) driven against `rdev-relay.py` with a fake Emacs socket in `test/py/test_relay.py`
- [X] T026 [P] [US1] Process integration tests for `make-process`, `start-file-process`, `process-file`, `shell-command`, filters/sentinels/buffers/stderr/env/cwd in `test/rdev-process-test.el` (R-04, FR-020)
- [X] T027 [P] [US1] TRAMP coexistence test (`tramp-ignored-file-name-regexp`, handler order) in `test/rdev-tramp-test.el` (R-09)
- [X] T028 [US1] Add known-failure tests for each confirmed defect (D-01 injection, D-02 truncated install, D-03 unsafe write, D-05 framing, D-06 chan scoping, D-07 exit codes, D-08 bootstrap byte loss, D-09 relay frames, D-11 TCP gate) tagged `:expected-result :failed` with the defect id in the docstring; list them in `test/KNOWN-FAILURES.md` (FR-006)
- [X] T029 [US1] Pin legacy-agent compatibility: run T023/T024 and client tests against `test/fixtures/legacy-server.py` in `test/rdev-legacy-compat-test.el` (FR-002, contracts/protocol.md §6)
- [X] T030 [US1] Create a regression baseline commit containing only tests/docs; run `test/run-all.sh` on the unmodified code and store the result in `test/BASELINE.md`, and create an empty `test/INTENTIONAL-CHANGES.md` where every deliberate behavior change is logged (acceptance M1-1); every INTENTIONAL-CHANGES entry MUST record justification, migration path and the test id that covers it (Article I)
- [X] T031 [US1] E2E baseline over real sshd for open/save/dired/shell/process-file in `test/e2e/baseline.el` run by `test/e2e/run.sh`; run on Linux and, where a macOS host is available, record macOS pass/fail/not-run in `test/e2e/PLATFORMS.md` (FR-004a, R-03)

**Checkpoint**: baseline suite green on unmodified code; every known defect has a failing-by-design test.

---

## Phase 3b: M1 foundational fixes (after baseline T030) 🎯 M1

**Gate**: T030 baseline commit exists and is green. These tasks change agent/client behavior, so each flips its pre-written known-failure test (T028) from expected-fail to pass.

- [X] T009 Agent framing validation (D-05, FR-029, M1): in `rdev-server.py` `Session.read_message` enforce header ≤ 8 KiB and ≤ 32 lines, decimal `Content-Length` with `0 ≤ n ≤ max_message` (default 33554432), JSON-object body; return `-32700/-32600` errors when an id is recoverable, otherwise log to stderr and close the session; convert `TypeError` from `fn(**params)` to `-32602`; never let an exception escape `serve()` (contracts/protocol.md §1)
- [X] T010 Agent lock for shared state (FR-019, R-02, M1): add `threading.Lock` for `procs`/`next_id` and the write path in `rdev-server.py`; register `Proc` in `procs` before starting its threads in `m_proc_spawn`
- [X] T011 Extend `m_hello` additively in `rdev-server.py` (FR-011, M1): add `protocol` (int), `capabilities`, `limits`, `agent_hash`, `platform`; accept optional `client` param without breaking the zero-arg legacy call; add Python ≥ 3.8 runtime check producing a structured error (FR-004b)
- [X] T012 Client negotiation in `rdev.el` (FR-011, M1): extend `rdev-conn` with `state gen proto caps limits transport log stats procs policy` slots (`policy` is reserved; only `terminate` is implemented) appended after existing ones; `rdev--connect` always sends a zero-param `hello` first (the legacy agent rejects params with `-32603`, so no behavior may depend on an error code), sends the advisory `client` hello only when the result has `protocol`, treats missing `protocol` as legacy 1.0, rejects an unsupported major with an actionable message
- [X] T013 [P] Define now, for use by later stories, `rdev-conflict` and `rdev-connection-lost` error symbols (children of `file-error`) with messages in `rdev.el`; extend `rdev--signal-error` to map `-32010/-32011/-32012/-32013/-32800` (contracts/protocol.md §1); add `rdev-ssh-error`, `rdev-transport-error`, `rdev-agent-error`, `rdev-filesystem-error`, `rdev-process-error` classes (FR-040)

**Checkpoint**: agent survives malformed input, negotiation works with legacy and new agents, regression suite still green versus `test/BASELINE.md`.

---

## Phase 4: User Story 2 — Edit remote files without data loss (P1) 🎯 M1/M2

**Goal**: atomic, version-checked saves; chunked large transfers; correct cache; notifications.
**Independent test**: fault-injected saves never corrupt (SC-002); external edits always conflict (SC-003).

### Tests first
- [X] T032 [P] [US2] Python tests for `fs/writeAtomic`: temp in same dir, perms preserved, symlink target, hardlink/non-regular fallback with `atomic:false`, CONFLICT on stale version, create-vs-exists, fsync calls, `os.replace` failure leaves original intact in `test/py/test_write_atomic.py`
- [X] T033 [P] [US2] Python tests for chunk family (offset checks, size limits, hash/size verify at commit, idle abort, session-end cleanup, abort idempotent) in `test/py/test_chunks.py`
- [X] T034 [P] [US2] ERT save tests: version recorded at visit, conflict refusal, refresh/compare/overwrite flows, append stays non-atomic, legacy-agent fallback message in `test/rdev-save-test.el`
- [X] T035 [US2] Fault-injection E2E: 100 saves with the connection killed at random points; assert 0 corrupt/truncated remote files and 0 lost local edits (SC-002) in `test/e2e/save-fault.el`
- [X] T036 [P] [US2] E2E concurrent external modification test (100% reported, SC-003) in `test/e2e/save-conflict.el`

### Implementation
- [X] T037 [US2] Implement `fs/writeAtomic` in `rdev-server.py` per research R3 (O_EXCL temp in dest dir, write, fsync, copy mode/owner, verify `{mtime_ns,size,ino,dev}` and optional sha256 immediately before `os.replace`, dir fsync best effort, `CONFLICT -32010`, symlink follow default, non-atomic fallback flagged); advertise `fs.writeAtomic` (FR-013, M1)
- [X] T038 [US2] Add FileVersion to `fs/read`/`fs/write`/`fs/stat` results taken from the open fd (`ino`,`dev`,`version`) in `rdev-server.py`, keeping existing keys (R-07)
- [X] T039 [US2] Client: record version in buffer-local `rdev--version`+conn `gen` at `insert-file-contents`; use `fs/writeAtomic` in `write-region` for whole-file saves when capable; keep `fs/write` for append/legacy; signal `rdev-conflict` in `rdev.el`
- [X] T040 [US2] Conflict UI: implement refresh / compare (diff buffer vs remote copy) / explicit-confirm overwrite via `rdev-conflict-functions` in `rdev.el`; no silent overwrite path (FR-014)
- [X] T041 [US2] Chunk methods `fs/readChunk`, `fs/beginWrite`, `fs/writeChunk`, `fs/commitWrite`, `fs/abortWrite` with `max_chunk`/`max_transfer`, incremental sha256, idle timeout 120 s, cleanup on session end, in `rdev-server.py` (M2, FR-015)
- [X] T042 [US2] Client chunked read/write path using `rdev-chunk-size` and `rdev-large-file-threshold`, bounded memory, no full-file duplicate buffers, `C-g` safe abort, in `rdev.el`
- [X] T043 [US2] Cache: `rdev-cache-max-entries` with oldest-first eviction, stats counters, invalidate target+parent in every mutating handler, drop on `gen` change, `rdev-clear-cache` host prefix arg in `rdev.el` (FR-016)
- [X] T044 [P] [US2] `fs/statMany` method (cap `fs.statMany`) and client prefetch from `readdir attrs=true` in `rdev-server.py` and `rdev.el` (M2)
- [X] T045 [P] [US2] Symlink/special-file/path validation for all `fs/*` params in `rdev-server.py` (reject NUL, non-string, relative where absolute is required; no silent symlink behavior change; each newly rejected input is logged in `test/INTENTIONAL-CHANGES.md`) (FR-035)
- [X] T046 [P] [US2] Python tests for T045 validation in `test/py/test_fs_validation.py`
- [X] T047 [P] [US6] Watch backends in `rdev-server.py`: inotify via `ctypes`, `select.kqueue`, polling fallback; methods `watch/add`, `watch/remove`, notification `watch/event`; cleanup at session end (M3, FR-017); tests in `test/py/test_watch.py`; define a `WatchBackend` interface (add/remove/poll) so platform-specific code stays isolated (Article VI)
- [X] T048 [US6] Client file-notify bridge in new `rdev-notify.el` replacing the `file-notify-add-watch` stub; descriptor mapping, `file-notify-rm-watch`, re-register via `rdev-reconnected-hook` after reconnect, drop on disconnect; ERT in `test/rdev-notify-test.el`; E2E `auto-revert-mode` sees external change ≤ 2 s (native backend); watch events invalidate the target and parent cache entries (FR-016); milestone M3

**Checkpoint**: saves are atomic and conflict-checked; large files transfer in bounded memory; watchers work.

---

## Phase 5: User Story 3 — Reliable connections (P1) 🎯 M1/M2

**Goal**: robust bootstrap, deterministic state machine, bounded reconnect.
**Independent test**: kill ssh mid-session → automatic recovery, nothing replayed.

### Tests first
- [X] T049 [P] [US3] Bootstrap tests with a fake `ssh` shim: noisy login banners, split markers, bytes following marker, interrupted upload at N random prefixes (100 trials), corrupt file, old Python, missing sha tool, leftover `.tmp` in `test/rdev-bootstrap-test.el` and `test/e2e/bootstrap.sh`; assert ≥ 99/100 first-connection successes and < 15 s on a low-latency link excluding download (SC-004)
- [X] T050 [P] [US3] State-machine ERT: every transition in data-model.md, illegal transitions ignored+logged, no duplicate connection for concurrent connects in `test/rdev-state-test.el`
- [X] T051 [P] [US3] Reconnect E2E: `kill -9` ssh; assert RECONNECTING→CONNECTED within backoff (≥95% of trials within 30 s of recovery, SC-005), buffers intact, pending requests fail with `rdev-connection-lost`, processes marked interrupted, no replay, cached metadata refreshed and `rdev-reconnected-hook` run once after reconnect (FR-009; watcher and project-context re-registration are asserted in T048 and T095), first save after reconnect re-checks version in `test/e2e/reconnect.el`

### Implementation
- [X] T052 [US3] Rewrite bootstrap remote script in `rdev.el` `rdev--ssh-process` (D-02, D-08, D-14, M1): size + sha256 verification (`sha256sum`/`shasum -a 256`/python fallback), install via `.tmp` + `mv` only on match, remove `.tmp` otherwise, `umask 077`, `chmod 700` dir, Python ≥ 3.8 probe, `RDEV-BOOT <json>` lines and final `RDEV-READY`, existence check by size/hash not `-f`
- [X] T053 [US3] Replace marker-in-filter parsing: consume only through the newline after `RDEV-READY`, pass residual bytes to jsonrpc, structured bootstrap error object, in `rdev.el` (D-08, FR-007); bootstrap failures are signaled as `rdev-ssh-error` (ssh exit/auth/host-key) or `rdev-agent-error` (bad handshake/version) (FR-040)
- [X] T054 [US3] Create `rdev-state.el`: state variable transitions via one function, log, `rdev-connection-state-hook`, single in-flight attempt per logical session, where the session key is the canonical `(user, hostname, port)` from `ssh -G <host>` so two aliases of one host share one connection (FR-008); `require` from `rdev.el`; `rdev-state.el` MUST NOT `require` `rdev` (it exposes hooks and callbacks that `rdev.el` fills in), enforced by T129
- [X] T055 [US3] Reconnect timer with bounded exponential backoff + jitter (`rdev-reconnect`, `-base`, `-cap`, `-max-attempts`), pending-request failure, `gen` increment, cache drop, then run `rdev-reconnected-hook` (consumers register themselves: T048 watchers, T093 project context), in `rdev-state.el` (FR-009). Defaults: base 1 s, cap 10 s, jitter ±20 %, max-attempts 30, so the first retry after network recovery lands within 10 s and, with SC-004's connect time, SC-005's 30 s bound holds
- [X] T056 [US3] Mark owned chans `interrupted` and send relay `X 255` on loss; never replay `exec/run`/`proc/spawn`; document in `docs/connections.md` and `rdev.el`
- [X] T057 [P] [US3] `session/shutdown` method and `proc.ownership` capability (terminate process groups: SIGHUP then SIGKILL after `grace_ms` 2000) in `rdev-server.py`; Python tests in `test/py/test_shutdown.py` (FR-021)
- [X] T058 [P] [US3] Per-connection log buffer `*rdev-log HOST*` (stderr + transitions, `rdev-log-max-lines`) in `rdev-state.el`; redact sensitive environment values (token/secret/password/key names) and tokens before writing to the buffer (FR-034)

**Checkpoint**: bootstrap cannot install a truncated agent; connection survives faults without data loss.

---

## Phase 6: User Story 8 — Secure by default (P2) 🎯 M1/M2

**Goal**: no injection, TCP gated, private relay socket, validated frames.
**Independent test**: every G1–G4 behavior has an automated test (SC-012).

- [X] T059 [P] [US8] Tests: host validation and `--` in ssh argv using a fake `ssh` recording argv; `/rdev:-oProxyCommand=id:/p` signals `user-error` and never spawns (D-01); static test that rdev code never reads or stores a password or passphrase and persists no key material (prompts stay with ssh/askpass, FR-033) in `test/rdev-security-ssh-test.el`
- [X] T060 [P] [US8] Tests: TCP non-loopback refused without opt-in, warning on every connect with opt-in, 5 failed auths close, `--token` argv warning, `--token-file`/`RDEV_TOKEN`, token never appears in logs, `rdev-status` or messages, generated token ≥ 128 bits in a 0600 file (FR-034) in `test/py/test_tcp_security.py` and `test/rdev-security-tcp-test.el`; also assert that sensitive environment variable values never appear in `*rdev-log HOST*`, messages or debug output
- [X] T061 [P] [US8] Tests: relay frame cap (16 MiB), unknown type, bad `H`/`X` payload, socket dir 0700/file 0600, peer-uid check in `test/py/test_relay_security.py` and `test/rdev-relay-security-test.el`
- [X] T062 [US8] Host validation (charset, no leading `-`) and `--` before the host in `rdev--ssh-process`; validate `:ssh-host` the same way; reject at connect in `rdev.el` (D-01, FR-033, M1)
- [X] T063 [US8] TCP gate: `rdev-allow-insecure-tcp`/`:insecure-ok`, warning, refuse by default for non-loopback in `rdev--tcp-process`; agent default bind `127.0.0.1` with warning on `0.0.0.0`; auth-failure limit; `--token-file`/env preferred, `--token` warns, generated tokens from `secrets.token_urlsafe(32)` stored 0600 and redacted in all logs/status output, in `rdev.el` and `rdev-server.py` (D-11, FR-034)
- [X] T064 [US8] Relay hardening in `rdev-relay.py` and `rdev.el` (`rdev--relay-filter`, `rdev--relay-frame`): length cap, type validation, malformed → `X 255`/exit 255, no exception out of the filter (D-09, FR-036, M1)
- [X] T065 [US8] Relay socket in private dir `$XDG_RUNTIME_DIR/rdev` (fallback `~/.cache/rdev/run`) mode 0700, socket 0600 via `umask 077`, `SO_PEERCRED`/`LOCAL_PEERCRED` check, in `rdev.el` `rdev--relay-socket` (D-10)
- [X] T066 [P] [US8] Document SSH tunneling as the recommended TCP setup and the security model in `docs/security.md` (FR-034)

---

## Phase 7: User Story 5 — Commands, shells, builds (P2) 🎯 M1/M2/M3

**Goal**: correct process lifecycle and compile.
**Independent test**: output byte-identical to local execution; exit codes exact (SC-007).

- [X] T067 [P] [US5] Tests: exit code `128+sig` identical for `exec/run` and `proc/exit`; `signal` key present (D-07) in `test/py/test_exit_codes.py`
- [X] T068 [P] [US5] Tests: two connections allocating the same channel id route output correctly (D-06) in `test/rdev-chan-scope-test.el`
- [X] T069 [P] [US5] Tests: process output fully delivered before `proc/exit` including >2 s drain, `truncated` flag when abandoned (R-01) in `test/py/test_proc_drain.py`
- [X] T070 [P] [US5] Tests: bounded output queue under a stalled consumer for 60 s of flooding stays within the documented limit (SC-009) in `test/e2e/flood.el` and `test/py/test_backpressure.py`
- [X] T071 [P] [US5] Tests: cancellation of `exec/run` frees thread and process group ≤ 2 s (SC-008) in `test/py/test_cancel.py`
- [X] T072 [US5] (FR-018) Normalize signalled exit code to `128+sig` in `exec/run` and `Proc._reap`, add `signal` key, log the deliberate change in `test/INTENTIONAL-CHANGES.md`, in `rdev-server.py` (D-07, research R16)
- [X] T073 [US5] Scope `rdev--chans` by `(host . id)` and add `host`/`status`/`exit` to `rdev-chan` in `rdev.el` (D-06, research R17)
- [X] T074 [US5] Bounded per-process output queue (default 1 MiB, 64 KiB chunks) with blocking pumps; define disconnect behavior (owned processes terminated) in `rdev-server.py` (FR-032, research R7, D-13)
- [X] T075 [US5] Drain-before-exit: join pumps until drained or process group dead plus 10 s, then `proc/exit` with `truncated` if abandoned, in `Proc._reap` of `rdev-server.py` (R-01)
- [X] T076 [US5] Bounded worker pool (`--workers`, default 8) replacing ad-hoc threads for `exec/run`, `project/files`, `search/grep`, chunk reads; unbounded `exec/run` stdout buffering capped with `TOO_LARGE` in `rdev-server.py` (FR-030, D-12); log the new `TOO_LARGE` behavior in `test/INTENTIONAL-CHANGES.md`
- [X] T077 [US5] `$/cancel` notification, in-flight registry with events, `-32800` response, process-group kill for `exec/run`, cap `cancel`, in `rdev-server.py`; client `C-g` in `rdev--req` sends cancel (FR-031, research R8) in `rdev.el`
- [X] T078 [US5] Clean `search/grep` stub: until implemented return `-32012 UNSUPPORTED` (not `-32601`), remove it from the threaded set and capabilities, in `rdev-server.py` (D-04, M1)
- [X] T079 [US5] Document operations that cannot be cancelled safely in `docs/protocol.md` (FR-031)
- [X] T080 [US5] Verify relay `sendall` interleaving from signal handlers (R-05): stress test in `test/py/test_relay_signals.py`; fix by queueing signal frames to the main loop in `rdev-relay.py` if reproduced
- [X] T081 [US5] Verify pty behavior on macOS (R-03): `test/e2e/pty.el` (resize, SIGINT, EOF, process-group kill); rerun at every milestone close (first run in M1 via T124 when a macOS host exists, otherwise record 'not run'); record result in `test/e2e/PLATFORMS.md`; fix `rdev-server.py` only if it fails
- [X] T082 [US5] Verify `shell-command`/`async-shell-command` shim (D-16) and shell/comint in `test/rdev-shell-test.el`; fix `rdev.el` only if tests fail
- [X] T083 [US5] `M-x compile`/`recompile` on remote dirs: streamed output, exit status, `next-error` to `/rdev:` files, cancel, ANSI colors; tests in `test/e2e/compile.el`; patch `rdev.el` only where tests fail (FR-026, M3)

---

## Phase 8: User Story 4 — Connection management UI (P2) M2

**Independent test**: list view shows state/latency/procs; all keys work.

- [X] T084 [P] [US4] ERT for commands and list view contents/keys in `test/rdev-ui-test.el`
- [X] T085 [US4] Create `rdev-ui.el` with `rdev-connect`, `rdev-reconnect`, `rdev-restart-server`, `rdev-show-logs`, `rdev-list-connections` (`tabulated-list-mode`: Host, State, Latency, Procs, Cache, Agent, Protocol; keys `c r k R l g`); autoload from `rdev.el` (FR-010)
- [X] T086 [US4] Extend `rdev-status` output with state column, keep existing text; mode-line state indicator in `rdev.el`
- [X] T087 [US4] Cache stats/inspection command (`rdev-cache-stats`) in `rdev-ui.el` (FR-016)

---

## Phase 9: User Story 6 — Projects, search, completion (P2) M3/M4

**Independent test**: project-find-file on a 10k-file repo; search with and without ripgrep.

- [X] T088 [P] [US6] Tests for `search/grep` (literal, regex, glob, ignore, max results, context, streaming, cancel, rg vs python engine equality, missing-tool path) in `test/py/test_search.py`
- [X] T089 [P] [US6] Tests for `project/root` and `project/files` (markers, git fast path, no file contents transferred) in `test/py/test_project.py` and `test/rdev-project-test.el`
- [X] T090 [US6] Implement `search/grep` in `rdev-server.py` (rg `--json` without shell, batches ≤100 matches/50 ms, python fallback via `git ls-files` or walk, `engine` key, never empty-success when no engine) (FR-023, research R11)
- [X] T091 [US6] Client in new `rdev-search.el`: `rdev-search` command with xref/grep-style results, incremental display, cancel (FR-023); Consult is added separately in T125
- [X] T092 [US6] `project/root` method (cap `project.root`) in `rdev-server.py`; extend `project/files` with git fast path and marker config (FR-022)
- [X] T093 [US6] New `rdev-project.el`: `project-find-functions` entry, `project-files`, `rdev-project-markers`, remembered remote projects for `project-switch-project`; adds a function to `rdev-reconnected-hook` that re-establishes project context after reconnect; fallback for legacy agent (FR-022, research R12)
- [X] T094 [US6] Completion latency: single-RPC `file-name-all-completions`/`-completion` using `readdir attrs=true` + `fs/statMany`, short completion cache; assert a 1000-entry directory completes in ≤ 2 round trips and ≤ 500 ms at 150 ms RTT (bench scenario) in `rdev.el` (FR-024)
- [X] T095 [US6] E2E: open project, find file, search, edit, save, compile, jump to error with no non-standard workflow (SC-010) in `test/e2e/workflow.el`; E2E also verifies that the active major mode and the user's mode hooks/customizations run on RDEV buffers (Article II)

---

## Phase 10: User Story 7 — Eglot, Git/Magit, Dape (P3) M3/M4

**Independent test**: real tools run end-to-end (never static inspection).

- [X] T096 [P] [US7] Magit E2E on a remote repo: status, diff, stage, commit, log, branch create/checkout; verify state with independent remote `git` in `test/e2e/magit.el`; skip with visible reason if magit missing (FR-027)
- [X] T097 [P] [US7] Eglot E2E with real `pylsp` (Python project): diagnostics, completion, definition, references, rename, code action, server kill → restart in `test/e2e/eglot-python.el` (FR-025, SC-011)
- [X] T098 [P] [US7] Eglot E2E with real `clangd` (C++ project, `compile_commands.json`) same checklist in `test/e2e/eglot-cpp.el`
- [X] T099 [US7] Fix only what T096–T098 prove broken (`make-process` keywords, `file-local-name`/URI mapping, trailing-slash `default-directory`, `executable-find` remote) in `rdev.el`; add `rdev-eglot.el` only if URI mapping needs a shim; record each fix against its failing test
- [X] T100 [US7] Handle LSP server restart/disconnect through reconnect (FR-025) in `rdev-state.el` + `test/e2e/eglot-reconnect.el`
- [X] T101 [US7] Dape fixture: create a venv on the test remote with `pip install debugpy`; tests tagged `:needs-debugpy` skip visibly if install fails, in `test/e2e/dape-fixture.sh`
- [X] T102 [US7] Dape E2E: launch `debugpy` adapter remotely, breakpoint hit, local↔remote path mapping, working dir, process I/O, termination kills adapter, reconnect behavior in `test/e2e/dape.el` (FR-028, M5, after T097–T098 and T083 pass)
- [X] T103 [US7] Dape compatibility fixes proven by T102 and a documented config recipe in `docs/dape.md` (FR-028)

---

## Phase 11: User Story 9 — Performance and documentation (P3) M2/M5

**Independent test**: benchmark suite produces CSVs for every operation × scenario; docs followable.

- [X] T104 [P] [US9] Benchmark driver `rdev-bench.el` + `bench/run.sh`: connect+bootstrap, stat, open, save, readdir, project enumeration, search, process start, shell echo latency, Eglot startup; records median/p95/failures/RSS and UI-blocked time (FR-037, plan "blocking")
- [X] T105 [P] [US9] Network shaping `bench/netem.sh`: `unshare -rn` + `tc netem` for RTT 0/50/150 ms, 1% loss, 1 Mbit/s, connection interruption; fallback delay/loss proxy `bench/delay-proxy.py` (stdlib), report says which was used (FR-037)
- [X] T106 [US9] TRAMP comparison harness using identical files/remote in `bench/tramp-compare.el` (FR-037, SC-013)
- [X] T107 [US9] Record baseline CSVs in `bench/results/baseline-<date>.csv` before any performance change; regression check script `bench/compare.py` flagging >20% regressions (SC-013)
- [X] T108 [US9] Measure-then-optimize: only for bottlenecks present in T107 (batching, prefetch, streaming), each with before/after CSV in `bench/results/`
- [X] T109 [P] [US9] Install and user guide `docs/README.md` (install, first connection, SSH config, TCP/tunnel, commands, customization, troubleshooting) (FR-039, SC-014)
- [X] T110 [P] [US9] Developer guide `docs/DEVELOPING.md` (layout, running all suites, sshd fixture, adding an RPC with capability, release checklist) (FR-039, SC-014)
- [X] T111 [P] [US9] `docs/protocol.md` mirroring contracts/protocol.md with the non-cancellable list, plus `docs/blocking.md` explaining unavoidable synchronous blocking (plan table) and stating that atomic visibility of saves is distinct from power-loss durability (FR-013), and documenting the per-process output-queue limit (default 1 MiB, T074) (FR-032, SC-009)
- [ ] T112 [US9] Walk-through validation: a fresh user follows `docs/README.md` timed ≤ 15 min; a contributor runs all suites from `DEVELOPING.md`; record in `docs/VALIDATION.md` (SC-014)

---

## Phase 12: Polish and cross-cutting

- [X] T113 Responsiveness measurement for SC-006: instrument the max command-loop stall during search, large transfer and process flood at RTT ≤ 50 ms (must be ≤ 200 ms) and record the blocking time of synchronous handlers; publish both and the sync-API limits in `docs/blocking.md`
- [X] T114 Byte-for-byte output and exit-code parity matrix across `make-process`, `start-file-process`, `process-file`, `shell-command`, compile, shell (SC-007) in `test/e2e/parity.el`
- [X] T115 Run full quickstart.md validation (sections 1–7) and record dated results in `specs/001-rdev-modernization/quickstart-results.md`
- [X] T116 Port hygiene: `test/e2e/run.sh` and `bench/` assert at teardown, via `ss -ltnp`, that every fixture listener was on `127.0.0.1` with a random port outside `test/e2e/reserved-ports.txt` (T008) and is gone; fail otherwise
- [X] T117 Remove `:expected-result :failed` markers as defects are fixed and empty `test/KNOWN-FAILURES.md`; final regression run vs `test/BASELINE.md` (SC-001)

## Phase 13: Gap-closure tasks (added by /speckit-analyze)

- [X] T118 [US6] Dired E2E over real sshd: `dired` listing, sort, mark, copy, rename, delete, `find-file`, `dired-do-shell-command`, revert after external change, compared with native results, in `test/e2e/dired.el` (spec M3)
- [X] T119 [US3] Ownership on failure paths (FR-021): kill the local relay while a remote process runs, kill ssh, and make the agent exit; assert the remote process group is terminated within `grace_ms`+2 s (the only implemented policy; keep-alive is neither offered nor advertised, FR-021), and the client sends `proc/signal` on relay EOF without `X`; implement in `rdev.el` (`rdev--relay-sentinel`) and test in `test/e2e/ownership.el`
- [X] T120 [US8] Agent refuses to run as uid 0 unconditionally (no override flag or env var exists), with a clear message (FR-035, Article IV); `test/py/test_root_refusal.py` monkeypatches `os.geteuid`; edit `rdev-server.py`
- [X] T121 [US3] Client-side protocol validation (FR-029): reject responses missing `jsonrpc`/`id`, with both or neither of `result`/`error`, unknown ids, malformed notifications or an unsupported protocol, without raising out of the process filter; tests in `test/rdev-response-validation-test.el`; edit `rdev.el`
- [X] T122 [US5] Deadlock/race stress (FR-019): 200 concurrent mixed requests (`exec/run`, `proc/spawn`, `fs/*`, cancel) plus flood and `session/shutdown`, watchdog 30 s, repeated 20 times, in `test/py/test_concurrency.py`; fix lock ordering in `rdev-server.py` if it fails
- [X] T123 [US2] Edge cases: two Emacs sessions editing one file (second save conflicts), same host via two aliases shares one connection and cache identity, non-UTF-8 and mixed-coding files round-trip byte-exact, in `test/e2e/edge-cases.el`
- [X] T124 [US1] macOS portability (FR-004a): `test/e2e/run.sh` accepts `RDEV_TEST_SSH_TARGET` to run against an external Linux or macOS host; `test/portability-lint.sh` rejects GNU-only flags in agent, relay and test scripts; record each run as pass/fail/not-run per platform in `test/e2e/PLATFORMS.md`
- [X] T125 [US6] Optional Consult adapter in `rdev-search.el`, loaded only when `consult` is present; test with and without it (FR-024; spec M4)
- [X] T126 [US1] Python 3.8 compatibility (FR-004b): `test/py/test_py38_compat.py` parses `rdev-server.py` and `rdev-relay.py` with `ast.parse(..., feature_version=(3,8))` and scans for 3.9+ APIs (`removeprefix`, `dict |`, `zoneinfo`, builtin generics); `test/run-all.sh` also runs `test/py` under `python3.8` when present, otherwise records 'not run'; edit the agent only if it fails; the explicit test matrix lists each supported Python version (3.8 minimum plus the newest available) and records every unavailable version as 'not run' with the reason (Article VI)
- [X] T127 [US2] Large-file E2E (plan M2 acceptance, FR-015): 500 MB round trip through the chunked path with RSS growth < 3× `rdev-chunk-size`, hash verified, interrupted transfer leaves no stray remote data, in `test/e2e/large-file.el`
- [X] T128 [US7] Missing language server (spec edge case): host lacks `pylsp`/`clangd` → actionable error and no hang, in `test/e2e/eglot-missing-server.el`; fix `rdev.el` only if the test fails
- [X] T129 [US3] Load-order and circularity check (FR-039): `test/rdev-load-order-test.el` loads each `*.el` alone in a fresh `emacs -Q --batch -L .`, asserts it loads with only its documented requires and that `rdev-state.el` does not require `rdev`
- [X] T130 [US8] Argv-only execution test: `test/py/test_argv_exec.py` proves commands run via argv, that metacharacters in args/paths/env values (`;`, `$()`, backticks, quotes, newlines) are never interpreted by a shell, and that no `shell=True` is used in `rdev-server.py` (FR-033, Article IV)
- [X] T131 [US1] Error-class test: `test/rdev-error-classes-test.el` provokes ssh, transport, agent, filesystem and process failures and asserts each yields its distinct error symbol and message (FR-040, Article X)
- [X] T132 [US9] Quality gate: run `checkdoc`, byte-compile with warnings as errors on `*.el`, and verify every public function/defcustom has a docstring and complex concurrency/lifecycle code has comments; script in `test/check-quality.sh` (Article IX)
- [X] T133 [US1] Milestone-close gate: `test/milestone-gate.sh` plus `test/MILESTONE-REPORT.md` template recording Article XII definition-of-done items per milestone (tests run, 'not run' environments, security review, docs, protocol changes, perf) (Article XII)

---

## Dependencies and order

- Phase 1 → Phase 2 (harness only, no behavior changes) → Phase 3 (US1 tests T014–T031, baseline T030) → Phase 3b (T009–T013) → everything else. Phase 3 tests must be **committed and green before any fix task** (T009–T013, T037+, T052+, T062+, T072+).
- M1 critical-fix set (needs T030): T009, T010, T011, T012, T013, T037–T040, T052, T053, T060, T062–T064, T072, T073, T078, T130, T131.
- US2 (T032–T048) depends on Phase 2; T041/T042 (chunks) depend on T037.
- US3 (T049–T058) depends on Phase 2; T055 depends on T054; T056 depends on T055 and T073.
- US8 (T059–T066): T062 can start right after T030; T063 depends on T012.
- US5 (T067–T083): T074/T076/T077 depend on T010; T083 depends on T072, T073.
- US4 (T084–T087) depends on T054, T058.
- US6 (T088–T095): T090 depends on T076, T077, T078; T093 depends on T092; T095 depends on T083, T090, T093.
- US7 (T096–T103): depend on US5 compile (T083) and US3 reconnect (T055); T102 (M5) depends on T097, T098, T083, T101.
- US9 (T104–T112): T104–T107 baseline should run right after M1 (parallel with M2); T108 after T107.
- Polish after all stories. T118–T125 are gap-closure tasks: T119 depends on T056/T057, T121 on T012, T122 on T010/T077, T123 on T039/T054, T125 on T091, T127 on T041/T042, T128 on T097/T098, T129 on T054; T130–T133 are Article-conformance tasks (T130 after T062, T131 after T013 and T053, T132 after T034–T040 land, T133 depends on T030).

## Parallel examples

- After T006–T008: T015–T027 are independent files and can run in parallel.
- After T030: T037 (agent writeAtomic), T052 (bootstrap), T062 (host validation), T072 (exit codes) touch different regions; only edits to `rdev.el` need serial merging.
- US9 docs T109–T111 parallel with any implementation.

## Implementation strategy

1. **MVP = M1**: Phases 1–3 plus the M1 critical-fix set above. Stop and verify acceptance M1-1…M1-8 before M2.
2. M2: remaining US2/US3/US5/US4/US8 work, remote search, ownership on failure paths, then baseline benchmarks.
3. M3: Dired, project.el, compile, shell, file watching, SC-010 workflow.
4. M4: Eglot, Magit, completion latency, Consult adapter.
5. M5: Dape, macOS pty verification, measured optimization, docs, release polish.

## Milestone map (matches spec.md Milestones)

| Milestone | Tasks |
|---|---|
| M1 | T001–T032, T034–T040, T045–T046, T049, T052–T053, T059–T060, T062–T064, T067–T068, T072–T073, T078, T124, T126, T130, T131, T133 |
| M2 | T033, T041–T044, T050–T051, T054–T058, T061, T065–T066, T069–T071, T074–T077, T079, T084–T088, T090–T091, T104–T107, T119–T123, T127, T129, T132 |
| M3 | T047–T048, T080, T082–T083, T089, T092–T093, T095, T118 |
| M4 | T094, T096–T100, T125, T128 |
| M5 | T081, T101–T103, T108–T117 |

Every task T001–T133 appears in exactly one row (the M1 range T001–T032 covers Setup, the Foundational harness, US1 and the Phase 3b tasks T009–T013).
