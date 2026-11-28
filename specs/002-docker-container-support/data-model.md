# Phase 1 Data Model: Docker Container Remote Development

**Feature**: `002-docker-container-support` | **Date**: 2026-11-28

This model describes the entities the feature adds or extends. It does not prescribe code
structure; `plan.md` and `research.md` cover the implementation. Field names are conceptual.

---

## 1. Container Engine

The Docker engine that hosts a target.

| Field | Type | Rules |
|---|---|---|
| `kind` | `local` \| `ssh` | Derived from `:docker-host` (absent = local). |
| `ssh_destination` | string or nil | Required when `kind = ssh`; validated with the existing SSH destination rules. |
| `canonical_identity` | string | `local`, or the canonical `user@host:port` from `rdev-state-session-key` of the SSH destination. |
| `docker_program` | string | `:docker-program` or `rdev-docker-program`; non-empty, no NUL; a path on the engine host when `kind = ssh`. |
| `reachable` | boolean | Result of the last inspection; never cached across a connect. |

**Relationships**: one engine has zero or more container targets.

**Validation**:
- A remote engine destination must pass the existing host validation (no leading `-`, no unusual
  characters) before any SSH command runs.
- The engine identity is used verbatim in the session key and must not collide with an SSH
  session key (`user@host:port`).

---

## 2. Container Target

A running container the developer attaches to, as configured and as resolved.

### 2.1 Configured form (`rdev-hosts` entry)

| Field | Type | Rules |
|---|---|---|
| `host_key` | string | The alist key and the HOST in `/rdev:HOST:/path`; non-empty, no `:`, `/` or `|`, not starting `-`. |
| `transport` | `docker` | Selects this model. |
| `container` | string | Docker name or ID; defaults to `host_key`; validated against the Docker name/ID charset. |
| `docker_host` | string or nil | SSH destination of the engine; nil = local. |
| `docker_user` | string or nil | Account for `docker exec --user`; name or numeric UID; nil = container default. |
| `docker_program` | string or nil | Overrides `rdev-docker-program`. |
| `allow_root` | boolean | Explicit opt-in for a root-only container; default nil. |

### 2.2 Resolved form

| Field | Type | Rules |
|---|---|---|
| `container_id` | string | Full ID from inspection; immutable for the life of the container. |
| `name` | string | The container's primary name, without the leading `/`. |
| `image` | string | Image reference reported by inspection; display only. |
| `state` | `running` \| `paused` \| `exited` \| `created` \| `restarting` \| `removing` \| `dead` | From inspection. Only `running` is connectable. |
| `default_user` | string | `Config.User` or the image default; display and policy input. |
| `effective_uid` | integer | UID the helper would run as; from the bootstrap probe or inspection. |
| `session_key` | string | `docker:<engine.canonical_identity>:<container_id>`. |

**Relationships**: a target belongs to one engine and has at most one live connection.

**Validation**:
- The target must exist on the engine before any install.
- The target must be `running` and not `paused` before any `docker exec`.
- A configured `docker_user` must be non-empty and must not start with `-`.
- `allow_root` is the only way to proceed when `effective_uid = 0`.

---

## 3. Root Policy Decision

Evaluated before installing the helper, on every connect and reconnect.

| Container account | `allow_root` | Outcome |
|---|---|---|
| Non-root UID | either | Connect normally; helper runs as that account. |
| Root UID (0) | nil | Refuse with `root-refused`; name the container and the remedies (use an unprivileged account, set `:docker-user`, or opt in). No install, no partial file. |
| Root UID (0) | non-nil | Connect with the agent's `--allow-root`; show a warning on every connection; log the elevated privilege. |
| Unknown / probe failed | either | Refuse with `unsupported`; do not guess. |

**Invariants**:
- The default is always refusal; the opt-in is per target and never inherited from another target.
- The opt-in does not change any other security control (no new listener, no credential storage).
- The warning is emitted on every connect, not only the first.

---

## 4. Container Connection

Extends the existing `rdev-conn` session.

| Field | Type | Notes |
|---|---|---|
| `host` | string | The user-facing `host_key`. |
| `rpc` | jsonrpc connection | The existing stdio connection. |
| `home`, `path` | string, list | From the agent `hello`, as today. |
| `cache` | hash table | Existing attribute cache; keyed with the connection generation. |
| `state` | connection state | Existing state machine. |
| `gen` | integer | Bumped on every successful (re)connect; invalidates caches. |
| `transport` | `docker` | New value alongside `ssh` and `tcp`. |
| `engine` | Container Engine | Identity used in the session key. |
| `container_id` | string | Immutable ID for this connection. |
| `root_mode` | boolean | True only when `allow_root` was used. |
| `helper` | Helper Installation | The verified helper for this connection. |
| `log`, `stats`, `procs`, `policy` | existing | Unchanged. |

**Relationships**: one connection belongs to one target; one target has at most one live
connection; aliases that resolve to the same session key share a connection, as SSH aliases do.

**Invariants**:
- Two `host_key`s with the same engine and container ID share one session key and one connection.
- A connection's cache is valid only for its `gen`; a replacement always starts empty.
- Pending requests are never replayed; owned processes are marked interrupted on loss.

---

## 5. Helper Installation

The in-container agent copy.

| Field | Type | Rules |
|---|---|---|
| `path` | string | `$HOME/.cache/rdev/rdev-server-<hash>.py`, or the documented `/tmp` fallback; owner-only directory and file. |
| `sha256` | string | Must match the client's script. |
| `size` | integer | Must match exactly. |
| `owner_uid` | integer | The `docker exec` user. |
| `version` | string | From the agent `hello`; incompatible majors are rejected. |
| `root_mode` | boolean | Mirrors the connection. |

**Invariants**:
- Install is atomic: write a temporary file, verify, rename; remove the temporary file on any
  failure.
- A partial or corrupt install is never executed.
- No package is installed; a missing `sh`, Python ≥ 3.8, or writable location is an `unsupported`
  error with a remedy.

---

## 6. Discovery Snapshot

A short-lived list of running containers for completion and the list command.

| Field | Type | Rules |
|---|---|---|
| `engine` | Container Engine | The snapshot is per engine. |
| `fetched_at` | timestamp | Used with the TTL. |
| `entries` | list of `{name, id, image, status}` | At most `rdev-docker-discovery-max`; bounded bytes. |
| `truncated` | boolean | True when the bound was hit. |
| `error` | reason or nil | A failed refresh keeps the previous snapshot and reports the reason. |

**Invariants**:
- A snapshot is for display/completion only; it never authorizes a connection. The target is
  re-inspected before connecting.
- An expired snapshot triggers at most one refresh.
- Discovery failure never blocks SSH completion.

---

## 7. State Transitions

The existing machine is reused. Container-specific causes are shown in parentheses.

| From | To | Cause |
|---|---|---|
| `disconnected` | `connecting` | User connect, reconnect, or replacement of a recreated container. |
| `connecting` | `bootstrapping` | Target exists, is running, and the root policy allows the helper. |
| `connecting` | `failed` | Not found, not running/paused, permission, engine unreachable, root refused, unsupported environment. |
| `bootstrapping` | `initializing` | `RDEV-READY` received. |
| `bootstrapping` | `failed` | Bootstrap/verification error or helper upload failure. |
| `initializing` | `connected` | Protocol `hello` succeeds. |
| `initializing` | `failed` | Incompatible protocol or `hello` failure. |
| `connected` | `degraded` | Keepalive unanswered within `rdev-degraded-after`. |
| `degraded` | `connected` | Keepalive answered. |
| `connected` / `degraded` | `reconnecting` | Transport closed unexpectedly (container stopped/removed, engine lost, SSH lost). |
| `reconnecting` | `connecting` | Next attempt starts; the container is re-resolved. |
| `reconnecting` | `failed` | Attempts exhausted or the target is permanently gone. |
| `failed` | `connecting` | User retries or the container returns. |
| any | `disconnecting` → `disconnected` | User disconnect. |

**Replacement rule**: when a reconnect resolves a different container ID for the same
`host_key`, the old session key moves to `disconnected`, a new session key starts at `connecting`,
the generation is bumped, caches are empty, and a `container replaced` line is logged. Buffers are
untouched; non-idempotent operations are not replayed.

**Stop rule**: a stopped container closes the transport; the connection moves to `reconnecting`.
If the container remains stopped, attempts exhaust to `failed`. A restart with the same ID resumes
the same session key; a removal/recreation produces a new ID and the replacement rule applies.

---

## 8. Configuration Examples

```elisp
(setq rdev-hosts
      '(("api" . (:transport docker
                  :container "my-api"
                  :docker-user "dev"))
        ("build" . (:transport docker
                    :container "ci-runner"
                    :allow-root t))
        ("remote-api" . (:transport docker
                         :container "my-api"
                         :docker-host "dev-server"))))
```

The path syntax is unchanged: `/rdev:api:/workspace/app.py`.
