# Contract: Agent JSON-RPC Protocol

Transport: JSON-RPC 2.0, `Content-Length` framing, over ssh stdio or token-authenticated TCP. **Existing methods are frozen** (names, required params, result keys). New behaviour is additive: optional params, extra result keys, new methods gated by capability. Clients must ignore unknown result keys; the agent must ignore unknown *optional-envelope* keys only where stated, and rejects unknown params with `-32602` (as today, `fn(**params)` raises) — so new optional params are only sent when the capability is advertised.

## 1. Framing and limits (M1)

- Headers: ≤ 8 KiB, ≤ 32 lines, `Content-Length` required, decimal, `0 ≤ n ≤ max_message` (default 33554432).
- Body: UTF-8 JSON object. Batches unsupported → `-32600`.
- Violations: if an id is recoverable → error response, else log + close the session (no resync possible). Never an unhandled exception.
- Error codes: `-32700` parse, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal, plus reserved application codes below. Existing `os_error` shape (`data.errno`, `data.filename`) is preserved.

| Code | Name | `data` |
|---|---|---|
| -32010 | CONFLICT | `{expected, actual}` FileVersion |
| -32011 | TOO_LARGE | `{limit, size}` |
| -32012 | UNSUPPORTED | `{capability}` |
| -32013 | BAD_TRANSFER | `{tid, reason}` |
| -32800 | CANCELLED | — |

## 2. Handshake

### `hello` (existing)

Request (legacy, still valid): `params: {}` (or none).
Request (v2 client): the client **always sends the first `hello` with no params**. Only if the result contains `protocol` does it send a second `hello` with `{"client": {"protocol": [1, 2], "capabilities": [...], "name": "rdev-el", "version": "2.0"}}` (advisory, for agent logging). No behavior depends on an error code, because the legacy agent's `m_hello(self)` rejects any params with `-32603` (`TypeError`), not `-32602` (verified 2026-11-22).

Result today: `{version, home, user, uid, host, path, python}`.
Result additions: `protocol: int`, `capabilities: [str]`, `limits: {max_message, max_chunk, max_transfer, workers}`, `agent_hash: str`, `python: "3.x.y"` (existing), `platform: "linux"|"darwin"|…`.

Negotiation rules:
1. `protocol` absent ⇒ legacy 1.0: client uses only the frozen method set, no new params; shows one notice recommending agent refresh (auto-refresh by hash happens at bootstrap).
2. Client supports protocol set `S`; agent `protocol ∈ S` ⇒ ok; else `FAILED` with actionable message ("agent speaks protocol N; client supports S; run `M-x rdev-restart-server` / update rdev").
3. Features are used only if their capability string is in `capabilities`.

Capability strings: `fs.writeAtomic`, `fs.chunk`, `fs.statMany`, `cancel`, `search.grep`, `project.root`, `watch`, `session.shutdown`, `proc.ownership`.

### `auth` (existing, TCP only) — unchanged. After 5 failures the agent closes. Compared with constant time.

## 3. Existing methods (frozen)

`fs/stat`, `fs/readdir`, `fs/read`, `fs/write`, `fs/mkdir`, `fs/delete`, `fs/rename`, `fs/copy`, `fs/chmod`, `fs/utime`, `fs/symlink`, `fs/link`, `fs/realpath`, `fs/statvfs`, `exec/run`, `proc/spawn`, `proc/write`, `proc/eof`, `proc/signal`, `proc/resize`, `project/files`, notifications `proc/out {id,data,stream?}`, `proc/exit {id,code}`.

Compatible changes inside frozen methods (no signature change):
- `fs/read`: result gains `version` (FileVersion taken from the open fd — R-07); `mtime` kept.
- `fs/write`: result gains `version`; behaviour unchanged (still truncating, still used for append/excl/legacy).
- `fs/stat`: result gains `ino`, `dev` if not present; callers unaffected.
- `exec/run` and `proc/exit`: signalled exit code becomes `128 + sig` (D-07), result/notification gains `signal`. Deliberate, documented change.
- `search/grep` before M2: returns `-32012 UNSUPPORTED` (instead of `-32601`) and is removed from capability list.

## 4. New methods

### `fs/writeAtomic` (cap `fs.writeAtomic`, M1)

Params: `path`, `data` (base64), `expected` (FileVersion | null), `create` (bool, default true), `mode` (int | null; default: preserve existing, else 0666&~umask), `force` (bool, default false), `follow_symlinks` (bool, default true), `sha256` (optional hex of decoded data).
Result: `{version, atomic: bool, bytes}`.
Semantics: see research R3. `expected: null` + `create: true` + target exists + not `force` ⇒ CONFLICT (new-file create must not clobber). Errors preserve the `os_error` shape.

### Chunk family (cap `fs.chunk`, M2)

- `fs/readChunk {path, offset, length, expected?}` → `{data, eof, version}`; `length ≤ max_chunk`.
- `fs/beginWrite {path, expected, size?, mode?, create?, follow_symlinks?}` → `{tid, chunk}` (agent-chosen chunk size ≤ max_chunk).
- `fs/writeChunk {tid, offset, data}` → `{received}`. Offsets must be contiguous; gap/overlap ⇒ `BAD_TRANSFER`.
- `fs/commitWrite {tid, sha256?, size?}` → `{version, atomic}`; verifies size/hash, runs the §R3 sequence, cleans temp.
- `fs/abortWrite {tid}` → `{}`; idempotent.
- Idle > 120 s or session end ⇒ agent aborts and deletes the temp file. Total > `max_transfer` ⇒ `TOO_LARGE`.

### `fs/statMany {paths[]}` (cap `fs.statMany`, M2)

→ `{results: [{path, stat | error}]}`; single round trip for prefetch.

### `$/cancel` (notification, cap `cancel`, M2)

`{id: <request id>}`. Target gets `-32800` response. Cancellable: `exec/run`, `search/grep`, `project/files`, `fs/readChunk`, `fs/writeChunk`. Not cancellable: single-syscall `fs/*`; `fs/copy`/`fs/delete` recursive stop between entries. Unknown id ⇒ ignored.

### `search/grep` (cap `search.grep`, M2)

Params: `root`, `pattern`, `regex` (bool), `case` (`smart|sensitive|insensitive`), `globs` (list, `!` prefix excludes), `ignore` (bool, default true: honour `.gitignore`/`.ignore`), `hidden` (bool), `max_results` (default 1000), `context` (0–5), `stream` (bool, default true).
Notification `search/result {id, matches: [{path, line, col, text, submatches:[[s,e]]}]}` batched. Final result `{count, truncated, engine: "rg"|"python"}`. Missing `rg` ⇒ python engine (flagged), never an empty success. Invalid regex ⇒ `-32602` with message.

### `project/root` (cap `project.root`, M3)

`{dir, markers[]}` → `{root | null, marker}`.

### `watch/add {path, recursive?, flags[]}` → `{wid, backend}`; `watch/remove {wid}`; notification `watch/event {wid, action: created|changed|deleted|renamed, path, path2?}` (cap `watch`, M3). Watches die with the session.

### `session/shutdown` (cap `session.shutdown`, M2)

Graceful: terminate owned processes per policy, abort transfers, reply, exit.

### `proc/spawn` additive params (cap `proc.ownership`)

`owned: bool` (default true ⇒ terminated at session end), `grace_ms` (default 2000). Response/`proc/exit` unchanged.

## 5. Ordering and delivery

- Notifications and responses are serialized on one writer (lock-protected); a `proc/exit` is queued after all `proc/out` for that id (the agent joins both pumps before sending exit; timeout extended from 2 s to "until drained or process group dead + 10 s", with an explicit `truncated: true` key if gave up).
- Requests may complete out of order; correlation by id.

## 6. Compatibility test obligations

1. Pre-change `rdev-server.py` (pinned copy under `test/fixtures/legacy-server.py`) must pass the new client's legacy-mode suite.
2. New agent must pass the *old* client's behaviours (hello with no params, all frozen methods).
3. Contract tests assert the frozen method list and result key supersets.
