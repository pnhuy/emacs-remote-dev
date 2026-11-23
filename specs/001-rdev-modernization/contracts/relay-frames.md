# Contract: Local Relay ↔ Emacs Frames

Unchanged byte format: `TYPE(1 byte) LEN(4 bytes, big-endian) PAYLOAD`.

| Dir | Type | Payload | Meaning |
|---|---|---|---|
| relay→Emacs | `H` | `"<chan> <rows> <cols>[ <token>]"` ASCII | First frame; identifies channel and tty size. The optional per-session token must match what Emacs expects, else Emacs drops the connection (see `docs/security.md`) |
| relay→Emacs | `I` | bytes | stdin data |
| relay→Emacs | `C` | empty | stdin closed (EOF) |
| relay→Emacs | `S` | decimal signal number | forwarded signal |
| relay→Emacs | `W` | `"<rows> <cols>"` | window size change |
| Emacs→relay | `O` | bytes | stdout |
| Emacs→relay | `E` | bytes | stderr |
| Emacs→relay | `X` | decimal exit code | exit relay with that code |

## Validation (M1, both ends)

- `LEN ≤ 16 MiB` (16777216). Larger ⇒ treat as protocol error.
- Unknown `TYPE` ⇒ protocol error.
- Protocol error on the Emacs side: log, signal-free: send `X 255` best effort, close the socket, mark the chan `interrupted`, never raise out of the process filter.
- Protocol error on the relay side: exit 255.
- `H` payload must match `^\S+ \d+ \d+$`; `X` payload must be `-?\d+` (otherwise exit 255, not `ValueError`).
- Partial frames across reads are buffered (already the case); buffer growth bounded by `LEN` cap.

## Socket security (M2, D-10)

- Directory `$XDG_RUNTIME_DIR/rdev/` (fallback `~/.cache/rdev/run/`), mode 0700, owner check on creation.
- `bind` under `umask 077`; socket mode 0600.
- Accept path verifies peer uid equals Emacs's uid (`SO_PEERCRED` on Linux, `LOCAL_PEERCRED` on macOS) when the platform supports it; otherwise relies on directory permissions and logs that the check was skipped.

## Channel identity (M1, D-06)

The `H` frame's `chan` is a client-allocated number; Emacs resolves it to `(host . id)` using the connection that created the chan (stored when `rdev--spawn` allocates it). No wire change.

## Exit semantics

Emacs sends `X <code>` after `proc/exit` and after all `O`/`E` frames for the chan have been written to the socket. Signalled children report `128 + signal` (D-07). On connection loss Emacs sends `X 255` after marking the chan `interrupted`. If the relay dies first, Emacs signals the remote process per the ownership policy.

## Backward compatibility

Relay and `rdev.el` ship together from the same directory, so version skew is limited to a stale relay process after an Emacs upgrade in-session; the `H` frame therefore stays byte-compatible, and any future extension must be a new frame type that an old peer ignores **only if** declared ignorable — today unknown types are errors, so M1 introduces no new types.
