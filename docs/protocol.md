# RDEV protocol notes (1.1)

Normative contract: `specs/001-rdev-modernization/contracts/protocol.md`. This page records
behavior users and client authors need day to day. JSON-RPC 2.0 over `Content-Length` framing.

## Capabilities (hello)
`fs.writeAtomic`, `fs.chunk`, `fs.statMany`, `cancel`, `proc.ownership`, `session.shutdown`, `search.grep`, `watch`,
`project.root`, `fs.readdirZ`.
A client must test `capabilities` before using a method that needs one; an older agent simply
lacks the string.

## Compressed listings (capability `fs.readdirZ`)
`fs/readdir` accepts `compress: true` (boolean; anything else is `-32602`). When the listing
has at least 32 entries the result is `{"z": BASE64}` where BASE64 is zlib-compressed compact
JSON of the usual array; smaller listings come back as the plain array, so a client must accept
both. Attribute listings shrink about tenfold, which matters on slow links (1 Mbit/s,
1000 entries: 3.1 s -> 0.19 s). The client asks only when the capability is advertised and
Emacs has zlib; an older agent never sees the parameter.

## Cancellation (`$/cancel`, capability `cancel`)
`$/cancel {id}` is a notification. The target request answers `-32800` (cancelled).
An unknown, finished or malformed id is ignored.

| Operation | Cancellable? | Effect |
|---|---|---|
| `exec/run` | yes | whole process group receives SIGKILL; response `-32800` |
| queued `exec/run` / `project/files` (waiting for a worker) | yes | never starts; `-32800` |
| `fs/readChunk`, `fs/writeChunk` | not needed | each call is one bounded syscall batch; abort a transfer with `fs/abortWrite` |
| `proc/*` | n/a | not requests that wait; use `proc/signal` |
| `project/files` once running | yes | kills the listing subprocess (or stops the walk); `-32800` |
| single-syscall `fs/*` (`stat`, `rename`, `chmod`, ...) | no | atomic from the agent's view; cancelling would only discard the reply, not the effect |
| `fs/delete` (recursive), `fs/copy` (recursive) | no | not interruptible mid-tree; a cancelled client may still see the tree partially processed |
| `fs/write*` commit (`fs/commitWrite`, `fs/writeAtomic`) | no | must finish so no temp file or half-written target remains |

**Why some operations are not cancellable**: killing them midway would leave the filesystem in a
state that is harder to reason about than letting the call finish (data integrity outranks
responsiveness, Article III). In Emacs, `C-g` during such a call stops *waiting*; the effect on
the remote side may still complete. After an interrupted non-idempotent operation, check the
remote state before retrying; RDEV never replays `exec/run` or `proc/spawn`.

## Resource bounds
- `exec/run`: stdout+stderr above 16 MiB fails with `-32011`; use `proc/spawn` for streams.
- Slow requests (`exec/run`, `project/files`) run on `--workers` threads (default 8).
- `proc/out` is buffered per process (1 MiB). A client that stops reading stalls the child
  (backpressure) instead of growing agent memory.
- `proc/exit` is sent after the output drained; `truncated: true` means the agent gave up
  waiting for a descendant that kept the pipe open or a client that stopped reading.

## Ownership and shutdown
`proc/spawn` takes `owned` (default true) and `grace_ms` (default 2000). Owned process groups
are sent SIGHUP when the session ends or on `session/shutdown`, and SIGKILL after `grace_ms`.
`session/shutdown {grace_ms?}` returns `{terminated: N}` and then ends the session.

## Watching (capability `watch`)

The client registers directories with the agent and receives change notifications
(`fs/changed`); inotify is used on Linux, a kqueue/rescan hybrid (about 1 s) elsewhere.
Watches are non-recursive. After a reconnect the client re-registers its watches; no
synthetic event is emitted for changes made while disconnected.

## Project methods (capability `project.root`)

- `project/root {path, markers?}` -> `{root, marker, vcs}` or `{root: null}`. The nearest
  ancestor holding a marker wins, except that VCS markers (`.git`, `.hg`, `.svn`) beat a
  nearer non-VCS marker. `markers` is at most 64 plain basenames; the default list is
  `.git .hg .svn pyproject.toml package.json Cargo.toml go.mod Makefile CMakeLists.txt
  .project .projectile`.
- `project/files {root, detail?, engine?, max?}` -> a list of relative names, or with
  `detail` `{files, engine[, truncated]}`. `engine` is `git`, `rg` or `walk`; the git listing
  omits files deleted from disk. A missing root returns error -32000. The server caps the
  result at 1,000,000 names. The request is not cancellable once running.

Agents without `project.root` make the client fall back to `vc`-based project detection.

## Orphan guard

If the agent is killed with SIGKILL (or the host kills it), a small watchdog process started by the agent kills the process groups of the children it was running (`proc/spawn`, `exec/run`, searches, listings). The watchdog holds no ssh channel and exits when it has done so.
