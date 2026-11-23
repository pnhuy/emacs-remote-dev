# Quickstart: Validating RDEV 2.0

A validation guide: how to run each layer and what a pass looks like. It contains no implementation. Paths refer to the layout in [plan.md](plan.md) §4. Entries marked *(M#)* exist only after that milestone.

## Prerequisites (this machine, surveyed 2026-11-22)

Present: Emacs 30.2, Python 3.14.8, `ssh`/`sshd`, `docker`, `podman`, `tc`, `rg`, `git`, `pylsp`, `clangd`, magit 4.7.2, dape 0.28.0, consult 3.10.
Missing, install into the test fixture only: `debugpy` (venv on the test remote), `pyright` (not needed).
Not available locally: a macOS host (use a real one for R-03 or record "not run").

Port safety: before binding any listener run `ss -ltnp 'sport = :<port>'` and consult `~/AGENTS.md`; the fixtures bind **random free high ports on 127.0.0.1 only** and never 8080/3007/8989/8990.

## 1. Baseline (M1, first thing)

```text
python3 -m unittest discover -s test/py -v
emacs -Q --batch -L . -L test -l ert -l test/rdev-all-tests.el -f ert-run-tests-batch-and-exit
```
Pass: every characterization test green on the **unmodified** tree (commit this state first). Tests for confirmed defects are present and marked `:expected-result :failed`.

## 2. Defect-fix verification (M1)

| Scenario | How | Pass |
|---|---|---|
| D-01 option injection | ERT: `(rdev--ssh-process "-oProxyCommand=id" nil)` with a fake `ssh` earlier in `PATH` that records argv | signals `user-error`; fake ssh never invoked; with a valid host the argv contains `--` before the host |
| D-02 truncated install | harness sends N random-length prefixes of the agent to the bootstrap script | installed file is absent or hash-equal; no `.tmp` left |
| D-03 safe save | unittest: patch `os.replace` to raise / kill process mid-write; E2E: modify the file externally between open and save | original intact; save refused with `rdev-conflict` |
| D-05 framing | feed bad lengths, bad JSON, oversize to `Session.serve` | error response or clean close, no traceback |
| D-06 channel scope | ERT: two fake connections allocating the same id | outputs reach the right buffers |
| D-07 exit codes | `sh -c 'kill -TERM $$'` via `exec/run` and `proc/spawn` | both report 143 |
| Legacy compat | run client suite against `test/fixtures/legacy-server.py` | all frozen-method tests pass in legacy mode |

## 3. Real Emacs over SSH

```text
test/e2e/run.sh            # starts sshd on 127.0.0.1:<random>, runs emacs --batch scenarios, tears down
```
Scenarios: open/edit/save, dired listing, shell with pty (`stty size` after resize), `process-file`, `async-shell-command`, concurrent external edit, kill sshd mid-session (M2: reconnect), interrupted bootstrap, TCP loopback allowed / TCP non-loopback refused without opt-in.
Pass: script exits 0 and prints a per-scenario summary; any skipped scenario prints the reason.

## 4. Tool integration (M2–M5)

| Tool | Run | Pass |
|---|---|---|
| Compile *(M3)* | `M-x compile` `make` in a remote project with a deliberate error | output streams; exit status correct; `next-error` opens `/rdev:` file at the line |
| Magit *(M4)* | status, stage, commit, diff, log, branch create/checkout on a remote repo | all succeed; repo state verified by running `git` on the remote independently |
| project.el *(M3)* | `project-find-file` in a ≥10k-file repo | list appears without transferring file contents (agent counters show only `project/files` + stats) |
| Eglot *(M4)* | `pylsp` on a Python file, `clangd` on a C++ file | diagnostics, completion, definition, references, rename, code action; kill server → restart |
| Search *(M2)* | `search/grep` with and without `rg` on PATH | same matches; `engine` reports which; cancel returns within 2 s |
| Dape *(M5)* | launch `debugpy` remote adapter from venv | breakpoint hit; path mapping resolves remote file locally; terminate kills adapter |

Tests needing a missing tool are tagged and **skipped with a visible reason**, never reported as passing.

## 5. Reliability (M2)

- `kill -9` the ssh process: expect `RECONNECTING` → `CONNECTED`, buffers intact, running processes marked interrupted, no automatic re-execution, first save re-checks version.
- 500 MB file read/write via chunk family: peak RSS delta of the Emacs and agent processes `< 3 ×` chunk size + constant (measured with `/proc/<pid>/status`).
- Process flood: 1 GB through `proc/out` to a stalled consumer: agent RSS stays bounded.

## 6. Performance (M2 baseline, M5 report)

```text
emacs -Q --batch -l rdev-bench.el -f rdev-bench-run     # (M2)
```
Scenarios: connect+bootstrap, stat, open, save, readdir, project enumeration, search, process start, shell echo latency, Eglot startup; each at RTT 0/50/150 ms, 1% loss, 1 Mbit/s; each with TRAMP on the same remote and files. Output CSV in `bench/` with n, median, p95, failures; memory where measurable. Network shaping needs privileges (`unshare -rn` + `tc`); otherwise the delay-proxy fallback is used and the report says so.

## 7. Blocking behaviour check

`rdev-bench` also records "UI blocked time" (time inside `jsonrpc-request`) for stat/open/save/`process-file`. These numbers back the claim in plan.md that synchronous file APIs block for ≥ 1 RTT; they are reported, not hidden.

## 8. Completion checklist for the planning phase

- [x] Source files inspected in full; defect probes run
- [x] Inventory, compatibility matrix, prioritized defects (plan §1–3)
- [x] Architecture, protocol evolution, testing strategy, milestones (plan §4–7)
- [x] `/speckit-tasks`, `/speckit-analyze` — done; no implementation has started
