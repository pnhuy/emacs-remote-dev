# Connections, reconnect and remote processes

## States

`DISCONNECTED → CONNECTING → BOOTSTRAPPING → INITIALIZING → CONNECTED` (TCP skips
BOOTSTRAPPING). `CONNECTED ⇄ DEGRADED`. An unexpected transport close moves
`CONNECTED`/`DEGRADED` to `RECONNECTING`; success returns to `CONNECTED`, exhausted
attempts give `FAILED`. A user disconnect goes `DISCONNECTING → DISCONNECTED` and never
reconnects. Every change runs `rdev-connection-state-hook` with `(KEY OLD NEW)`.
Illegal changes are ignored and logged (`rdev-state--strict` makes them errors in tests).

`CONNECTED` becomes `DEGRADED` when a keepalive probe (`hello`, sent every
`rdev-keepalive-interval` seconds, default 15) gets no answer within `rdev-degraded-after`
seconds (default 5). Any later answer returns it to `CONNECTED`. A probe that cannot even be
sent does not degrade the session: the transport is gone and the normal reconnect path runs.
Set `rdev-keepalive-interval` to nil to turn probing off. The mode line shows `degraded` as a
warning.

## One connection per logical host

The session key is `user@hostname:port` from `ssh -G HOST` (falls back to the alias when
ssh is unavailable). Two aliases of one machine share one connection. A second connect
while one is in flight is refused with `rdev-connection-lost` instead of racing.
Run `M-x` `rdev-state-forget-keys` after changing `~/.ssh/config`.

## Container targets

A Docker target (`:transport docker`) reuses the state machine above. Its session key is
`docker:<engine>:<container-id>`, where `<engine>` is `local` or the canonical SSH key of
`:docker-host`. The immutable container ID is part of the key, so a container recreated under the
same name is a **new session**: the old key is closed, the new one starts with empty caches, and
`*rdev-log OLD*` records `container replaced: OLD -> NEW`. A restart with the same ID keeps the
key and bumps the generation.

Every connect and reconnect re-inspects the container. A stopped, paused or removed container
fails with `not-running` or `not-found`; reconnect attempts continue with the usual backoff and
end in `FAILED` when they are exhausted.

A plain host name with no `rdev-hosts` entry is always SSH, whatever containers are running. A
container without a configured entry is reached by its explicit address `docker+NAME` (local
engine) or `docker+NAME@DH` (the engine reached over SSH at `DH`), for example
`/rdev:docker+web:/srv/app.py`. The address is parsed, not looked up: it adds nothing to
`rdev-hosts`, and a configured entry with the same key still wins. Owned processes of a lost
container are reported interrupted (exit 255) and are never replayed, exactly as for SSH. Buffers
are untouched.

Typing `/rdev:` in a file prompt completes the host over configured targets, ssh-config hosts and
running containers, which are offered as `docker+NAME` keys. Containers come from the engines of
configured Docker targets and, with `rdev-docker-auto-detect` (default t), the local engine;
containers that already have a configured key are not offered twice.

Completion never waits on Docker. Discovery is one `docker ps` per engine, cached for
`rdev-docker-discovery-ttl` (5 s) and capped at `rdev-docker-discovery-max` (200). A stale
snapshot is served at once while a background `docker ps` refreshes it, so new containers show up
on the next TAB. Only a prompt with no snapshot at all waits, at most `rdev-docker-discovery-wait`
(0.3 s). A background lookup is killed after `rdev-docker-auto-detect-timeout` (2 s), and a failed
engine is not queried again for `rdev-docker-discovery-backoff` (30 s). A failed discovery never
breaks SSH completion. `rdev-docker-list` (which waits for a fresh answer) shows name, ID and
status; `rdev-docker-connect` accepts a configured key, an address or a bare container name, which
it connects as `docker+NAME`. `rdev-status` and `rdev-list-connections` show the engine and
container for Docker targets.

In-container workflows use the same process path as SSH: `shell`, `compile`, `process-file`,
`make-process` with `:file-handler t`, Eglot, Magit and Dape. Output streams incrementally, exit
codes and signals are exact, and PTY resize is forwarded. Tools must be installed in the image;
RDEV installs no packages.

## Reconnect

Controlled by `rdev-reconnect` (t), `rdev-reconnect-base` (1 s), `-cap` (10 s),
`-max-attempts` (30), `-jitter` (±20 %). Delay for attempt *n* is
`min(cap, base·2^(n-1))` with jitter. On success the connection generation (`gen`) is
bumped, so every cached attribute from the old connection is invalid, and
`rdev-reconnected-hook` runs once with the session key.

`M-x rdev-reconnect` drops and re-establishes a connection immediately.

## What happens to work in flight

* A **pending request** fails with `rdev-connection-lost`. It is **never replayed**: whether
  a write or exec took effect is unknown, so the caller decides.
* **Remote processes** (`make-process`, `proc/spawn`, `exec/run`) owned by the lost
  connection are marked `interrupted`; the local relay gets `X 255` so Emacs sees exit
  status 255. They are never restarted on the new connection. The agent terminates their
  process groups when it sees EOF (SIGHUP, then SIGKILL after `grace_ms`).
* **Unsaved buffers** are untouched. The first save after a reconnect re-checks the file
  version (`gen` changed), so a change made meanwhile raises `rdev-conflict`.

## Logs

`*rdev-log HOST*` holds state transitions and ssh/agent stderr, trimmed to
`rdev-log-max-lines`. Values of names matching token/secret/password/passphrase/
credential/api-key/private-key/auth are replaced by `<redacted>` before being written.

## Language servers (Eglot)

Eglot works on `/rdev:HOST:/path` projects without rdev-specific code: the server is started
through `make-process` with `:file-handler t`, so it runs on the remote host behind the local
relay, URIs are mapped by Eglot from `file-local-name`, and `project.el` roots come from the
agent (`project.root`). Verified against real servers on a Linux host (E2E `eglot-python`,
`eglot-cpp`): start, completion, definition, references, rename (multi-file, saved through the
file-name handlers), diagnostics, and a clangd fix-it code action.

Behaviour worth knowing:

- **Connection loss.** The language server is a remote process owned by the old session. When the
  connection is re-established the server is reported dead (exit 255) and is never replayed.
  Unsaved edits in its buffers are kept. Start a new server (`M-x eglot`, or `eglot-reconnect`)
  on the new session (E2E `eglot-reconnect`). Eglot's *auto*reconnect after an unexpected server
  exit calls `eglot-shutdown` on a dead process and can raise an error in the process sentinel
  (reproducible with a local server in batch Emacs), so keep it off in unattended sessions.
- **Missing server.** Eglot wraps remote server commands in `sh -c "stty raw; PROG"`, so a missing
  program is not seen by rdev: Eglot reports "Server died" within the connect timeout and the
  shell's `not found` message is in the `*EGLOT … stderr*` buffer. Eglot's own pre-check
  (`eglot-alternatives`, `executable-find` with REMOTE) runs on the remote host and names the
  candidates (E2E `eglot-missing-server`). TRAMP behaves the same way.
- **Provisioning.** Servers are not installed by rdev. pylsp diagnostics and rope features need
  pyflakes/pycodestyle/rope importable on the host.

## Consult (optional)

`rdev-consult-grep` is a Consult front end over `rdev-search` (the search runs on the host).
`rdev-search.el` does not load Consult; without the package the command signals a `user-error`
that points to `rdev-grep`. The remote search itself is synchronous per input change (throttled
and debounced by Consult); quitting cancels it on the agent.
