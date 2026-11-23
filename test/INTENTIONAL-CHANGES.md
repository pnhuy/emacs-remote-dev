# Intentional behavior changes

Entries are added only when a fix deliberately changes behavior pinned by the baseline.
Each entry: date, task, test changed, rationale, migration note.

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
