# Research: RDEV 2.0

Phase 0 output. No `NEEDS CLARIFICATION` remain; each decision records what was chosen, why, and what was rejected.

## R0. Defect probes run during planning

Throwaway scripts (kept out of the repo) imported `rdev-server.py` via `importlib` with in-memory streams, and ran Emacs in batch mode. Results:

| # | Probe | Result | Verdict |
|---|---|---|---|
| R0-1 | `search/grep` through `Session.handle` | `{'code': -32601, 'message': 'method not found: search/grep'}` | CONFIRMED D-04 |
| R0-2 | `serve()` with `Content-Length: abc` / body `{{{` / missing length / `[]` body | `ValueError` and `JSONDecodeError` escape `serve()`; missing length and non-dict body survived | CONFIRMED D-05 (two of four shapes) |
| R0-3 | 200 × `proc/spawn` of `true`, then count `procs` | 0 stale entries | NOT REPRODUCED R-02 |
| R0-4 | 3 MB child through a 20 ms/write consumer; compare bytes before/after `proc/exit` | 3,000,000 before, 0 after | NOT REPRODUCED R-01 (drain > 2 s untested) |
| R0-5 | Whether `m_fs_read` stats by path | No `os.stat(path)` in it | Inconclusive; R-07 stays |
| R0-6 | Exact bootstrap command shape `head -c 100 > F.tmp && mv F.tmp F` fed 40 bytes | Installed a 40-byte file as final | CONFIRMED D-02 (command shape copied from `rdev--ssh-process`) |
| R0-7 | `fs/stat` inside a mode-000 directory | Error with `errno: EACCES` | Server shape confirmed; client mapping = R-06 |
| R0-8 | `rdev--parse "/rdev:-oProxyCommand=id:/p"`; `ssh -G -oProxyCommand=echo\ pwned x` | Parses to host `-oProxyCommand=id`; ssh reports `proxycommand echo pwned` | CONFIRMED D-01. (A first attempt with `/` in the host returned `nil` only because the regexp excludes `/`; `${IFS}` tricks are unnecessary for exploitation.) |

Not tested here, so not claimed: actual ssh execution of the injected option from within `rdev` (the ssh-side acceptance was shown with `-G`, which parses but does not connect). M1 acceptance #2 covers it end-to-end.

## R1. Host validation and ssh argv (D-01)

- **Decision**: Validate `HOST` against `\`[A-Za-z0-9._@%+#\[\]:-]+\`` *and* reject a leading `-`; always pass `--` before the host in the ssh argv; resolve aliases from `~/.ssh/config` by ssh itself. Keep the `:ssh-host` plist escape hatch but validate it the same way.
- **Rationale**: A leading `-` is the only way to smuggle options; `--` makes it structurally impossible even if validation regresses. Both are tiny, behaviour-preserving for every legitimate host.
- **Rejected**: Quoting (ssh treats the arg as an option regardless); passing hosts only through `ssh -G` first (extra round trip, still needs `--`).

## R2. Bootstrap integrity and framing (D-02, D-08, D-14)

- **Decision**: Keep the ssh + `sh -c` approach and `~/.cache/rdev/rdev-server-<hash>.py`. Change the remote script so that (1) upload is `head -c N > F.tmp`, then compare `wc -c < F.tmp` to N and (when `sha256sum`/`shasum -a 256`/`python3 -c hashlib` exists) the full hash, `mv` only on match, `rm -f F.tmp` otherwise; (2) install under `umask 077`, directory `chmod 700`; (3) all bootstrap output uses a `RDEV-BOOT ` line prefix plus a final `RDEV-READY`, and after `RDEV-READY` the process is `exec`ed so the *same* pipe carries JSON-RPC; (4) the Emacs filter consumes only through the newline after `RDEV-READY` and forwards any remaining bytes to `jsonrpc`; (5) the existence check becomes size/hash check, not `-f`.
- **Rationale**: Fixes truncation and filter byte loss without changing transport or file layout; works with Linux/macOS `sh` (uses `shasum` fallback, not GNU-only flags).
- **Alternatives**: Separate scp/sftp upload (second ssh, different failure modes, requires sftp subsystem); stdin-less deploy via base64 in the command line (argv length limits, visible in `ps`); heredoc (still needs size check).
- **Python version check**: remote script runs `"$P" -c 'import sys; sys.exit(sys.version_info<(3,8))'` and emits `RDEV-BOOT {"error":"python-too-old",...}` so the client can show a structured error.

## R3. Race-safe version-checked save (D-03)

- **What the OS can and cannot do**: POSIX has no compare-and-swap for "replace file only if unchanged". Between `stat` and `rename` another writer can slip in. The achievable guarantees are: (a) **atomic visibility** — readers see old or new, never partial (temp file in the same directory + `fsync` + `os.replace`); (b) **conflict detection with a bounded race window** — the server re-stats immediately before `os.replace`.
- **Decision**: `fs/writeAtomic` on the agent: create temp in the destination directory with `O_EXCL`, write, `fsync` the file, copy mode (and uid/gid when allowed) from the target if it exists, compare the target's `{mtime_ns,size,ino,dev}` against `expected` (and optional `sha256` if given) immediately before `os.replace`, `fsync` the directory best-effort, return the new version. Mismatch → error `CONFLICT` (code `-32010`) with the current version. Atomic persistence across power loss is documented as "best effort: file and directory fsync issued, filesystem-dependent".
- **Symlinks**: if the target is a symlink, write to the resolved target (not replace the link) — matches what Emacs/TRAMP users expect; `follow_symlinks=false` is an opt-out. Hard-linked targets and non-regular files fall back to in-place write after the version check (documented: not atomic) because `os.replace` would break the link.
- **Fallback**: if temp creation fails (read-only dir but writable file), use in-place write with the same version check and mark the response `atomic:false` so Emacs can message once.
- **Rationale**: Honest about the residual race rather than claiming locking; the window shrinks from "seconds between open and save" to microseconds.
- **Rejected**: `flock` advisory locks (other editors ignore them, NFS flaky); content hash on every save (cost; kept optional for chunked transfers).

## R4. Protocol versioning and capabilities (F1)

- **Decision**: Extend `hello` additively (see contracts/protocol.md). Compatibility is determined by `protocol` (integer major) and `capabilities` (string set). Absence ⇒ legacy 1.0.
- **Rationale**: The existing agent has no version field; the client must detect "old agent" by *absence*, which works with the current server file unmodified (tested in M1).
- **Rejected**: Version in the agent filename only (can't express partial feature support); JSON-RPC batch negotiation (jsonrpc.el does not support it).

## R5. Message validation and limits (D-05)

- **Decision**: Header section ≤ 8 KiB and ≤ 32 lines; `Content-Length` must be a base-10 integer 0 ≤ n ≤ `max_message` (default 32 MiB; advertised in `hello`); body must be a JSON object (or array → JSON-RPC batch unsupported error); bad framing ⇒ send `-32700/-32600` where an id is recoverable, otherwise close the session after logging to stderr; unknown method ⇒ `-32601`; params type mismatch ⇒ `-32602` (catch `TypeError` from `fn(**params)` and reject unexpected keys by name, not by traceback).
- **Rationale**: A session is long-lived; one bad frame must not drop all remote processes. Resync after a bad header is not possible, so close is correct there.

## R6. Concurrency model (F3, C3)

- **Decision**: One reader thread dispatching; fast methods run inline; slow methods (`exec/run`, `project/files`, `search/grep`, chunk reads over a threshold) go to a `ThreadPoolExecutor(max_workers=8)` (configurable `--workers`); one `threading.Lock` for `procs`/`next_id`; one `threading.Lock` around the socket/pipe write path (already needed for interleaved notifications; verify existing). Register `Proc` in `procs` **before** starting its threads; remove it after `proc/exit` is queued.
- **Rationale**: Minimal diff, no new dependency, bounded threads.
- **Rejected**: asyncio (rewrite), multiprocessing (state sharing).

## R7. Backpressure (F5, D-13)

- **Decision**: Per-process output goes through a bounded queue (default 1 MiB total, 64 KiB chunks). The pump thread blocks when full ⇒ the child blocks on its pipe ⇒ OS-level flow control. Optional credit-based window (`proc/ack`) is **not** adopted initially: the transport is already ordered and blocking writes provide the same effect; the cost is head-of-line blocking across processes on one connection, accepted and documented. If Emacs stops reading, ssh's pipe fills and writers block; on disconnect the session finally block terminates owned processes (clarified default).
- **Rejected**: Dropping output (silent loss), unbounded queue (memory).

## R8. Cancellation (F4)

- **Decision**: `$/cancel {id}` notification (client→agent). Cancellable: `exec/run`, `search/grep`, `project/files`, chunk reads/writes. Agent keeps `inflight[id] = threading.Event` + optional `Popen`; handlers poll the event; `exec/run` kills the process group. A cancelled request still gets a response (`-32800` "cancelled") so correlation is preserved. Non-cancellable (documented): single `fs/*` syscalls, `fs/copy`/`delete -r` mid-flight (cancel takes effect between entries only).
- **Client**: `C-g` during `rdev--req` sends `$/cancel` then re-signals quit.

## R9. Connection state machine and reconnect (A3, A4)

- **Decision**: States as in spec; transitions table in data-model.md. Reconnect via `run-with-timer` with exponential backoff `min(cap, base·2^n)` plus jitter (defaults base 1 s, cap 30 s, max 8 attempts, then `FAILED`). Pending requests fail immediately with `rdev-connection-lost` on loss. Processes owned by the dead connection get status `interrupted`; their relay subprocesses receive `X 255`. Nothing is replayed automatically. Each conn carries a `gen` counter; cache entries and open-file versions from an older generation force a re-stat and conflict check before the next save.
- **Rationale**: Satisfies "never repeat a command whose status is unknown" structurally: there is no replay path.

## R10. File notifications (B6)

- **Decision**: Capability `watch`. Agent backends in order: `inotify` through `ctypes` (Linux, stdlib), `kqueue` via `select.kqueue` (macOS/BSD, stdlib), polling `os.scandir` snapshot diff at 1 s as fallback. Emacs side registers through `file-notify-add-watch` returning a descriptor mapped to a server watch id; events are delivered as `watch/event` notifications and converted to the standard `(descriptor action file [file1])` form. Watches are re-registered after reconnect and dropped on disconnect.
- **Rationale**: stdlib only; fallback guarantees behaviour on any host.
- **Risk**: `ctypes` inotify limits (`max_user_watches`) → surface as a capability-level error and fall back to polling for that watch.

## R11. Search (spec D3, defect D-04)

- **Decision**: `search/grep` runs `rg --json` (if present) with args built from the structured request (never via shell); parse JSON lines into `search/result` notifications in batches (≤ 100 matches or 50 ms), final response carries `{count, truncated, engine}`. Fallback engine: Python `re` over `os.walk` honouring `.gitignore` for git trees via `git ls-files -co --exclude-standard` when `git` exists, else simple walk with a built-in ignore list; fallback is documented as slower and reports `engine:"python"`. Missing both ⇒ never silently succeed.
- **Rationale**: Reuses ripgrep's speed/ignore handling when present; no mandatory deps.

## R12. project.el backend (D2)

- **Decision**: `project-find-functions` hook entry returning `(rdev . ROOT)` for remote dirs; root discovery runs one RPC (`project/root`, capability) walking up for configured markers (`.git`, `.hg`, `pyproject.toml`, `package.json`, `Makefile`, … from a defcustom); `project-files` uses `project/files` (existing) with `git ls-files` fast path on the server. Falls back to the built-in `vc` backend behaviour if the capability is absent (legacy agent).
- **Rejected**: relying solely on `vc-git` (needs a synchronous `git` per call through `process-file` → N round trips).

## R13. Eglot, Magit, Dape validation approach

- **Eglot**: `eglot` already uses `make-process` with `:file-handler t` for remote servers and `file-local-name`/`eglot-path-to-uri` for URIs. Risk is whether our `make-process` honours the keywords Eglot passes (`:stderr`, `:noquery`, `:connection-type`). Test with real `pylsp` (installed) and `clangd` (installed): initialize, open, edit, diagnostics, completion, definition, references, rename, code action, kill server → restart. Expect to need `file-local-name`/URI mapping verification only; patch only on failing tests.
- **Magit**: uses `process-file` (synchronous) and `start-file-process`; `magit-git-executable` resolved via `executable-find` with `remote=t`; path handling uses `magit-convert-filename-for-git`/`file-local-name`. Test with real repo status/diff/stage/commit/log/branch; synchronous `process-file` cost is the main performance risk (R-blocking table). Also check `default-directory` trailing-slash handling in `rdev--normalize`.
- **Dape**: needs remote adapter launch (`make-process` through the relay) plus local↔remote path mapping (`dape-…` config `:cwd`, `:program`, `prefix-local/-remote`) and TCP/stdio adapter transport. `debugpy` is **not installed** locally; the plan requires a venv in the E2E fixture (`python -m venv` + `pip install debugpy` on the test remote), so Dape tests are tagged `:needs-debugpy` and skipped with a visible reason if unavailable — never silently passed.

## R14. Testing harness

- **ERT fake server**: an in-process Python subprocess running the real `rdev-server.py` over a pipe, so ERT exercises the real agent without ssh; `jsonrpc-process-connection` is the same class used in production. Local twin directory comparison asserts handler results equal native Emacs results for the same tree.
- **SSH fixture**: start `sshd -f <generated> -p <random>` as the current user on `127.0.0.1` with a throwaway host key and `AuthorizedKeysFile` containing a throwaway key; point `rdev-ssh-args` at `-F <generated ssh_config>`. Needs no root. Teardown kills it.
- **Network shaping**: `tc netem` needs privileges; the fixture first tries `unshare -rn`+`tc`, then falls back to a `ProxyCommand` delay/loss shim written in Python (documented as less faithful). Bandwidth limiting in the shim by token bucket.
- **macOS**: cannot be provided locally; M1 records macOS pass/fail/not-run and the spec's "fully supported" claim is not marked satisfied until a real macOS run exists.
- **Emacs matrix**: 30.1 (build or container image) and current.

## R15. Local relay hardening (G4, D-09, D-10)

- **Decision**: Create the socket inside `$XDG_RUNTIME_DIR/rdev` (or `~/.cache/rdev/run`) with mode 0700; `umask 077` around `bind`; verify peer uid with `SO_PEERCRED` in the relay server accept path (Linux; `LOCAL_PEERCRED` on macOS) when available; cap `LEN` at 16 MiB; unknown type ⇒ close that channel and log; payload parse errors (`X`, `H`) ⇒ treat as `X 255`. Applies on both ends. No byte-format change.

## R16. Exit-code convention (D-07)

- **Decision**: Normalize to the shell convention `128 + signum` for signalled children in both `exec/run` and `proc/exit`, and return the raw signal separately (`signal: N`) as an additive key. Document as a deliberate behaviour change for `exec/run` (previous `128 - code` was never a valid convention).

## R17. Per-connection channel scoping (D-06)

- **Decision**: Internal key `(host . id)`; relay hello still sends a numeric chan which Emacs maps; `proc/out`/`proc/exit` handlers are already per-conn (`rdev--dispatch _conn …`) so lookup uses `(conn-host . id)`. Server ids are unique within a session already; the collision is purely client-side.

## R18. TCP transport (G2, D-11)

- **Decision**: Connect refuses non-loopback unless `(plist-get spec :insecure-ok)` or `rdev-allow-insecure-tcp` is set for that host; when set, every connect shows a warning in the echo area and logs it. Server default bind remains `127.0.0.1`; `--listen 0.0.0.0` prints a warning. Token only via `--token-file` or `RDEV_TOKEN` env (the `--token` argv form is kept for compatibility but warns that it is visible in `ps`). Constant-time compare (`hmac.compare_digest`) is already in place. After 5 failed auths per connection, close. Recommend SSH port forwarding in the docs.

## R19. Cache (B5)

- **Decision**: Keep per-conn hash; add `rdev-cache-max-entries` (default 5000) with oldest-first eviction, hit/miss/evict counters, invalidate target + parent dir on every mutating op (audited by a test that enumerates all mutating handler ops), full drop on generation change. `fs/readdir attrs=true` populates children into the cache.

## Summary of rejected "big" designs

- Replace relay with direct ssh per process: contradicts constraint.
- asyncio agent / rewrite in Go or Rust: contradicts no-redesign and stdlib-only.
- TRAMP-method integration: contradicts "own namespace and handler".
- Persistent detached remote processes (tmux-like): spec forbids promising it without session-independent management; deferred beyond this plan.
