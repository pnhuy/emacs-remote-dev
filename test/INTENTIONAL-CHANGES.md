# Intentional behavior changes

Entries are added only when a fix deliberately changes behavior pinned by the baseline.
Each entry: date, task, test changed, rationale, migration note.

## 2026-11-28 — Docker: review fixes (failure records, display name, exec by ID)
- **Before**: a connect whose `docker inspect` failed recorded no state (the key was resolved
  before the failure handling), and a reconnect to a removed container dropped the cached key, so
  `rdev-list-connections` signaled. The list's Target column showed the container ID cut to 18
  characters. The UID probe and transport ran `docker exec` by name. The `/tmp/rdev-<uid>`
  fallback was used without an ownership check. Discovery had no byte cap. CLI errors read
  `docker failed (1): ...` without the engine or account.
- **After**: the failure is recorded under the previous key, or under
  `docker:<engine>:unresolved/<container>` for a target that never resolved, and key lookups
  never signal. The list shows `docker:<engine>/<name>` (28-character column) and `rdev-status`
  shows the name plus a 12-character ID. Probe and transport exec the inspected ID. The fallback
  requires the account to own both directories, neither a symlink. `docker ps` output is cut at
  1 MiB (reported as truncated). Messages name the container, engine, account (for `permission`)
  and a remedy.
- **Tests**: `rdev-docker-failed-first-connect-records-reason`,
  `rdev-docker-vanished-container-keeps-session-key`, `rdev-docker-session-key-never-signals`,
  `rdev-docker-exec-uses-container-id`, `rdev-docker-tmp-fallback-requires-ownership`,
  `rdev-docker-discovery-output-is-byte-capped`,
  `rdev-docker-error-messages-name-engine-and-account`; updated
  `rdev-docker-ui-shows-container-target`, `rdev-docker-bootstrap-parameterization` and E2E
  `e2e-docker-discovery-and-status`.
- **Migration**: none. A pre-existing `/tmp/rdev-<uid>` owned by another account (or a symlink) now
  fails with `unsupported` instead of being used; remove it or give the container a usable `HOME`.

## 2026-11-28 — host completion after `/rdev:'
- **Before**: `file-name-directory` on a partial `/rdev:par` returned `/`, so the minibuffer looked
  for local files named `rdev:par` and offered no host completion.
- **After**: `file-name-directory` returns `/rdev:` for a partial host, and
  `file-name-all-completions`/`file-name-completion` offer configured targets, ssh-config hosts
  and running containers with their closing colon. Full `/rdev:host:/path` names are unchanged.
- **Tests**: `rdev-completion-host-after-rdev-colon`, `rdev-completion-host-directory-split`,
  `rdev-completion-host-unique-and-all`.
- **Migration**: none; only the completion behavior for partial names changed.

## 2026-11-28 — Docker: global `rdev-docker-allow-root` option
- **Before**: the root opt-in was per target only (`:allow-root t` on one `rdev-hosts` entry).
- **After**: `rdev-docker-allow-root` (default nil) is a global default for Docker targets without
  `:allow-root`. An explicit `:allow-root` on a target always wins, including `:allow-root nil`,
  which opts that target out even when the global option is on; otherwise the global value
  applies (`rdev-docker--allow-root-p`). The warning on every connect, the log record, and the agent
  `--allow-root` flag now follow the effective value. Both the per-target and global options are
  off by default, so existing deployments are unchanged.
- **Tests**: `rdev-docker-root-policy-global-option`, `rdev-docker-global-allow-root-connects`,
  and E2E `e2e-docker-global-allow-root`.
- **Migration**: none; the default remains refusal. The global option is broader than the
  per-target one and is documented as such in `docs/security.md`.

## 2026-11-28 — Docker: explicit `docker+NAME` addresses for unconfigured containers
- **Before**: a name with no `rdev-hosts` entry always used the SSH transport, including a name of
  the form `docker+NAME`.
- **After**: a key matching `docker+NAME` or `docker+NAME@DH` (NAME a valid container name) with no
  `rdev-hosts` entry is the container NAME on the local engine, or on the engine reached over SSH
  at DH. Parsing is pure: nothing is queried and `rdev-hosts` is not changed. Any other
  unconfigured name is still SSH, whatever containers are running. Host completion offers running
  containers under these keys. Discovery runs in the background (stale-while-revalidate): a
  prompt waits at most `rdev-docker-discovery-wait` (0.3 s), and only when no snapshot exists. A
  failed engine is retried after `rdev-docker-discovery-backoff` (30 s).
  `rdev-docker-auto-detect` (default t) now only controls whether the local engine is listed in
  completion. `rdev-docker-connect NAME` connects a bare name as `docker+NAME` instead of adding
  an `rdev-hosts` entry.
- **Tests**: `rdev-docker-bare-name-is-never-a-container`, `rdev-docker-explicit-address-spec`,
  `rdev-docker-explicit-address-connects-without-config`,
  `rdev-docker-completion-offers-local-containers-as-addresses`,
  `rdev-docker-completion-local-discovery-can-be-disabled`,
  `rdev-docker-completion-never-waits-on-a-hung-engine`,
  `rdev-docker-completion-serves-stale-snapshot-and-refreshes`,
  `rdev-docker-completion-queries-each-engine-once`,
  `rdev-docker-connect-command-uses-explicit-address`, and E2E
  `e2e-docker-open-by-address-without-config`.
- **Migration**: an ssh alias that itself starts with `docker+` would now be read as a container
  address. Add an `rdev-hosts` entry with a nil plist for it (an entry always wins) to keep SSH.

## 2026-11-28 — Docker: agent gains the `--allow-root` flag
- **Before**: the agent refused uid 0 unconditionally (`os.geteuid() == 0` → `RDEV-ERR` + exit 5)
  before argument parsing; `test/py/test_root_refusal.py::test_no_override_flag` asserted that no
  `--allow-root` string existed in the source.
- **After**: the refusal still applies by default with the same message and exit 5, but the check
  runs after `argparse` and `--allow-root` (command line only; never from the environment, a
  config file or RPC) permits running as root, printing a WARNING to stderr. This exists solely
  for Docker targets with `:allow-root` set.
- **Tests**: `test/py/test_root_refusal.py` rewritten: default refusal pinned, env override
  (`RDEV_ALLOW_ROOT=1`) still refused, `--allow-root` reaches session startup, and the source
  check now asserts the flag is CLI-only (no `RDEV_ALLOW_ROOT` in the source).
- **Migration**: none. Existing ssh/TCP deployments cannot reach root (no env or RPC path); the
  agent exits 5 as before.

## 2026-11-28 — Docker: connection list gains a Target column
- **Before**: `rdev-list-connections` showed Host, State, Latency, Procs, Cache e/h/m, Agent,
  Protocol (7 columns); `rdev-ui-test.el` pinned that layout and column indexes.
- **After**: a `Target` column (index 1) shows `docker:<engine>/<container-id>` for Docker targets
  and `-` otherwise; subsequent columns shift by one. `rdev-status` prints the container/engine
  line for Docker targets. Hosts, states and actions are unchanged.
- **Tests**: `test/rdev-ui-test.el` column list and indexes updated; new assertions in
  `test/rdev-docker-test.el` (`rdev-docker-ui-shows-container-target`).
- **Migration**: none for behavior; only the display layout changed.

## 2026-11-28 — Docker: bootstrap script parameterized, SSH output unchanged
- **Before**: `rdev--bootstrap-template` was a single literal used only by the ssh transport.
- **After**: the same script is produced by `rdev--bootstrap-script (&optional HOME-FALLBACK
  AGENT-ARGS)`; with no arguments the output is byte-identical to the previous literal (pinned by
  `rdev-docker-bootstrap-parameterization`). Docker targets add the `/tmp/rdev-<uid>` fallback and
  optionally `--allow-root`; the ssh install path is unchanged.
- **Tests**: `test/rdev-docker-test.el` (parameterization, fallback install under `/tmp/rdev-<uid>`).
- **Migration**: none; ssh deployments see the same script and the same hash-pinned install path.

## 2026-11-28 — test robustness: deterministic `search/grep` cancel (pre-existing flake)
- **Before**: `test/py/test_search.py::CancelSearch` sent the cancel 0.3 s after a search whose
  pattern matched and whose result cap (100000) it hit in ~0.2 s on a fast machine: the search
  finished before the cancel, so the response was a `result`, not `-32800` (KeyError in the
  assertion). `rg` completes the same 264 MB scan in <50 ms, so no sleep-based cancel can win.
- **After**: the cancel test uses a non-matching pattern (no early cap exit) and sends `$/cancel`
  immediately; the server's reader thread processes it right after submitting the search, which
  either pre-empts the worker or lands mid-scan — both produce `-32800`.
- **Tests**: `test/py/test_search.py` only; no product code changed.
- **Migration**: none.

## 2026-11-22 — T045: fs/* params validated (FR-035)
- **Before**: a NUL byte in a path raised `ValueError` inside the handler and surfaced as
  `-32603 internal error`; a non-string path surfaced as `-32603` (TypeError) or was coerced.
  `mode`/`mtime_ns` of the wrong type reached `os.chmod`/`os.utime`.
- **After**: `-32602 invalid params` before any filesystem call, for: non-string or empty
  path-like params (`path src dst link root`), NUL in any path-like param, non-int or bool
  `mode`/`mtime_ns`. No side effects occur on rejection.
- **Not changed**: relative paths are still accepted (resolved against the agent cwd) because the
  client's behavior relied on it; symlink semantics are unchanged.
- **Tests**: `test/py/test_fs_validation.py` (new). No baseline test needed changing.
- **Migration**: none for the shipped client, which only sends absolute string paths. A custom
  client sending such inputs now receives `-32602` instead of `-32603`.

## 2026-11-22 — D-07 (T072): reclassified, no behavior change
- Characterization showed `exec/run` already returns `code = 128 + sig` and a `signal` key for
  signalled children, identical to `proc/exit`. D-07 was a code-cleanliness issue (`128 - (-15)`
  arithmetic), not a behavioral defect. `test/py/test_exit_codes.py` pins the equivalence.

## 2026-11-22 — T076: exec/run output cap and bounded concurrency
- **Before**: `exec/run` buffered stdout/stderr without limit (agent memory unbounded) and every
  `exec/run`/`project/files` request got its own thread. A timeout left the child's process group
  running and surfaced as `-32603`.
- **After**: combined stdout+stderr above 16 MiB (`EXEC_MAX_OUTPUT`) kills the process group and
  returns `-32011 TOO_LARGE` (`data.limit`); `proc/spawn` streaming is the intended path for big
  output. Slow requests run on a pool of `--workers` threads (default 8); extra requests queue.
  `exec/run` children run in their own session and the whole group is killed on timeout, cancel
  or cap. A timeout is still `-32603 TimeoutExpired` (message unchanged in kind).
- **Also**: `proc/exit` may carry `truncated: true` and is sent only after the output drained or
  was abandoned (T075); capability `cancel` and the `$/cancel {id}` notification are new (T077).
- **Tests**: `test/py/test_backpressure.py`, `test_proc_drain.py`, `test_cancel.py`,
  `test/rdev-cancel-test.el`. No baseline test needed changing.
- **Migration**: a client that relied on >16 MiB `exec/run` output must use `proc/spawn`.

## 2026-11-22 — T043 side effect: Emacs supersession prompt now precedes the agent check
- `process-file` on a host clears its attribute cache, so after an external change made through
  RDEV the buffer's `verify-visited-file-modtime` sees the new mtime and Emacs's own
  "file changed on disk" prompt appears before the agent's version check. Previously a stale
  cached mtime hid the change from Emacs and only the agent refused the save. Both paths end in
  a user decision (never silent loss). `test/e2e/conflict.el` answers the Emacs prompt so the
  agent-side `rdev-conflict` is still exercised.
