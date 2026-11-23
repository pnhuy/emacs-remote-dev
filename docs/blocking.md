# What blocks Emacs, and for how long

Emacs file APIs (`file-exists-p`, `insert-file-contents`, `write-region`, ...) are
synchronous: the caller waits for the answer. RDEV cannot change that; it can only make the
wait short and keep the rest of Emacs (timers, redisplay, other processes) running.

## Measured (T113, SC-006)

Client: macOS, Emacs 31.1. Host: `devbox` (Linux, Python 3.14) through `bench/delay-proxy.py`
with a 50 ms round trip. A 10 ms timer records the longest gap between ticks.
Run: `RDEV_TEST_SSH_TARGET=host sh test/e2e/run.sh stall` (`RDEV_STALL_RTT`, `RDEV_STALL_MB`).

| Operation (64 MiB where it applies) | Longest timer gap | Limit |
|---|---|---|
| `rdev-search`, 4000 files | 13.9 ms | 200 ms |
| read a 64 MiB file (`insert-file-contents-literally`) | 70.0 ms | 200 ms |
| write a 64 MiB file (`write-region`) | 122.2 ms | 200 ms |
| process flood, 64 MiB of output | 23.4 ms | 200 ms |

Time a synchronous handler keeps its caller waiting (5 calls, cache cleared, RTT 50 ms):

| Call | Median | Max |
|---|---|---|
| `file-exists-p` | 71.5 ms | 84.4 ms |
| `file-attributes` | 74.4 ms | 87.7 ms |
| `directory-files` | 73.8 ms | 79.9 ms |
| `write-region` (small) | 81.6 ms | 93.1 ms |
| `insert-file-contents` (small) | 157.1 ms | 173.5 ms |

Each uncached call costs about one round trip (50 ms) plus agent and ssh overhead; reading is
measured at about two round trips (not broken down further). These are single measurements per run, not a
distribution across hosts.

**Caveat on the timer gap.** The gap measures how long timers are starved. It is not how long
the Lisp caller waits: a 64 MiB read takes 16 s end to end, during which Emacs stays
responsive because the transfer is chunked. A single
synchronous call (for example one `insert-file-contents`) still blocks that caller for the
whole transfer.

## Unavoidable blocking

- The first uncached `file-exists-p`, `file-attributes`, `directory-files`, and similar calls
  wait for one round trip. A cache hit does not (`rdev-cache-ttl`).
- `insert-file-contents` and `write-region` wait for the whole transfer.
- Connecting for the first time waits for ssh, authentication and, once, agent installation.
- `project/files` is cancellable: `$/cancel` kills the running `git`/`rg` listing (or stops the walk) and the request answers `-32800`.
- A dead link makes synchronous calls wait up to `rdev-timeout` before failing.

## Output queue limit

Output from each remote process is queued on the client up to 1 MiB. Beyond that the
transport is paused, which stalls the remote child, instead of growing Emacs memory.

## Durability (FR-013)

A save is atomic with respect to other readers: a temporary file is written and renamed over
the target, so readers see the old or the new content and never a mix. It is not a guarantee
against power loss: durability depends on the remote filesystem and `fsync` behaviour, and a
crash of the host in the middle of a save can lose the new content.

## Parity

Output and exit codes of `process-file`, `shell-command`, `start-file-process`,
`make-process` (with `:file-handler t`), `compile` and an interactive `rdev-shell` match
byte for byte (`test/e2e/parity.el`). Documented differences: a pty (interactive shell) turns
newlines into CRLF and cannot carry NUL or control bytes; a command killed by a signal is
reported by native Emacs with the platform's text (for example "Terminated") and by RDEV as
"Signal N", both meaning exit status 128+N.
