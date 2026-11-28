# Phase 0 Research: Docker Container Remote Development

**Feature**: `002-docker-container-support` | **Date**: 2026-11-28

This research resolves the Technical Context unknowns for the plan. It is based on reading
`rdev.el`, `rdev-state.el`, `rdev-ui.el`, `rdev-server.py`, `rdev-relay.py`, the existing specs,
`docs/connections.md`, `docs/security.md`, `docs/protocol.md`, and the test layout. No runtime
behavior is claimed here beyond what the code shows; runtime checks are scheduled in the plan.

---

## R1. Transport: reuse stdio JSON-RPC over `docker exec -i`

**Decision**: A Docker target runs the existing bootstrap script through
`docker exec -i <container> sh -c '<bootstrap>'` (local engine) or
`ssh <ssh-args> <engine-host> docker exec -i <container> sh -c '<bootstrap>'` (remote engine).
The `docker exec` process's stdin/stdout carry the same JSON-RPC stream that `ssh` carries today.

**Rationale**:
- Preserves Articles I and VIII: same agent, same framing, same methods, same relay, same file
  handlers and process model.
- No new listening socket and no dependency on the container's network, satisfying Article IV and
  the spec's no-listener requirement.
- `docker exec` without `-t` gives a clean byte stream; interactive PTYs are still created by the
  agent for individual processes, as they are over SSH.
- The process lifetime is the connection lifetime, so the existing shutdown/reconnect detection
  works without changes.

**Alternatives considered**:
- **TCP into the container** (`--listen` on a published port): needs a listener, network access and
  a token; fails the spec's "no new listeners" and "no network dependency" requirements.
- **`docker attach`**: attaches to PID 1's stdio, not a new process; unsuitable for a per-session
  agent.
- **`docker cp` + `docker exec`**: still needs `docker exec` for the stream and adds a second
  non-atomic step.
- **Bake the agent into the image**: not general, requires image changes and rebuilds.

---

## R2. Addressing: extend `rdev-hosts`, keep `/rdev:HOST:/path`

**Decision**: A Docker target is an `rdev-hosts` entry whose value has `:transport 'docker`. The
alist key is the HOST used in `/rdev:HOST:/path` and in all existing commands. New plist keys:

| Key | Meaning | Default |
|---|---|---|
| `:transport` | `ssh`, `tcp`, or `docker` | `ssh` |
| `:container` | container name or ID | HOST |
| `:docker-host` | SSH destination of the engine host | nil (local engine) |
| `:docker-user` | container account for `docker exec --user` | container default |
| `:docker-program` | `docker` executable (local path, or path on the engine host) | `rdev-docker-program` (`"docker"`) |
| `:allow-root` | explicit opt-in for a root-only container | nil |

`M-x rdev-find-file`, `C-x C-f /rdev:NAME:/path`, `rdev-shell`, `rdev-reconnect`,
`rdev-disconnect`, `rdev-status` and the file-name handlers need no new syntax.

**Rationale**: Article I requires `/rdev:HOST:/path` compatibility and backward-compatible public
configuration. Reusing the host key means every existing command, hook and cache key works with a
container target. A configured key also gives a stable, human-readable name even when the container
ID changes.

**Alternatives considered**:
- **New `/rdev-docker:CONTAINER:/path` scheme**: breaks the single-convention promise, needs a
  second handler and a second completion path, and complicates `file-remote-p` and project roots.
- **`docker://` URL**: not an Emacs file-name convention and would leak into every API.
- **Container ID as the only key**: unreadable and changes on recreation.

---

## R3. Identity and session keys: engine + immutable container ID

**Decision**: The logical session key is `docker:<engine>:<container-id>`.

- `<engine>` is `local` for the local engine, or the canonical `rdev-state-session-key` of
  `:docker-host` (for example `user@host:22`) for a remote engine.
- `<container-id>` is the full ID from `docker inspect --format '{{.Id}}'`, not the name.
- `rdev--conns` remains keyed by the user-facing HOST; `rdev--key-hosts` maps the session key back
  to that HOST for reconnect.

On every connect and reconnect the client resolves the configured container name to its current
ID. If the ID differs from the previous session, the client:
1. transitions the old key to `disconnected` (or leaves `failed` when it never recovered),
2. starts the new session under the new key with a bumped connection generation,
3. logs `container replaced: old-id → new-id`,
4. leaves existing buffers untouched and never replays pending work.

**Rationale**: The spec requires a recreated same-name container to be a new session, and caches
must not leak across container instances. Keying by name alone would let a new container inherit
stale attributes and state. Keying by ID alone would make completion and reconnect ambiguous.

**Alternatives considered**:
- **Name only**: stale cache and state after `docker run --name` replacement.
- **ID only**: no stable user-facing target and no way to reconnect by name.
- **Engine-agnostic key**: local and remote same-named containers would collide.

---

## R4. Bootstrap and helper installation

**Decision**: Reuse `rdev--bootstrap-template` and `rdev-server.py` unchanged in content. The
bootstrap runs as the `docker exec` user with `umask 077`, installs to
`${HOME:-/tmp}/.cache/rdev/rdev-server-<hash>.py` (or `/tmp/rdev-<uid>/...` when `HOME` is unset or
unwritable), verifies exact size and SHA-256, and renames atomically. If `sh` or Python ≥ 3.8 is
missing, the existing `RDEV-ERR` path reports it; the client maps it to a Docker "unsupported
environment" error with a remedy.

**Rationale**: The bootstrap is already the tested, atomic, integrity-checked path for SSH. Reusing
it means one deployment mechanism, one set of markers and one failure vocabulary. The fallback is
needed because `docker exec --user` with a numeric UID may not have a passwd entry or a writable
home.

**Alternatives considered**:
- **`docker cp` the agent**: extra step, not atomic with the stream, and needs cleanup on failure.
- **Mount a host directory**: requires the container to be created with the mount, which is not
  general and changes the container's configuration.
- **Install Python or `sh`**: violates "no package installation" and the least-privilege rule.

---

## R5. Root policy: refuse by default, explicit per-target opt-in

**Decision**:
- The client checks the effective UID inside the container before installing the helper
  (`id -u` in the bootstrap, or `docker inspect` `Config.User` as a pre-check).
- If the UID is 0 and `:allow-root` is nil, the client aborts before installing, with a message
  that names the container, the root condition, and the remedies: use an existing unprivileged
  account, set `:docker-user`, or set `:allow-root` deliberately.
- If `:allow-root` is non-nil, the client passes the agent's new `--allow-root` flag, shows a
  warning on every connection, and writes a log line that the helper runs with container-root
  privileges.
- The agent's default remains an unconditional refusal for uid 0; `--allow-root` is the only
  override and is accepted only from the bootstrap command line, never from RPC.

**Rationale**: The spec's clarification selected this policy, and the constitution permits a
documented exception with rationale, risk and remediation. Keeping the default refusal preserves
Article IV for every existing user and for containers that do have an unprivileged account.

**Alternatives considered**:
- **Unconditional refusal**: simplest and safest, but the spec explicitly requires root-only
  containers to be usable through an opt-in.
- **Automatic `--user` to a guessed account**: guessing a UID/name is unsafe and often wrong.
- **Root by default**: unacceptable.

**Constitution exception**: recorded in `plan.md` (Complexity Tracking) and `spec.md` (Documented
Security Exception). The agent flag is an additive CLI change, not a protocol change.

---

## R6. Remote engine over SSH

**Decision**: When `:docker-host` is set, the transport process is:

```text
ssh <rdev-ssh-args> -- <docker-host> docker exec -i <validated-container> sh -c '<quoted bootstrap>'
```

The `docker` command runs on the engine host, not locally. `:docker-program` may be an absolute
path there. The engine identity uses `rdev-state-session-key` on `:docker-host`, so existing SSH
aliases, keys, agents, `ProxyJump` and host-key checking apply unchanged.

**Rationale**: Reuses the developer's SSH configuration and authentication (Article IV) and keeps
the remote path a single stdio stream. It also means the remote engine can be on a host that is not
otherwise reachable from the client.

**Alternatives considered**:
- **Docker context / `DOCKER_HOST`**: would require configuring and trusting a separate transport,
  often TCP/TLS, and would bypass the existing SSH configuration.
- **A local port-forward to the remote Docker socket**: exposes a powerful socket and adds a
  listener; rejected on security grounds.

**Quoting**: container names are validated against `[A-Za-z0-9][A-Za-z0-9_.-]*` (or a hex ID), the
bootstrap is passed as one `shell-quote-argument` payload, and `--` separates options from the
destination. No user-controlled string is interpolated into an unquoted shell command.

---

## R7. Discovery and completion

**Decision**: Add `rdev-docker-connect` (interactive) and `rdev-docker-list`. Completion of a
target consults:
1. configured `rdev-hosts` keys with `:transport 'docker` (no subprocess),
2. a short-lived cache of `docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}'`
   (local) or the same command over `:docker-host`.

The cache TTL is a new `rdev-docker-discovery-ttl` (default 5 s). Output is bounded (a maximum
number of entries and bytes), the call has a timeout, and a failure to list containers does not
break SSH completion.

**Rationale**: One `docker ps` is enough for 50 containers and is far below the 3 s success
criterion. A cache avoids repeated calls during a single completion session. Configured targets
work even when the engine is temporarily unreachable.

**Revision (2026-11-28)**: completion no longer runs `docker ps` synchronously. A blocking lookup
in the host prompt cost up to its timeout per engine on every TAB when the daemon was slow or
down. Completion now serves the cached snapshot (stale-while-revalidate) and refreshes it with an
asynchronous `docker ps`. There is one lookup in flight per engine, it is killed after
`rdev-docker-auto-detect-timeout`, and a failed engine is not retried for
`rdev-docker-discovery-backoff`. Only a prompt with no snapshot waits, at most
`rdev-docker-discovery-wait` (0.3 s). Engines are de-duplicated, so several targets on one engine
cost one `docker ps`. Explicit commands (`rdev-docker-list`, connect) keep the blocking query.

Unconfigured containers are offered, and addressed, as explicit `docker+NAME[@DH]` keys. An
earlier iteration resolved any unconfigured bare host name to a same-named running container
after an ssh-config check. That was rejected because it let a container silently capture an SSH
host that is not in the ssh configuration (for example a bare DNS name), it ran `docker ps` on
the connect path of every unconfigured SSH host, and it contradicted FR-003 (opt-in). The address
form keeps "open a container without configuring it" while making the choice of Docker explicit
in the name itself.

**Alternatives considered**:
- **Always call `docker ps` on every completion**: correct but needlessly slow and fails noisily
  when the engine is down.
- **Watch the Docker events stream**: a long-lived process and extra failure surface for little
  benefit at this scale.

---

## R8. Error taxonomy

**Decision**: Add `rdev-docker-error` as a child of the existing `rdev-transport-error`, with a
stable `reason` in the error data:

| Reason | Meaning |
|---|---|
| `not-found` | no container with that name/ID on the engine |
| `not-running` | container exists but is stopped/paused |
| `permission` | the account cannot use the Docker engine or the container |
| `engine-unreachable` | the Docker CLI/daemon or the SSH host is unavailable |
| `unsupported` | no `sh`, no Python ≥ 3.8, or an unusable home |
| `root-refused` | container runs as root and the opt-in is off |
| `bootstrap` | install/verification failed |

SSH failures on a remote engine remain `rdev-ssh-error`; agent and filesystem failures keep their
existing classes. `rdev-status`, `rdev-list-connections` and `*rdev-log HOST*` show the reason.

**Rationale**: Article X requires distinguishable failures. A single class with reasons keeps
`condition-case` handlers simple while preserving actionable messages. Inheriting from
`rdev-transport-error` means existing handlers still catch Docker failures.

**Alternatives considered**:
- **One symbol per reason**: more precise but multiplies public symbols and handler branches.
- **Reuse `rdev-agent-error`**: loses the distinction between Docker and agent failures.

---

## R9. Lifecycle, reconnect and cache invalidation

**Decision**: Reuse the existing state machine and reconnect/backoff. On transport close,
`rdev--on-shutdown` marks owned processes interrupted (exit 255) and starts reconnect as today. A
reconnect re-resolves the container by name:
- same ID → same session key, generation bump as today, caches invalidated;
- different ID → new session key, old key closed, new connection with empty cache, replacement log;
- container missing/stopped → reconnect attempts fail; state reaches `failed` after the configured
  attempts; buffers remain untouched.

**Rationale**: The existing machine already satisfies the spec's stop/restart/removal and no-replay
requirements. Re-resolution is the only container-specific addition.

**Alternatives considered**:
- **Keep the old `docker exec` alive across a container restart**: impossible; the process dies
  with the container.
- **Auto-start the container**: out of scope per the spec.

---

## R10. Process, environment and PTY behavior

**Decision**: No change to the relay or `proc/*` methods. `docker exec` is run without `-t`; the
agent creates a PTY per `proc/spawn` as it does over SSH. The agent's environment is the container
environment for the `docker exec` user; `rdev--env` continues to forward only local changes and
excludes `HOME`, `USER`, `SHELL`, `PATH`, `SSH_*` and the other existing exclusions.

**Rationale**: This preserves exact output, exit codes, signals, resize and flow control, which the
spec requires. A `-t` on `docker exec` would corrupt the JSON-RPC stream.

**Alternatives considered**:
- **`docker exec -t` for the session**: mixes terminal control with protocol bytes.
- **Forwarding the full local environment**: can override container variables and leak host paths.

---

## R11. Configuration and compatibility

**Decision**: Add Docker keys to `rdev-hosts` (a `defcustom` plist type) and new `defcustom`s:
`rdev-docker-program` (default `"docker"`), `rdev-docker-discovery-ttl` (default 5),
`rdev-docker-discovery-max` (default 200), and `rdev-docker-timeout` (default `rdev-timeout`).
Existing entries without `:transport` remain SSH. No existing symbol is renamed or removed. New
commands are additive; existing commands keep their signatures.

**Rationale**: Article I and Article X require backward-compatible public configuration and
discoverable options.

**Alternatives considered**:
- **A separate `rdev-docker-hosts` alist**: splits completion, status and reconnect logic and
  duplicates the host-key namespace.
- **Reusing `:ssh-host` for the engine**: conflates two destinations and breaks the existing
  meaning of `:ssh-host`.

---

## R12. Testing strategy

**Decision**:
- **ERT unit tests** (`test/rdev-docker-test.el`) drive a fake `docker` executable
  (`test/fixtures/fake-docker`) that returns canned `inspect`/`ps` JSON and runs `exec` commands
  locally. They cover command construction, quoting, parsing, discovery cache, error mapping, root
  refusal/opt-in, session keys, replacement and reconnect.
- **Python tests** extend `test/py/test_root_refusal.py` to assert the default refusal and the
  `--allow-root` path with `os.geteuid` monkeypatched.
- **E2E** (`test/e2e/docker.el`, `test/e2e/docker-fixture.sh`) runs against a real local Docker
  engine: edit/save/conflict, interrupted save, process/PTY, compile navigation, discovery,
  stop/restart, root refusal and opt-in. The fixture uses `RDEV_TEST_DOCKER_IMAGE` (default
  `python:3.11-slim`) and creates an unprivileged user; a second root-only fixture exercises the
  opt-in. The remote-engine path uses the existing disposable `sshd` fixture as the engine host
  (the same machine's Docker engine over SSH).
- **Gates**: `make check` and `make e2e S=docker`; the full existing suite is a regression gate.

**Rationale**: A fake CLI makes unit tests deterministic and independent of a daemon, while real
Docker is the only way to prove `exec`, PTY, signals and lifecycle behavior. The fixture image is
documented as a prerequisite so a missing image is reported, not silently skipped.

**Alternatives considered**:
- **Only mocks**: would not prove `docker exec` semantics.
- **Only E2E**: slow, environment-dependent, and hard to cover error branches.

---

## R13. Performance and blocking

**Decision**: Keep one persistent `docker exec` per target. First connect performs at most one
`docker inspect` plus the bootstrap `docker exec`; steady-state file/process operations are
unchanged. Discovery is one `docker ps` with a short cache. The Emacs-side blocking profile is the
same as SSH: the first interactive connect and discovery block briefly; file handlers and
`process-file` block per RPC as documented; `make-process`/compile/shell/Eglot are asynchronous.

**Rationale**: Article V asks for measured, bounded behavior, and the spec's SC-005 bounds
discovery. No new per-operation round trip is introduced.

**Alternatives considered**:
- **A background discovery timer**: more moving parts and stale data. Discovery is refreshed in
  the background only on demand, when completion finds the snapshot stale (see the R7 revision);
  there is no periodic timer.
- **Caching inspect results indefinitely**: stale after a container restart; re-resolve on connect.

---

## R14. Documentation and migration

**Decision**: Update `docs/connections.md` (container targets, lifecycle, reconnect),
`docs/security.md` (root opt-in, trust boundary, no new listeners), `docs/README.md` and
`README.md` (configuration and commands), and `docs/DEVELOPING.md` (fixtures and test commands).
Add the agent flag and the `rdev-hosts` keys to the contracts. Record the root exception in
`test/INTENTIONAL-CHANGES.md` with the justification and the tests that cover it.

**Rationale**: Articles I, IX, X and XII require documented public interfaces, protocol/CLI
changes, security behavior and verification limits.

**Alternatives considered**: none; undocumented configuration would violate the constitution.

---

## Open items carried into implementation

1. Confirm `docker exec` behavior for a numeric `--user` with no passwd entry and no `HOME`
   (fallback path) on the fixture images.
2. Confirm signal delivery and PTY resize through the agent when the container's `docker exec`
   process is the only host-side process.
3. Confirm discovery latency with 50 containers on the development machine; record the number.
4. Record which environments were actually exercised (Docker Desktop, rootless Docker, a real
   second engine host) in the milestone report; do not claim untested compatibility.
