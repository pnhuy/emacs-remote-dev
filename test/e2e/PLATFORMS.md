# E2E platforms actually run (T031)

`test/e2e/run.sh baseline` — 8 scenarios, real `ssh` → bootstrap → agent → JSON-RPC.

| Date | Client | Remote | Remote Python | Transport | Result |
|---|---|---|---|---|---|
| 2026-11-22 | macOS, Emacs 31.1 | devbox (Linux 7.2, Fedora 44, uid 1000) | 3.14.8 | real ssh (`RDEV_TEST_SSH_TARGET=devbox`) | 8/8 pass |
| 2026-11-22 | macOS, Emacs 31.1 | local throwaway sshd (macOS) | 3.9.6 | real sshd on a random port | 8/8 pass |

Limits: on devbox the current agent was already cached in `~/.cache/rdev`, so the first-time
deploy path (`RDEV-NEED` + stream) was not exercised there; the local fixture uses a fresh
HOME-independent cache only if its home lacks the file (not verified). No Emacs 30.x client,
no Windows, no latency injection, no TRAMP-side-by-side run.

## M1 re-verification (2026-11-22, after hardening, writeAtomic, versioned save, relay, tokens)
| Client | Remote | Python | Scenario | Result |
|---|---|---|---|---|
| macOS, Emacs 31.1 | devbox (Linux, Fedora) | 3.14.8 | baseline (first-time deploy of new agent hash) | 8/8 pass |
| macOS, Emacs 31.1 | devbox | 3.14.8 | conflict + atomic-save-preserves-mode (+ baseline) | 10/10 pass |
| macOS, Emacs 31.1 | devbox | 3.14.8 | `e2e/bootstrap.sh 10` (cache wiped each trial) | 10/10 first connections, 1-2 s each |
| macOS, Emacs 31.1 | local throwaway sshd (macOS) | 3.9.6 | baseline (via milestone gate) | 8/8 pass |

Python agent unit suite (83 tests): 3.8.18 and 3.9.6 (macOS), 3.8.20, 3.10.18, 3.12.11, 3.14.8 (devbox), 3.12.12 and 3.13.1 (macOS) all OK.
ERT (113 tests): Emacs 31.1 (macOS) and 30.2 (devbox), 0 unexpected.

Not run: Emacs 30.1 and snapshot, Windows, ssh latency injection, TRAMP side-by-side, a macOS *remote* host over real ssh. Python 3.5 on devbox was probed: the agent
exits with `RDEV-ERR python>=3.8 required` as designed.


## M2 large-file (T127)
| Date | Client | Remote | Result |
|------|--------|--------|--------|
| 2026-11-22 | macOS, Emacs 31.1 | devbox, real ssh, 500 MiB, 1 MiB chunks | sha256 identical both directions; 1002 requests; peak RSS growth 1040 KiB (< 3 MiB plan limit); interrupted upload leaves no remote files; 414 s |
| 2026-11-22 | macOS, Emacs 31.1 | local sshd fixture, 64 MiB | passes at factor 5 only: growth 3.4–3.9 MiB (> 3x) — short runs include warm-up allocation; not repeated at 500 MiB locally |

## pty behaviour (T081, R-03)

`test/e2e/pty.el`, 15 tests (resize, SIGINT, EOF, process-group kill, ...), run 2026-11-22:

| Client | Remote | Result |
|---|---|---|
| macOS, Emacs 31.1 | devbox (Linux, Fedora), real ssh | 15/15 pass |
| macOS, Emacs 31.1 | local throwaway sshd (macOS pty) | pass |

The macOS *agent-side* pty path was therefore exercised through the local sshd fixture.  Still
**not run**: a macOS remote host over real ssh from another machine.  An earlier pty run was
invalid (processes ran locally, no `:file-handler t`); the results above are after that fix.


## Docker container targets (2026-11-28)

`make e2e S=docker` — 14 scenarios over real `docker exec` (local engine) plus the
remote-engine scenario through the disposable sshd.

| Date | Client | Engine / image | Scenarios | Result |
|---|---|---|---|---|
| 2026-11-28 | Linux 7.3.6 x86_64, Emacs 31.1 | Docker 29.10.1, `python:3.11-slim` | edit/save, conflict, interrupted save, shell/compile/interrupt/resize, discovery/status, stop/restart/recreate, root policy (per-target and global), disconnect, remote engine, open-by-address without config, Eglot | 13 pass, 1 skip (Eglot: no server in the image) |

The remote-engine scenario uses the throwaway sshd on the same machine as the engine, so a real
second host was **not** exercised. Docker Desktop, rootless Docker, a macOS client and Emacs 30.1
were **not** exercised. The fixture's unprivileged container runs as uid 1000 with
`HOME=/home/dev`; the root-only container has no unprivileged account.
