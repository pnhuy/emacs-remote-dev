# Data Model: RDEV 2.0

Entities are runtime structures, not persisted databases. "Existing" marks what is in the code today.

## Connection (`rdev-conn`, existing, extended)

| Field | Type | Notes |
|---|---|---|
| `host` | string | existing; validated (no leading `-`) |
| `rpc` | jsonrpc connection | existing |
| `home`, `path` | strings | existing (from `hello`) |
| `cache` | hash-table | existing; bounded, per conn |
| `state` | symbol | NEW — see state machine |
| `gen` | integer | NEW — increments on every (re)connect |
| `proto` | integer or nil | NEW — nil ⇒ legacy 1.0 |
| `caps` | list of strings | NEW |
| `limits` | plist | NEW — `max-message`, `max-chunk`, `max-transfer` |
| `transport` | `ssh` \| `tcp` | NEW |
| `log` | buffer | NEW — `*rdev-log HOST*` (stderr + state transitions) |
| `stats` | plist | NEW — requests, errors, cache hits/misses/evictions, reconnects |
| `procs` | list of chan ids | NEW — owned processes |
| `policy` | plist | NEW — termination policy (default `terminate`) |

Uniqueness: at most one `rdev-conn` per logical host key; `rdev--conn` under `CONNECTING`/`RECONNECTING` waits on or returns the in-flight attempt instead of starting another.

### State machine

States: `DISCONNECTED, CONNECTING, BOOTSTRAPPING, INITIALIZING, CONNECTED, DEGRADED, RECONNECTING, FAILED, DISCONNECTING`.

| From | Event | To |
|---|---|---|
| DISCONNECTED | connect requested | CONNECTING |
| CONNECTING | ssh/tcp process up | BOOTSTRAPPING (ssh) / INITIALIZING (tcp) |
| BOOTSTRAPPING | `RDEV-READY` | INITIALIZING |
| BOOTSTRAPPING | install/py-version/timeout error | FAILED |
| INITIALIZING | `hello` ok + compatible | CONNECTED |
| INITIALIZING | incompatible / auth fail / timeout | FAILED |
| CONNECTED | keepalive miss / slow responses | DEGRADED |
| DEGRADED | recovers | CONNECTED |
| CONNECTED, DEGRADED | transport closed unexpectedly | RECONNECTING |
| RECONNECTING | attempt ok | INITIALIZING → CONNECTED |
| RECONNECTING | attempts exhausted | FAILED |
| any except DISCONNECTED | user disconnect | DISCONNECTING → DISCONNECTED |
| FAILED | `rdev-reconnect` / connect | CONNECTING |

Rules: transitions go through one function that logs, updates the mode-line/list UI, and runs `rdev-connection-state-hook`; illegal transitions signal an internal error in tests and are ignored with a log entry otherwise.

## FileVersion (token)

`{mtime_ns: int, size: int, ino: int, dev: int, sha256?: string}`. Returned by `fs/stat`, `fs/read`, `fs/readChunk` (final), `fs/writeAtomic`, `fs/commitWrite`. Client stores it per visiting buffer (buffer-local `rdev--version`, plus conn `gen`). On save: send as `expected`. After reconnect (`gen` changed) the client re-stats before send; a mismatch raises `rdev-conflict`.

## Conflict (`rdev-conflict`, error)

Signal data: `(rdev-conflict FILE EXPECTED ACTUAL)`; derives from `file-error`. Handled by the save wrapper offering: **refresh** (revert), **compare** (diff local buffer vs remote copy), **overwrite** (explicit confirm → resend with `expected: null, force: true`). No silent overwrite path.

## Transfer

| Field | Notes |
|---|---|
| `tid` | agent-generated, opaque |
| `path`, `tmp` | target, staging file in same directory (writes) |
| `mode` | `read` / `write` |
| `size_limit` | from `limits.max-transfer` |
| `received` | bytes accepted so far (writes must be in-order; offset checked) |
| `expected` | FileVersion to check at commit |
| `hash` | incremental sha256 |
| `created`, `last_active` | idle timeout 120 s ⇒ auto-abort and temp cleanup; also aborted on session end |

## Process / Channel

| Field | Notes |
|---|---|
| agent: `Proc` | `id` (session-unique), `pid`, pty flag, pump threads, `owned` |
| client: `rdev-chan` | existing; adds `host`, `status` (`running`/`exited`/`interrupted`), `exit` |
| registry key | client `(host . id)`; agent `id` |

Lifecycle: spawn → register (before threads start) → running → exit (drain pumps) → `proc/exit` → unregister. Connection loss ⇒ client marks `interrupted` and sends `X 255` to relay; agent terminates owned processes (default) via process-group SIGHUP then SIGKILL after grace (2 s).

## RelayChannel

Relay socket connection ↔ `rdev-chan`. Frames in [contracts/relay-frames.md](contracts/relay-frames.md). Socket directory 0700, files 0600.

## Watch

`{wid, path, flags, backend (inotify|kqueue|poll), descriptor (client)}`; owned by connection `gen`; dropped on disconnect, re-registered after reconnect.

## SearchRequest / SearchMatch

Request: `{pattern, regex, case, globs[], ignore (default true), max_results, context, root}`. Match: `{path, line, col, text, submatches[]}` delivered in `search/result` batches. Final response: `{count, truncated, engine}`.

## Cache entry

`local-name → (timestamp . attrs-or-:missing)`; bounded; invalidated by target+parent on mutators; dropped on `gen` change.

## Benchmark result

`{scenario, op, rtt_ms, loss, bw, tool (rdev|tramp), n, median, p95, max, failures, rss_kb?}` stored as CSV in `bench/`.
