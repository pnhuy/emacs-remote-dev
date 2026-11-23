# Implementation Plan: RDEV 2.0 — Incremental Modernization

**Branch**: `001-rdev-modernization` | **Date**: 2026-11-22 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-rdev-modernization/spec.md`

## Summary

Harden and extend the existing `rdev` package (`rdev.el` 1031 lines, `rdev-server.py` 547, `rdev-relay.py` 94) without replacing any of its three components. Order of work is fixed by the user's constraints: **file safety and protocol correctness first, features second**. Milestone 1 builds a regression-test baseline that pins current behaviour, then fixes the P0/P1 defects found in the audit below. Everything else (reconnect, UI, search, project.el, notify, Eglot/Magit/Dape validation, benchmarks) layers on afterwards via additive, capability-negotiated RPCs.

Method for this plan: all three files were read in full, and the defect candidates were exercised with throwaway scripts (results in [research.md](research.md) §R0). Findings are labelled **CONFIRMED** (reproduced or unambiguous in code), **NOT REPRODUCED** (suspected, tried, did not occur — kept as a risk), or **UNVERIFIED** (needs a real runtime test, scheduled in the milestone that fixes it).

## Technical Context

**Language/Version**: Emacs Lisp (Emacs ≥ 30.1; dev box 30.2); Python ≥ 3.8 for the remote agent and relay (dev box 3.14.8). Agent stays Python-stdlib-only.

**Primary Dependencies**: Emacs built-ins only (`jsonrpc`, `eglot`, `project`, `filenotify`, `tabulated-list`). Optional, never required: `ripgrep` on remote, `consult`, `magit`, `dape` (all present locally for validation: magit 4.7.2, dape 0.28.0, consult 3.10).

**Storage**: remote `~/.cache/rdev/` (agent files, `*.tmp` upload staging, write-transfer staging); no local database.

**Testing**: ERT (`test/rdev-*-test.el`), Python `unittest` (`test/py/`), real Emacs-over-SSH integration against a disposable unprivileged `sshd` (available: `/usr/sbin/sshd`, `ssh`, `docker`, `podman`, `tc`, `rg`, `pylsp`, `clangd`; **absent**: `debugpy`, `pyright` — Dape needs a pip-installed adapter in the test venv, not the system).

**Target Platform**: Emacs client on Linux/macOS; remote host Linux or macOS (clarified: both fully supported from M1).

**Project Type**: Emacs package + remote agent (existing three-file layout, extended in place).

**Performance Goals**: set by measurement, not assumption (FR-037). M1 only records baselines. Targets are chosen in M2 once numbers exist; success is "no regression vs baseline, and compared to TRAMP report median/p95".

**Constraints**: preserve `/rdev:HOST:/path`; keep persistent JSON-RPC over SSH stdio; keep local relay; no mandatory Python deps; Emacs 30.1+; no behaviour break for existing RPC names; existing public functions/defcustoms keep working.

**Scale/Scope**: single user, a handful of concurrent connections, projects up to ~10^5 files, files up to hundreds of MB (chunked path).

### Unavoidable blocking (stated up front, per instruction)

Emacs calls file-name handlers and `process-file` **synchronously** and expects a return value, so each such call blocks the command loop for at least one RPC round trip (`accept-process-output` inside `jsonrpc-request`). This cannot be removed — only bounded and reduced:

| Operation | Blocks Emacs? | Mitigation (does not make it async) |
|---|---|---|
| `file-exists-p`, `file-attributes`, `file-directory-p`, … | Yes, 1 RTT on cache miss | TTL cache, batched `fs/stat` with dir listing attrs, parent-dir prefetch; every call has a timeout and is interruptible with `C-g` |
| `insert-file-contents`, `write-region` | Yes, whole transfer | Chunked transfer keeps memory bounded and lets `C-g`/timeouts act per chunk; it does not unblock the UI |
| `directory-files`, completion | Yes | `attrs=true` single call; completion cache |
| `process-file` (e.g. Magit's `git`) | Yes, until the command exits | Server-side timeout; large output streamed in chunks |
| `make-process`, `start-file-process`, compile, shell, Eglot server | **No** — fully async via relay | n/a |
| `search/grep`, project enumeration (new APIs) | **No** when called from our own commands | incremental `search/result` notifications; cancellable |
| Reconnect, bootstrap | No for background reconnect; **Yes** for the first interactive connect (existing `rdev--wait-for`) | Spinner/message; `C-g` aborts |

Consequence for acceptance tests: latency SCs must be stated as "blocked time per call" and measured, not "UI never blocks".

## Constitution Check

Gated against `.specify/memory/constitution.md` v1.0.0 (Articles I–XII). Baseline non-conformances are existing defects that this plan schedules for repair; they are recorded here, not hidden.

| Article | Pre-research | Post-design | Notes |
|---|---|---|---|
| I Architecture preservation | PASS | PASS | `/rdev:HOST:/path`, SSH JSON-RPC, relay preserved; new code goes in new files/functions; breaking changes are logged in `test/INTENTIONAL-CHANGES.md` with justification, migration path and test id (T030) |
| II Native Emacs | PASS | PASS | File-name handlers only; Eglot/Magit/Dape/Dired/project/compile validated by real execution in M3–M5; T095 checks major-mode and hook behavior |
| III Data integrity | PASS | PASS | Atomic `fs/writeAtomic`, conflict detection, no replay of non-idempotent ops (M1). Baseline non-conformance: non-atomic saves (D-10), scheduled M1 |
| IV Security | PASS | PASS | No root (unconditional, FR-035/T120), argv-only (FR-033/T130), token and env redaction (FR-034/T058/T060), TCP gate in M1. Baseline non-conformances: D-12 and D-13, scheduled M1 |
| V Performance | PASS | PASS | Bounded chunking and concurrency (M2); baseline benchmarks incl. TRAMP comparison at realistic latency (US9) |
| VI Dependencies | PASS | PASS | Stdlib-only agent, `inotify` via `ctypes`/polling, grep `rg`→stdlib; Emacs 30.1+; Python 3.8 minimum tested (T126); WatchBackend isolates platform code |
| VII Testing | PASS | PASS | Baseline-first (T030), ERT + pytest, regression tests that fail before the fix, known failures documented in `test/BASELINE.md` |
| VIII Protocol | PASS | PASS | JSON-RPC 2.0 and Content-Length framing unchanged; additive, capability-negotiated RPCs; effect on deployed agents assessed in contracts/protocol.md |
| IX Maintainability | PASS | PASS | Incremental refactoring; T132 enforces docstrings, checkdoc and byte-compile cleanliness |
| X User experience | PASS | PASS | Visible state, per-connection log, distinct error classes (FR-040/T013/T131) |
| XI Workflow | PASS | PASS | Existing code inventoried (§1); confirmed vs suspected defects separated; baseline-first |
| XII Definition of done | PASS | PASS | T133 milestone-close gate and report; 'not run' environments reported explicitly (FR-004a) |

No exceptions to mandatory principles are requested, so Complexity Tracking is empty.

## 1. Inventory of existing behaviour

### 1.1 Emacs client — `rdev.el`

**Public API / customization (must keep)**: `rdev-hosts`, `rdev-ssh-args`, `rdev-python`, `rdev-cache-ttl`, `rdev-timeout`, `rdev-env-exclude`; commands `rdev-find-file`, `rdev-shell`, `rdev-disconnect`, `rdev-clear-cache`, `rdev-status`; struct `rdev-conn` (host rpc home path cache); `rdev-file-name-handler`, `rdev-defop`.

**Connection**: `rdev--parse`/`rdev--host`/`rdev--prefix`, `rdev--ssh-process` (bootstrap), `rdev--tcp-process`, `rdev--connect`, `rdev--on-shutdown`, `rdev--conn`, `rdev--req`, `rdev--notify`, `rdev--signal-error` (errno → Emacs file-error symbols), global tables `rdev--conns` (host→conn), `rdev--chans` (chan-id→chan, **global**).

**Cache**: `rdev--stat`, `rdev--invalidate`, `rdev--cache-put`, `rdev--attributes`.

**File-name handler ops (`rdev-defop`)** — 53 operations:

| Group | Ops |
|---|---|
| Name/identity | `expand-file-name`, `file-remote-p`, `file-truename`, `file-name-case-insensitive-p`, `unhandled-file-name-directory`, `temporary-file-directory`, `exec-path` |
| Predicates / attrs | `file-attributes`, `file-exists-p`, `file-directory-p`, `file-regular-p`, `file-symlink-p`, `file-readable-p`, `file-executable-p`, `file-writable-p`, `file-accessible-directory-p`, `access-file`, `file-modes`, `file-newer-than-file-p`, `file-system-info`, `file-ownership-preserved-p` |
| Read/write | `insert-file-contents`, `file-local-copy`, `write-region`, `verify-visited-file-modtime`, `set-visited-file-modtime` |
| Directories | `directory-files`, `directory-files-and-attributes`, `file-name-all-completions`, `file-name-completion`, `make-directory`, `make-directory-internal`, `delete-directory`, `insert-directory` |
| Mutation | `delete-file`, `copy-file`, `rename-file`, `set-file-modes`, `set-file-times`, `make-symbolic-link`, `add-name-to-file` |
| Stubs (no-op) | `file-acl`, `file-selinux-context`, `set-file-acl`, `set-file-selinux-context`, `lock-file`, `unlock-file`, `file-locked-p` |
| Not supported (signals) | `file-notify-add-watch` |
| Process | `process-file`, `make-process`, `start-file-process`, `shell-command` (via `cl-letf` shim) |

Any op not in the table falls through `rdev--real` to the real implementation with the handler inhibited (so e.g. `file-name-directory` works).

**Process integration**: relay server (`rdev--ensure-relay-server`, `rdev--relay-socket`, `rdev--relay-filter`, `rdev--relay-frame`, `rdev--relay-sentinel`, `rdev--relay-send`), `rdev--spawn` (sends `proc/spawn`), `rdev--dispatch` (routes `proc/out`, `proc/exit` notifications), `rdev--chan-exit`, `rdev--env`, `rdev--program`, `rdev--decode`; connection-local profile `rdev-shell-profile`; registration in `rdev--register` (`file-name-handler-alist`, `tramp-ignored-file-name-regexp`).

### 1.2 Agent — `rdev-server.py`

Framing: LSP-style `Content-Length`. Dispatch: `m_<ns>_<name>` via `getattr`. Threaded dispatch for `exec/run`, `project/files`, `search/grep`.

| Namespace | Methods (existing, all preserved) |
|---|---|
| session | `auth` (TCP token), `hello` |
| fs | `stat`, `readdir`, `read`, `write`, `mkdir`, `delete`, `rename`, `copy`, `chmod`, `utime`, `symlink`, `link`, `realpath`, `statvfs` |
| exec | `run` |
| proc | `spawn`, `write`, `eof`, `signal`, `resize`; notifications `proc/out`, `proc/exit` |
| project | `files` |
| search | `grep` — **dispatched but not implemented** |

Transports: `--stdio`, `--listen HOST:PORT --token/--token-file`.

### 1.3 Relay — `rdev-relay.py`

Unix-socket client of Emacs; frames `TYPE(1) LEN(4 BE) PAYLOAD`; relay→emacs `H I C S W`, emacs→relay `O E X`; raw tty mode when stdin is a tty; forwards SIGINT/TERM/HUP/QUIT/TSTP/CONT/USR1/USR2 and SIGWINCH; `os._exit` on `X` or socket EOF.

## 2. Compatibility matrix

Legend: **P** preserved unchanged · **M** modified (same contract, fixed behaviour) · **E** extended (additive) · **N** new.

| Item | Status | Detail |
|---|---|---|
| `/rdev:HOST:/path` syntax, `rdev--regexp` | P | Host charset validation added at connect time only (D-01) |
| `rdev-conn` struct | E | New slots appended (`state`, `gen`, `proto`, `caps`, `limits`, `transport`, `log`, `stats`, `procs`, `policy`; `policy` reserved, only `terminate` implemented); existing slots/accessors unchanged |
| `rdev--conns` | P | |
| `rdev--chans` | M | Key becomes `(host . id)` internally; `rdev-chan` gains `host`; ids stay ints on the wire (D-06) |
| `rdev--ssh-process` | M | Same function, same ssh invocation shape; adds `--`, framed bootstrap markers, size/hash-verified install (D-02/D-03) |
| `rdev--tcp-process` | M | Adds opt-in gate + warning for non-loopback; token via `m_auth` unchanged |
| `rdev--connect/--on-shutdown/--conn` | M→E | Wrapped by state machine; same signatures |
| `rdev--req`, `rdev--notify` | P (+E) | Optional `:timeout`/cancel keyword added at end |
| `rdev--signal-error` | M | Add dedicated `rdev-conflict` error (child of `file-error`) |
| Cache fns | M | Per-conn (already), plus size bound, parent invalidation on all mutators, stats |
| 49 handler ops (non-process) | P / M | Behaviour pinned by M1 baseline tests first; changed only where listed in §3 |
| `write-region` | M | Atomic + version-checked via new RPC when `fs/writeAtomic` capability present; old `fs/write` used when absent |
| `insert-file-contents` | M | Records version; chunked when large and capable |
| `file-notify-add-watch` | E | Stub → real (M3) |
| `process-file`, `make-process`, `start-file-process`, `shell-command` | P/M | Contract preserved; fixes: exit-code mapping, chan scoping, cancellation |
| Relay frame types `H I C S W O E X` | P | Byte format unchanged and no new frame types; M1 adds validation only |
| `rdev-find-file/-shell/-disconnect/-clear-cache/-status` | P | `rdev-status` output kept; list UI is additive |
| New commands | N | `rdev-connect`, `rdev-list-connections`, `rdev-reconnect`, `rdev-restart-server`, `rdev-show-logs` |
| `fs/*`, `exec/run`, `proc/*`, `project/files`, `hello`, `auth` | P | Parameters/results unchanged; new *optional* params and result keys only |
| New RPCs | N | `fs/writeAtomic`, chunk family, `fs/statMany`, `search/grep`, `$/cancel`, `watch/*`, `session/shutdown` — see [contracts/protocol.md](contracts/protocol.md) |
| Python ≥ 3.8 | M | Add version check in `hello`; avoid 3.9+ syntax/APIs |

## 3. Prioritized defect list

P0 = data loss / arbitrary-execution / crash of the core path. P1 = incorrect results or protocol breakage under realistic use. P2 = robustness/security hardening. P3 = polish.

### 3.1 Confirmed code defects

| ID | Pri | Defect | Evidence | Fix milestone |
|---|---|---|---|---|
| D-01 | **P0** | **ssh argument injection**: host from `/rdev:HOST:` goes straight into `ssh` argv with no `--`; `rdev--parse "/rdev:-oProxyCommand=id:/p"` → host `-oProxyCommand=id`, and `ssh -G` accepts it as `proxycommand`. A crafted path/link executes a local command. | Run in this session (research.md R0-8) | M1 |
| D-02 | **P0** | **Truncated agent installed as final file**: bootstrap `head -c N > F.tmp && mv F.tmp F` — if the stream ends early, `head` still exits 0 and `mv` installs a short script; later connects see `-f F` and run the truncated agent. | Exact command shape reproduced: 40 of 100 bytes installed (R0-6) | M1 |
| D-03 | **P0** | **`fs/write` truncates in place** (`O_TRUNC`, no temp file, no version check): failure mid-write or a concurrent external edit loses data. `write-region` has no conflict detection. | Code (`m_fs_write`) | M1 |
| D-04 | **P1** | `search/grep` listed in the threaded set but no `m_search_grep` → `-32601` for any caller. | Reproduced (R0-1) | M2 (implement), M1 (remove from set or stub with clean error + test) |
| D-05 | **P1** | Frame parser kills the session on bad input: non-numeric `Content-Length` → `ValueError`; invalid JSON body → `JSONDecodeError`; both propagate out of `serve()`. No header/body size limits. | Reproduced (R0-2) | M1 |
| D-06 | **P1** | `rdev--chans` is global: channel ids from two connections can collide (`s1` on host A vs B / `rdev--next-chan`), misrouting output/exit. | Code | M1 |
| D-07 | **P1** | Exit-code mismatch: `exec/run` returns `128 - code` for signalled children; `Proc._reap` uses `128 + sig`. Same signal ⇒ two different codes. | Code | M1 |
| D-08 | **P1** | Bootstrap marker detection runs in a process filter on accumulated text with `^RDEV-OK$`; bytes after the marker that arrive in the same chunk are consumed by the filter instead of `jsonrpc`; marker split across chunks is handled only by re-scanning the full log. | Code | M1 |
| D-09 | **P1** | Relay frames are not validated in the Emacs filter (`rdev--relay-filter`) or the relay: unbounded `LEN` is buffered, unknown types ignored silently, `int(payload)` on `X` can raise. | Code | M1 |
| D-10 | **P2** | Relay Unix socket created without explicit 0600 perms / private dir; no peer credential check. | Code | M2 |
| D-11 | **P2** | TCP: token sent in plaintext on non-loopback with no opt-in; `--token` visible in `ps`; no auth-failure handling/backoff (token compare already uses `hmac.compare_digest`). | Code | M1 (opt-in gate, `--token-file` default, auth-failure limit) |
| D-12 | **P2** | Unbounded thread creation for each `exec/run`/`project/files`; unbounded stdout buffering in `exec/run`. | Code | M2 |
| D-13 | **P2** | No backpressure: `Proc` pump threads write to the session socket without bound; slow Emacs ⇒ blocked pumps (fine) but no cap on queued notifications, and no cancellation. | Code + R0-4 (no loss observed) | M2 |
| D-14 | **P2** | Interrupted installs leave `$F.tmp` forever; no Python version check; `mkdir -p` perms follow umask. | Code | M1 |
| D-15 | **P2** | Cache has no size cap; `file-notify-add-watch` signals an error (documented gap, not a defect per se). | Code | M2 / M3 |
| D-16 | **P3** | `shell-command` support relies on `cl-letf` shim over `process-file`/`make-process`. | Code | M3 (verify) |

### 3.2 Risks requiring runtime verification (not confirmed)

| ID | Pri | Risk | What was tried / what verifies it |
|---|---|---|---|
| R-01 | P1 | `proc/exit` emitted before the last `proc/out`, losing output (2 s join timeout). | **NOT REPRODUCED**: 3 MB through a deliberately slow writer arrived entirely *before* `proc/exit` (R0-4). Keep as risk for >2 s drain; add stress test in M1 baseline. |
| R-02 | P1 | Race in `m_proc_spawn`: `Proc` threads start before `self.procs[id]` is set; instant-exit child could leak/`pop` first. | **NOT REPRODUCED**: 200 instant-exit spawns left 0 stale entries (R0-3). Still fix by registering before start (cheap, M1). |
| R-03 | P1 | pty semantics on macOS (`tcgetpgrp(master)`, `preexec_fn` with threads). | Needs real macOS run; first run in M1 via T124 when a macOS host exists (else recorded 'not run'), re-run at each milestone close, fixes in M5 (T081). |
| R-04 | P1 | `file-modes`, `file-newer-than-file-p`, `insert-file-contents` `beg/end/replace`, `copy-file`/`rename-file` across hosts match native contract. | Baseline contract tests comparing against a local twin directory (M1). |
| R-05 | P2 | Relay `sendall` from signal handlers interleaving with main-loop `sendall`. | Stress test: signal storm while streaming stdin (M2). |
| R-06 | P2 | `fs/stat` on unsearchable dir raises `EACCES` rather than "not found"; client must map to `nil` for `file-exists-p`. | Server error shape confirmed (R0-7); client mapping verified by baseline test (M1). |
| R-07 | P2 | `fs/read` mtime/size obtained separately from content (not atomic with it). | Not confirmed either way; M1 will switch to `fstat` on the open fd for the version. |
| R-08 | P1 | Eglot/Magit/Dape work end-to-end. | Real-execution tests (M4 Eglot/Magit, M5 Dape). |
| R-09 | P2 | TRAMP interplay (`tramp-ignored-file-name-regexp` registration order). | ERT test with TRAMP loaded (M1). |

## 4. Architecture (minimal-refactor)

Principle: **new behaviour goes in new functions/files; existing functions change only where a defect in §3 names them.**

```text

├── rdev.el                # existing — stays the entry point and handler; edits are surgical
├── rdev-server.py         # existing — adds methods; Session gets a lock + worker pool
├── rdev-relay.py          # existing — frame validation only in M1
├── rdev-state.el          # NEW (M2): connection state machine + reconnect  (required by rdev.el)
├── rdev-ui.el             # NEW (M2): tabulated-list UI, logs, restart       (autoload)
├── rdev-project.el        # NEW (M3): project.el backend                     (autoload)
├── rdev-search.el         # NEW (M2): search/grep client; consult adapter M4 (autoload)
├── rdev-notify.el         # NEW (M3): file-notify bridge                     (autoload)
└── rdev-bench.el          # NEW (M2): benchmark driver (not loaded by default)
test/
├── rdev-test-helpers.el   # local twin-dir fixtures, fake server, SSH fixture launcher
├── rdev-*-test.el         # ERT
├── py/test_*.py           # unittest (imports rdev-server.py via importlib; no install)
└── e2e/                   # sshd harness + tc netem scripts + Eglot/Magit/Dape scenarios
bench/                     # raw results (CSV) + report
```

Key decisions (details and rejected alternatives in [research.md](research.md)):

1. **Server stays one stdlib file.** Add a `threading.Lock` around `procs`/`next_id`/write-side; a fixed-size `ThreadPoolExecutor` (default 8) replaces ad-hoc threads. No asyncio rewrite.
2. **State machine lives beside, not inside, `rdev--connect`.** `rdev--conn` keeps its signature and returns a `CONNECTED` conn or signals; state transitions are recorded on `rdev-conn-state`. Reconnect is a timer that calls the same `rdev--connect`.
3. **Safe writes are a new RPC** (`fs/writeAtomic`) so the old `fs/write` keeps its exact semantics for older agents and for append. The client picks by negotiated capability.
4. **Version token** = `{mtime_ns, size, ino, dev}` always, optional `sha256` for chunked/commit verification. Server verifies under `flock`-free "stat-then-replace" as the best available semantics; documented as detect-and-refuse, not a lock (see research R3).
5. **Bootstrap becomes two-phase**: (a) a tiny fixed shell probe prints framed `RDEV-BOOT <json>\n` lines and the install uses `--` + size/sha256 check + `mv` only on match; (b) after `RDEV-READY`, the same ssh pipe switches to JSON-RPC. The filter hands over residual bytes (D-08).
6. **Capabilities, not versions, gate features.** `hello` gains `protocol` and `capabilities[]`; the client treats absence as legacy v1 (current agents keep working — compat test with the *current* server file).

## 5. Protocol evolution (summary)

Full wire contract: [contracts/protocol.md](contracts/protocol.md). Rules:

- Existing method names, params, results: **frozen**. Additions are optional params/keys.
- `hello` (no args) keeps working. New optional param `{client:{protocol:[1,2],caps:[…]}}`; result adds `protocol`, `capabilities`, `limits` (`max_message`, `max_chunk`, `max_transfer`), `python`.
- Absent `protocol` in the result ⇒ legacy (v1.0). Client then uses only legacy methods and warns once.
- Agent hash is still the deployment key; `protocol` is the compatibility key. Bumping the agent hash never requires a protocol bump.
- Minor additions (new methods) ⇒ capability string; breaking changes ⇒ major bump and client refuses with an actionable message (FR-011, FR-029).

## 6. Testing strategy

Full detail in [quickstart.md](quickstart.md). Three layers, each with a defined entry point:

| Layer | Tool | What it proves | Runs |
|---|---|---|---|
| Unit — agent | `python3 -m unittest discover test/py` | framing validation, methods against a temp dir, atomic write failure injection (kill mid-write), chunk lifecycle, thread-safety stress | every change, no network |
| Unit — client | `emacs -Q --batch -l ert` with an **in-process fake server** over a pipe | path parsing, handler contracts vs. a local twin directory, cache invalidation, error mapping, relay framing, state machine | every change, no network |
| Integration | disposable `sshd` on 127.0.0.1:random as the current user, real `emacs --batch` | bootstrap (incl. interrupted/corrupt install), real saves with concurrent external edit, process relay with real pty, reconnect via killing sshd, TCP opt-in gate | M1 acceptance, nightly |
| Tool integration | same harness + real tools | Eglot↔`pylsp`/`clangd`, Magit status/diff/commit on a remote repo, compile with error navigation, Dape with `debugpy` in a venv | M3–M5 acceptance |
| Perf | `rdev-bench.el` + `tc netem` (needs root/`unshare -n`; falls back to ssh `ProxyCommand` delay shim if unavailable) vs TRAMP | median/p95, memory, failure rate | M2 baseline, M5 report |

Baseline-first rule: M1 task 1 is writing characterization tests that **pass against the unmodified code**, committed before any fix; each fix then flips exactly one pre-written failing test (marked `:expected-result :failed` until fixed) from fail to pass. Phase 2 of tasks.md is harness only; behavior-changing foundation work (framing, `hello`, negotiation) lands in Phase 3b, after the baseline commit. This is how "without breaking existing functionality" is enforced.

## 7. Milestones, dependencies, acceptance tests

Dependency graph:

```text
M1 baseline+critical ──► M2 robust core ──► M3 Emacs integration ──► M4 IDE capabilities ──► M5 advanced
       (tests ► fixes)      │                    │                      │
                            └─ state, search ──► Dired/project/compile/watch ─► Eglot, Magit ─► Dape, perf, release
```

### M1 — Regression baseline and critical correctness (no new features)
Depends on: nothing.
Scope: build the test harness (fake server, twin-dir, sshd fixture); characterization tests for all 53 ops + relay + agent methods; then fix D-01, D-02, D-03 (new `fs/writeAtomic` + client use + `rdev-conflict`), D-04 (clean error), D-05, D-06, D-07, D-08, D-09, D-11, D-14, R-02; add `hello` protocol/capabilities (additive).
Acceptance:
1. Characterization suite passes on the pre-change commit and on the post-change commit except for tests explicitly tagged as intentional behaviour changes (each listed in the PR).
2. `/rdev:-oProxyCommand=id:/p` signals a user-error without spawning ssh (ERT + process-table check).
3. Kill the upload at a random byte (100 trials): the installed agent is either absent or hash-verified, never truncated.
4. Save with a concurrent external change is refused with `rdev-conflict`; kill agent mid-write leaves original intact (E2E + unittest).
5. Malformed framing (bad length, bad JSON, oversize) yields a JSON-RPC error or closes only that session cleanly, never an unhandled exception.
6. Two hosts with the same channel counter do not cross output (ERT).
7. Existing agent (pre-change file) still works with the new client (legacy-capability test); new agent works with old client logic path (hello w/o params).
8. Works against a Linux remote and, if available, a macOS remote (R-03 recorded as pass/fail/not-run).
9. Non-loopback TCP is refused without the explicit opt-in and warns on every connect when opted in; 5 failed auths close the session (D-11).
10. The agent and relay parse under Python 3.8 and pass the unit suite there when a 3.8 interpreter exists (FR-004b).

### M2 — Robust core
Depends on: M1 (tests, hello caps).
Scope: state machine, reconnect/backoff, pending-request failure policy, process ownership/termination policy (default terminate), `rdev-list-connections`/`reconnect`/`restart-server`/`show-logs`, bounded worker pool, backpressure + `$/cancel`, chunked transfer, cache bound/stats/parent invalidation, relay socket 0600 private dir (D-10, D-12, D-13, D-15), remote `search/grep` (rg → stdlib fallback, streaming, cancel), process-ownership on relay crash, benchmark baseline.
Acceptance: kill sshd mid-session → buffers intact, state goes CONNECTED→RECONNECTING→CONNECTED within configured backoff, unknown-status processes marked interrupted and *not* replayed, first save after reconnect re-checks version; 500 MB file round-trips with RSS growth < 3× chunk size; cancelled `exec/run` frees thread and process within 2 s; baseline CSVs committed.

### M3 — Emacs integration
Depends on: M2 (state, ownership, search).
Scope: Dired verification, project.el backend, remote `compile`/`recompile`, shell/comint polish, `shell-command`/`async-shell-command` validation (D-16), file watching (`inotify` via `ctypes`, kqueue, poll; capability-gated) with cache invalidation, TRAMP coexistence (R-09).
Acceptance: Dired open/mark/copy/rename/delete on a remote dir; `project-find-file` on a 10^4-file remote repo without downloading the tree; `M-x compile` streams output, exit status correct (incl. signalled → D-07), `next-error` opens `/rdev:` file; `auto-revert-mode` sees an external change within 2 s with the native backend and watchers are released on disconnect; the SC-010 end-to-end workflow passes.

### M4 — IDE capabilities
Depends on: M3.
Scope: Eglot (URI mapping, restart), Git/Magit through real runs, navigation and completion latency (single-RPC completion), optional Consult adapter.
Acceptance: Eglot with `pylsp` and `clangd`: diagnostics, completion, definition, references, rename, code action on a remote file; server killed → Eglot restarts; real Magit status/diff/stage/commit/log/branch on a remote repo, verified with independent remote `git`.

### M5 — Advanced
Depends on: M2–M4.
Scope: Dape/`debugpy` remote debugging (partial where adapters make full support infeasible), advanced terminal compatibility (macOS pty verification), performance optimization driven by baselines, TRAMP comparison report, broader platforms (best-effort), documentation and release preparation.
Acceptance: Dape launches `debugpy` remotely, breakpoint hit, path mapping correct, termination kills adapter; benchmark report with median/p95 at 0/50/150 ms RTT, loss, throttled bandwidth, each optimization with before/after CSV; docs walk-throughs pass (SC-014).

## Project Structure

### Documentation (this feature)

```text
specs/001-rdev-modernization/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── protocol.md        # JSON-RPC contract incl. versioning
│   ├── relay-frames.md    # relay ↔ Emacs socket frames
│   └── emacs-api.md       # public commands, defcustoms, errors, handler guarantees
├── tasks.md               # generated by /speckit-tasks, checked by /speckit-analyze
└── (repo) docs/      # user + developer docs: audit (T014), connections (T056), security (T066), dape (T103), README/DEVELOPING/protocol/blocking (T109–T111)
```

### Source Code

See §4 tree. Structure decision: keep the existing flat `` directory; add files only where a new feature is separable and lazily loadable; add top-level `test/` and `bench/`.

## Complexity Tracking

| Addition | Why needed | Simpler alternative rejected because |
|---|---|---|
| Separate `fs/writeAtomic` instead of changing `fs/write` | Old agents/clients and append must keep exact semantics | Changing `fs/write` silently alters append/excl/mode behaviour for existing callers |
| Fixed worker pool in agent | Unbounded threads (D-12) | asyncio rewrite would violate "no redesign" |
| New Elisp files | Lazy loading, reviewable diffs | Growing `rdev.el` past ~1.5k lines hurts review; not a redesign |
