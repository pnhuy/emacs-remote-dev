# Contract: Docker Target

**Feature**: `002-docker-container-support` | **Version**: 1.0 | **Date**: 2026-11-28

This is the user- and integration-facing contract for using a Docker container as an RDEV target.
It is additive to the existing SSH/TCP contract in `docs/connections.md` and
`specs/001-rdev-modernization/contracts/`.

---

## 1. Configuration

A Docker target is an entry in `rdev-hosts`:

```elisp
(setq rdev-hosts
      '(("NAME" . (:transport docker
                   :container "CONTAINER"
                   :docker-host "SSH-DEST"
                   :docker-user "USER"
                   :docker-program "PATH"
                   :allow-root t))))
```

| Key | Required | Default | Contract |
|---|---|---|---|
| `:transport` | yes | `ssh` | Must be the symbol `docker`. |
| `:container` | no | the entry's NAME | Docker name or ID. Names match `[A-Za-z0-9][A-Za-z0-9_.-]*`; IDs are 12–64 hex characters. |
| `:docker-host` | no | nil (local engine) | An SSH destination accepted by `ssh`; uses the developer's existing SSH configuration. |
| `:docker-user` | no | container default | Account for `docker exec --user`; a name or numeric UID. Must not start with `-`. |
| `:docker-program` | no | `rdev-docker-program` (`"docker"`) | Executable on the engine host; non-empty, no NUL. |
| `:allow-root` | no | nil | Explicit opt-in for a container whose only account is root. Off by default. The global `rdev-docker-allow-root` is the default for targets without it; an explicit `:allow-root nil` opts a target out. |

New customization variables:

| Variable | Default | Contract |
|---|---|---|
| `rdev-docker-program` | `"docker"` | Default Docker executable. |
| `rdev-docker-discovery-ttl` | `5` | Seconds a discovery snapshot stays fresh. |
| `rdev-docker-discovery-max` | `200` | Maximum containers listed for completion. |
| `rdev-docker-auto-detect` | t | List running containers on the local engine in host completion (as `docker+NAME`). Never resolves a plain host name to a container. |
| `rdev-docker-auto-detect-timeout` | `2` | Seconds before a background discovery `docker ps` is killed. |
| `rdev-docker-discovery-wait` | `0.3` | Longest wait in a prompt that has no discovery snapshot yet. |
| `rdev-docker-discovery-backoff` | `30` | Seconds before a failed engine is queried again by completion. |
| `rdev-docker-timeout` | `rdev-timeout` | Timeout for inspect/ps/exec bootstrap steps. |
| `rdev-docker-allow-root` | nil | Global root opt-in for Docker targets without `:allow-root`. Off by default; every root connection warns and logs. |

Existing `rdev-hosts` entries without `:transport` keep their current meaning.

---

## 2. Addressing and commands

- The path syntax is unchanged: `/rdev:NAME:/absolute/path`.
- `M-x rdev-find-file`, `C-x C-f`, Dired, `project.el`, `compile`, `shell`, `rdev-shell`,
  `rdev-reconnect`, `rdev-disconnect`, `rdev-status` and `rdev-clear-cache` accept a Docker target
  wherever they accept an SSH host.
- New commands:
  - `M-x rdev-docker-connect` — choose a running container and connect.
  - `M-x rdev-docker-list` — list running containers on the configured engine(s).
- Completion offers configured Docker targets first, then a fresh discovery snapshot. A discovery
  failure must not prevent SSH completion or configured-target completion.

**Target precedence**: An entry key in `rdev-hosts` is unique and identifies exactly one target.
When a configured key has the same name as an `~/.ssh/config` alias, the configured entry wins for
every command, for file-name dispatch and for `file-remote-p`; to reach both, use distinct keys.
Discovery listings are informational only and never override a configured key.

For a name with no `rdev-hosts` entry:

1. a name matching `docker+NAME` or `docker+NAME@DH`, where NAME is a valid container name, is
   the container NAME on the local engine, or on the engine reached over SSH at DH. The address
   is parsed, never looked up, and `rdev-hosts` is not changed;
2. any other name is SSH. A running container never captures a plain host name.

`rdev-docker-connect` accepts a configured Docker key, an address, or a bare container name,
which it connects as `docker+NAME`.

`rdev-docker-auto-detect` (default t) controls whether host completion also lists containers
on the local engine; the engines of configured Docker targets are always listed.

---

## 3. Discovery

The engine is queried with one command equivalent to:

```text
docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}'
```

- For a remote engine, the same command runs on `:docker-host` over SSH.
- Output is bounded to `rdev-docker-discovery-max` entries and a byte limit; truncation is
  reported.
- A snapshot is cached for `rdev-docker-discovery-ttl` and is used for display/completion only.
- Completion never blocks on the engine. It serves the cached snapshot, even a stale one, and
  starts at most one asynchronous `docker ps` per engine to refresh it. That lookup is killed after
  `rdev-docker-auto-detect-timeout` (2 s), and a failed engine is not retried for
  `rdev-docker-discovery-backoff` (30 s). Only a prompt with no snapshot waits, at most
  `rdev-docker-discovery-wait` (0.3 s). Several targets on one engine share one lookup.
- Completion offers running containers as `docker+NAME` (local) or `docker+NAME@DH` keys, except
  containers that a configured target already names.
- `rdev-docker-list` and `rdev-docker-connect` query synchronously, bounded by
  `rdev-docker-timeout`.
- Every connection re-inspects the target; a snapshot never authorizes a connection.
- Errors are reported as `rdev-docker-error` with reason `engine-unreachable` or `permission`, and
  do not abort the current command.

---

## 4. Errors

All Docker failures signal `rdev-docker-error`, a child of `rdev-transport-error`, with a
`reason`:

| Reason | When | Message must include |
|---|---|---|
| `not-found` | no container with the configured name/ID | target name, engine |
| `not-running` | state is not `running`, or is `paused` | target name, state |
| `permission` | Docker CLI/daemon or container access denied | target, account, remedy |
| `engine-unreachable` | Docker CLI/daemon missing, or SSH host unreachable | engine, command, remedy |
| `unsupported` | no `sh`, no Python ≥ 3.8, or unusable home | missing prerequisite, remedy |
| `root-refused` | effective UID 0 and the opt-in (`:allow-root` or `rdev-docker-allow-root`) is off | container, root condition, the three remedies |
| `bootstrap` | install, size/hash verification, or upload failed | container, stage, remedy |

Rules:
- SSH failures for a remote engine remain `rdev-ssh-error`; agent and filesystem failures keep
  their existing classes.
- Messages must not contain credentials, tokens or sensitive environment values.
- `rdev-status`, `rdev-list-connections` and `*rdev-log NAME*` show the reason. When the container
  cannot be inspected (removed, engine down), the target keeps its previous session key; a target
  that never resolved records the failure under `docker:<engine>:unresolved/<container>`, which
  the next successful connect replaces. Looking up a key never signals.
- Messages name the container, the engine (`the local engine` or `the engine on DH`), the account
  for `permission`, and a remedy.
- A failed connection must leave no partial helper file and must not alter the container.

---

## 5. Lifecycle

- **Connect**: resolve the target, verify it is running, apply the root policy, bootstrap, then
  `hello`. The UID probe and the transport `docker exec` the inspected container ID, not the name.
  The state machine is the existing one.
- **Stop**: the transport closes; state becomes `reconnecting`; owned processes are reported
  interrupted (exit 255) and are never replayed; buffers are untouched.
- **Restart (same ID)**: reconnect succeeds under the same session key with a new generation.
- **Recreate (new ID)**: the old session is closed, a new session key starts, caches are empty, and
  a replacement is logged.
- **Remove**: reconnect attempts fail; state reaches `failed`; buffers remain.
- **Disconnect / Emacs exit**: the container and its services keep running; only RDEV's own helper
  and owned processes are affected.

---

## 6. Compatibility and security guarantees

- `/rdev:HOST:/path`, JSON-RPC 2.0, `Content-Length` framing, the relay, public commands and
  existing customization remain compatible.
- No new listening socket; the container needs no network access or published port.
- No Docker/registry credentials are stored; the developer's existing Docker and SSH permissions
  apply.
- Commands are passed as argv; container names are validated; the remote `sh -c` payload is quoted
  and `--` separates options from the destination.
- The helper runs as an unprivileged account by default and refuses root unless the per-target
  or global opt-in is set; the opt-in warns on every connect and is logged.
- Existing SSH and TCP behavior is unchanged.

---

## 7. Acceptance mapping

| Spec requirement | Contract section |
|---|---|
| FR-001, FR-002, FR-003 | §1, §2, §6 |
| FR-004, FR-005 | §1, §3, §4 |
| FR-006, FR-008 | §4, §5; `bootstrap.md` |
| FR-007 | §1, §6; `bootstrap.md` §4 |
| FR-009, FR-010, FR-011 | §5, §6 |
| FR-012, FR-013 | §3, §5 |
| FR-014, FR-015 | §1, §2 |
| FR-016, FR-017, FR-018 | §1, §4, §6 |
| FR-019, FR-020 | §2, §5 |
