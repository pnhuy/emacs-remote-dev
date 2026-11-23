# Contract: Emacs-facing API

## Namespace

`/rdev:HOST:/absolute/path` and `/rdev:HOST:~/…` (home expansion as today). `HOST` is anything `ssh` accepts as a destination except a leading `-`; `user@host`, aliases and `host#port` forms keep working as today. `rdev--regexp` is unchanged; invalid hosts are rejected at connect time with `user-error` "rdev: invalid host name".

## Commands

| Command | Status | Behaviour |
|---|---|---|
| `rdev-find-file` | existing | unchanged |
| `rdev-shell` | existing | unchanged |
| `rdev-disconnect` | existing | → `DISCONNECTING`; owned processes terminated per policy |
| `rdev-clear-cache` | existing | unchanged; with prefix arg clears one host |
| `rdev-status` | existing | same output; adds state column |
| `rdev-connect` | new (M2) | connect without opening a file |
| `rdev-list-connections` | new (M2) | `tabulated-list-mode`: Host, State, Latency, Procs, Cache, Agent, Protocol; keys `c` connect, `r` reconnect, `k` disconnect, `R` restart server, `l` logs, `g` refresh |
| `rdev-reconnect` | new (M2) | |
| `rdev-restart-server` | new (M2) | `session/shutdown` then reconnect (re-bootstraps) |
| `rdev-show-logs` | new (M2) | pops `*rdev-log HOST*` |

## Customization (existing kept, new additive)

Existing: `rdev-hosts`, `rdev-ssh-args`, `rdev-python`, `rdev-cache-ttl`, `rdev-timeout`, `rdev-env-exclude`.
New (all with defaults preserving current behaviour): `rdev-cache-max-entries` (5000), `rdev-reconnect` (t), `rdev-reconnect-base`/`-cap`/`-max-attempts` (1/30/8), `rdev-process-policy` (`terminate`), `rdev-allow-insecure-tcp` (nil), `rdev-chunk-size` (1 MiB), `rdev-large-file-threshold` (8 MiB), `rdev-project-markers`, `rdev-search-engine` (`auto`), `rdev-log-max-lines`.

## Errors

| Condition | Signal |
|---|---|
| missing file / ENOENT | `file-missing` (as today) |
| EACCES | `permission-denied` (as today; predicates return nil) |
| version conflict | `rdev-conflict` ⊂ `file-error` (new) |
| connection lost mid-request | `rdev-connection-lost` ⊂ `file-error` (new); never retried automatically |
| unsupported op | `file-error` with "rdev: <op> not supported" — never a silent success |
| timeout | `file-error` "rdev: timeout" (existing wording) |

## Hooks

`rdev-connection-state-hook` (args: conn old new). `rdev-conflict-functions` (abnormal hook to customize resolution UI; default offers refresh/compare/overwrite).

## Handler guarantees (checked by the baseline suite)

For each of the 53 `rdev-defop` operations a test compares result and error shape with native Emacs on an identical local twin directory, except where listed in the "documented differences" section of the baseline test file (e.g. ACL/SELinux stubs, lock files are no-ops). Operations not in the handler table fall through to the real function and are not claimed.

## Save semantics (summary)

1. Visiting a file stores its FileVersion.
2. `write-region` (whole file, not append) uses `fs/writeAtomic` when the capability is present, else legacy `fs/write` (with a one-time message that saves are not atomic against this agent).
3. Append uses `fs/write append=true` always (explicitly non-atomic).
4. Conflict ⇒ `rdev-conflict`, save aborted, buffer unmodified-state preserved.
5. Large files (> threshold, capability present) use the chunk family and bounded memory.
