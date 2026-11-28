# Developing RDEV

## Layout

| File | Role |
|---|---|
| `rdev.el` | client: file-name handlers, connections, process handlers, jsonrpc.el glue |
| `rdev-docker.el` | Docker container transport: inspect/discovery, `docker exec` process, root policy |
| `rdev-state.el` | connection state machine, reconnect/backoff, redacted per-connection log |
| `rdev-ui.el` | `rdev-list-connections`, mode line, logs, cache inspection |
| `rdev-project.el` | `project.el` backend (`project/root`, `project/files`) |
| `rdev-search.el` | remote grep, Consult integration |
| `rdev-notify.el` | `fs/changed` notifications, opt-in auto-revert |
| `rdev-bench.el` | benchmark driver (RDEV vs TRAMP) |
| `rdev-server.py` | remote agent: JSON-RPC 2.0, Content-Length framing, standard library only |
| `rdev-relay.py` | local relay that gives Emacs a real subprocess (pty, signals) for a remote process |

Dependency direction: `rdev.el` is the base; the other `.el` files `require` it, never the
reverse (checked by `test/rdev-load-order-test.el`).

## Ground rules (from the constitution)

- Keep `/rdev:HOST:/path`, existing commands, variables and RPC methods compatible.
  Intentional changes go in `test/INTENTIONAL-CHANGES.md` with a migration path.
- Data integrity first: no change may weaken atomic save, conflict detection or
  non-replay of `exec/run` / `proc/spawn`.
- The agent refuses to run as root. Do not weaken that. The only exception is the documented
  `:allow-root` opt-in for Docker containers, set per target or globally with
  `rdev-docker-allow-root`: it warns on every connect, is logged, and is covered by positive and
  negative tests. Keep the default refusal and the flag's command-line-only nature intact.
- Python: standard library only, 3.8-compatible syntax (`test_py38_compat.py`).
- Emacs: 30.1 or later, built-in libraries first.
- A bug fix needs a regression test that fails before the fix and passes after.
- Do not claim a test ran if it did not; record unrun items.

## Running tests

```sh
sh test/run-all.sh                 # ERT + Python unit tests, local, no network
sh test/check-quality.sh           # byte-compile, checkdoc, package-lint style gates
sh test/portability-lint.sh        # POSIX-sh / Python 3.8 portability checks
```

Single files:

```sh
emacs -Q --batch -L . -L test -l ert -l test/rdev-save-test.el -f ert-run-tests-batch-and-exit
python3 -W ignore -m unittest discover -s test/py -t test/py -p test_write_atomic.py
```

### End-to-end (real Emacs, real ssh)

```sh
sh test/e2e/run.sh baseline                                  # throwaway local sshd
RDEV_TEST_SSH_TARGET=myhost sh test/e2e/run.sh baseline      # an existing host
```

Docker container targets (real `docker exec`, disposable containers):

```sh
make e2e S=docker                                            # python:3.11-slim by default
RDEV_TEST_DOCKER_IMAGE=python:3.11-slim make e2e S=docker
```

`test/e2e/docker-fixture.sh` starts an unprivileged container and a root-only container, seeds
`/workspace`, and removes both on stop; it also starts the throwaway sshd for the remote-engine
scenario. A missing Docker daemon or image is reported as a skip, never a silent pass.

Scenarios: `baseline conflict flood large-file reconnect dired compile workflow magit
eglot-python eglot-cpp eglot-missing-server eglot-reconnect dape pty save-conflict
save-fault notify ownership edge-cases docker`.
Tests that need a missing optional tool (`debugpy`, `pylsp`, `clangd`, Dape) skip with a
visible reason. `RDEV_TEST_DEBUG=1` turns on extra logging. Fault and conflict trial counts
are `RDEV_FAULT_TRIALS` and `RDEV_CONFLICT_TRIALS` (default 100).
`test/e2e/PLATFORMS.md` records which platform combinations have actually been run.

When using an external host, test code must pass `:file-handler t` to plain `make-process`;
without it Emacs ignores file-name handlers and the test silently runs locally.

### Benchmarks

```sh
RDEV_BENCH_ITER=10 sh bench/run.sh myhost out.csv rtt50 rtt150
python3 bench/compare.py baseline.csv out.csv
```

Latency is injected with `bench/delay-proxy.py` (no privileges) or `bench/netem.sh`
(needs `tc`). See `bench/README.md`.

## Adding a protocol method

1. Document it in `specs/001-rdev-modernization/contracts/protocol.md` and `protocol.md`.
2. Add it to `rdev-server.py` with validation and bounds; advertise a `capabilities` string
   if clients must probe for it.
3. Python test in `test/py/`, including negative cases (bad types, oversize, bad paths).
4. Client side: call it only when the capability is present; keep a fallback for older agents
   (`test/rdev-legacy-compat-test.el`).

## Concurrency notes worth reading before editing `rdev.el`

- `process-send-string` can block and run other process filters (re-entrancy).
  `rdev--relay-send` serializes writes with a queue and pauses the transport while a send is
  in flight so backpressure reaches the remote child; see its comments.
- `(set-process-filter p t)` pauses reading from a process; restoring the filter resumes it.
- Synchronous file handlers use `jsonrpc-request`; they must not be made to depend on timers
  or idle time.

## Release checklist

1. `sh test/run-all.sh` and `sh test/check-quality.sh` and `sh test/portability-lint.sh` are green.
2. Every E2E scenario passes on the throwaway sshd and on one real Linux host
   (`RDEV_TEST_SSH_TARGET=host`); record what ran in `test/e2e/PLATFORMS.md`.
3. `python3 bench/compare.py` against the last release shows no unexplained regression.
4. `test/KNOWN-FAILURES.md` is empty or every row has an owner and a reason.
5. If the protocol changed: bump the version, update `protocol.md` and the contract, and run
   `test/rdev-legacy-compat-test.el` against the previous agent.
6. `test/INTENTIONAL-CHANGES.md` lists every incompatible change with a migration path.
7. Update `docs/` for new options, commands and limits; bump the constitution
   version only through the amendment procedure.
8. State what was *not* run (platforms, tools) in the release notes.

## Style

Docstrings on every public function and option; checkdoc clean; lines at most 80 columns in
docstrings. Comment any concurrency or lifecycle subtlety. Prefer a small test to a long
explanation.
