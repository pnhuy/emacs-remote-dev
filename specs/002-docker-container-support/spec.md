# Feature Specification: Docker Container Remote Development

**Feature Branch**: `002-docker-container-support`

**Created**: 2026-11-28

**Status**: Draft

**Input**: User description: "rdev is working with ssh remote, extend this to make it work with running docker container"

## Scope & Delivery Model

This is an extension of the existing, working RDEV package, not a new product. Today a developer
reaches a remote machine over SSH and edits its files as `/rdev:HOST:/path`. This feature makes a
running Docker container an additional kind of remote target, so the same editing, project,
search, process and debugging workflows work inside the container.

The change is additive and opt-in. Existing SSH and TCP behavior, commands, configuration and the
`/rdev:HOST:/path` convention are preserved. Work is delivered in three ordered, independently
shippable increments:

1. **Local container editing (P1)** — connect to a running container on the local Docker engine
   and edit files with the existing safety guarantees.
2. **In-container workflows and visibility (P2)** — run builds, shells, searches and language
   tools inside the container; discover, list, monitor and reconnect container targets.
3. **Containers on a remote engine (P3)** — reach a Docker engine on a machine that is itself
   accessed over SSH, with container identity kept distinct from local containers.

All three increments are in scope for this feature (see Clarifications for the scope decisions);
their order reflects dependency and delivery sequence, not optionality.

Container lifecycle management (creating, starting, stopping, building or removing containers and
images) is out of scope. RDEV attaches to containers that are already running.

## Clarifications

### Session 2026-11-28

- Q: When only a root account exists inside the container, what should RDEV do? → A: Refuse by
  default with guidance, but allow an explicit opt-in (per target or a global default). The opt-in
  is documented as a constitution exception, warns on every connection, is recorded in the log,
  and is covered by security tests.
- Q: Is support for containers on a remote Docker engine in scope? → A: Yes, it is required in this
  feature; local and remote engines must both ship.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Edit files inside a running local container (Priority: P1)

A developer has a service running in a Docker container on their machine. Without leaving Emacs
they target that container by name, open a file from its filesystem, edit it and save it. They do
not install anything inside the container by hand, and they do not need to know the container's
ID, mount points or network address.

**Why this priority**: Reading and writing files is the minimum viable value and the foundation
every other workflow depends on. It must be delivered and be trustworthy before processes,
discovery or remote engines matter.

**Independent Test**: Start a container from an image with a small project and no RDEV helper
inside. From a clean Emacs session, open, edit, create, rename and delete files under the
container's working directory using ordinary Emacs commands. Verify contents, permissions and
symlinks. Interrupt a save and modify a file externally between open and save.

**Acceptance Scenarios**:

1. **Given** a running container with no RDEV helper installed, **When** the developer targets the
   container and opens a file, **Then** the helper is installed and verified inside the container
   automatically and the file opens in a normal Emacs buffer.
2. **Given** an open container file, **When** the developer saves, **Then** the write is atomic and
   the file contains either the complete old or complete new content, never partial content.
3. **Given** a container file changed by another process after it was opened, **When** the
   developer saves, **Then** the save is refused with a distinct conflict error and the developer
   can refresh, compare or explicitly overwrite.
4. **Given** files owned by another user or exposed through a read-only mount, **When** the
   developer attempts an operation, **Then** it fails with a clear permission error and no partial
   change is left behind.
5. **Given** a container that lacks a usable helper runtime, a POSIX shell, or an unprivileged
   account, **When** the developer connects, **Then** the connection fails with an actionable
   message and no partial helper installation remains.
6. **Given** a container whose only account is root, **When** the developer has not opted in,
   **Then** the connection is refused with guidance; **When** the developer opts in for that
   target, **Then** the connection proceeds and a privilege warning is shown and logged.

---

### User Story 2 - Run commands, shells, builds and tools inside the container (Priority: P2)

A developer compiles, runs tests, opens an interactive shell, searches the project and uses
language tooling inside the container, exactly as they would on an SSH host. Output, exit codes,
signals, working directory and environment come from the container, and error navigation opens
the container's files.

**Why this priority**: Editing alone is not a development environment; builds, tests, shells and
language servers are the daily workflow that makes container targets useful.

**Independent Test**: For each standard Emacs process mechanism, compare output, exit status,
working directory and environment with running the same command directly inside the container.
Interrupt a long build, resize an interactive shell, and follow a compile error to its source.

**Acceptance Scenarios**:

1. **Given** a container target, **When** a process is started through any standard Emacs
   mechanism, **Then** output streams incrementally, the exit code is exact, and the working
   directory is inside the container.
2. **Given** a running in-container process, **When** the developer interrupts or kills it,
   **Then** the whole process group terminates and resources are released.
3. **Given** an interactive shell in the container, **When** the window is resized, **Then** the
   terminal size follows.
4. **Given** a compile with errors, **When** the developer follows an error, **Then** the matching
   container file opens at the right location.
5. **Given** a container connection lost while processes run, **When** the loss is detected,
   **Then** those processes are reported interrupted, are never replayed, and no command with
   unknown completion status is re-executed.

---

### User Story 3 - Discover, monitor and reconnect container targets (Priority: P2)

A developer sees which containers are running, picks one by a readable name instead of an ID,
and sees container connections in the same status and connection views as SSH hosts. When a
container stops, restarts or is replaced, the developer is told clearly and can reconnect without
losing unsaved work.

**Why this priority**: Without discovery and visibility, container support is usable only by
people who memorize IDs, and failures become indistinguishable from agent or filesystem errors.

**Independent Test**: With several containers running, open the connection list, connect to one
by completion, stop and restart it while a file is open, and verify state changes, log messages
and buffer preservation.

**Acceptance Scenarios**:

1. **Given** several running containers, **When** the developer asks to connect, **Then** running
   containers are offered for completion with readable names and no manual ID lookup is required.
2. **Given** a container connection, **When** status, connection list or logs are viewed, **Then**
   the target is shown as a container and is distinguishable from an SSH host.
3. **Given** an open container file, **When** the container is stopped, restarted or removed,
   **Then** the connection moves to a degraded, reconnecting or failed state, unsaved buffers are
   preserved, and the reason names the container condition.
4. **Given** a stopped container that starts again, **When** reconnection succeeds, **Then** the
   session resumes with invalidated caches and no replay of non-idempotent operations.
5. **Given** several container targets, **When** used at the same time, **Then** each connection
   and its processes operate independently.
6. **Given** a container target, **When** the developer disconnects or exits Emacs, **Then** the
   container itself keeps running.

---

### User Story 4 - Reach containers on a remote Docker engine (Priority: P3)

A developer runs containers on a remote development server that they already reach over SSH.
They can target a container on that engine and get the same editing and process behavior as a
local container, with the remote container kept distinct from any local container of the same
name.

**Why this priority**: It extends the feature to shared and cloud development hosts. Local
containers deliver the core value first, but remote-engine support is required in this feature and
is not deferred.

**Independent Test**: With a Docker engine reachable only through an SSH host, connect to one of
its running containers, edit and save a file, run a command, and connect to a same-named local
container to confirm the two targets are independent.

**Acceptance Scenarios**:

1. **Given** a Docker engine on a host reachable through the developer's existing SSH
   configuration, **When** the developer targets one of its containers, **Then** the connection is
   established and files can be edited with the same guarantees as a local container.
2. **Given** a local container and a remote container with the same name, **When** both are
   connected, **Then** they are separate targets with separate state, caches and processes.
3. **Given** the remote host is unreachable, **When** connecting, **Then** the failure is reported
   as an SSH/host failure rather than as a missing container.
4. **Given** the remote Docker engine denies access to the container, **When** connecting, **Then**
   the failure names the permission problem and the account involved.

---

### Edge Cases

- The container is not running when the developer connects.
- The container stops or is removed while files are open or a save is in flight.
- The container is restarted or recreated under the same name but with a new identity.
- The container's default account is root and no unprivileged account exists.
- The container has no POSIX shell, no supported helper runtime, or the runtime is at a
  non-standard path.
- The container is a minimal/distroless image that cannot host the helper at all.
- The Docker command is missing, the engine is unreachable, or the developer lacks permission to
  use it.
- Two engines expose containers with the same name, or a container name matches an SSH host name.
- Container files are owned by another user, are read-only, or are on a mount that changes
  underneath the session.
- Large files, sparse files, symlinks and hard links inside the container.
- A process floods output faster than Emacs consumes it, or the client stalls.
- Emacs exits or the connection drops while in-container processes are running.
- Two Emacs sessions target the same container at once.
- The container has no network access (the connection must not depend on the container's network).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: RDEV MUST allow a developer to target an already-running Docker container as a
  remote host and use the existing file-name workflow, commands and editing behavior without
  learning a separate mode.
- **FR-002**: Container support MUST reuse the existing client, helper and protocol architecture;
  it MUST be an additional target kind, not a parallel product with divergent behavior.
- **FR-003**: Existing SSH and TCP targets, commands, path syntax, customization variables and
  documented behavior MUST remain backward compatible; container support MUST be opt-in.
- **FR-004**: RDEV MUST identify a container by a human-readable name or ID and MUST validate the
  target before any file or process operation.
- **FR-005**: RDEV MUST distinguish and report, with actionable messages, a missing container, a
  container that is not running, an unreachable engine, a permission denial, and an unsupported
  container environment.
- **FR-006**: RDEV MUST deploy and verify its in-container helper atomically, detect corruption or
  truncation, clean up partial installations, and MUST NOT modify unrelated container files.
- **FR-007**: RDEV MUST run the in-container helper as an unprivileged account by default and MUST
  NOT require root privileges inside the container. When only a root account is available, RDEV
  MUST refuse by default with actionable guidance and MUST allow the connection only through an
  explicit opt-in, set per target or as a global default. While that opt-in is active, RDEV MUST
  warn on every connection and record the elevated privilege in the connection log.
- **FR-008**: RDEV MUST require no manual package installation inside the container and MUST NOT
  install packages itself. If the helper's runtime prerequisites are unmet, it MUST fail with a
  message naming the missing prerequisite and a remedy.
- **FR-009**: Container file operations MUST preserve the existing data-integrity guarantees:
  atomic saves, conflict detection, permission and symlink handling, binary and encoding fidelity,
  and bounded-memory transfer of large files.
- **FR-010**: RDEV MUST support in-container processes through standard Emacs mechanisms with
  correct output streaming, exit codes, process-group signals, working directory, environment,
  interactive terminal size and output flow control.
- **FR-011**: RDEV MUST NOT replay non-idempotent operations after a container connection loss and
  MUST report processes whose completion status is unknown as interrupted.
- **FR-012**: RDEV MUST offer running containers for discovery and completion, and MUST show
  container targets distinctly from SSH hosts in status, connection list and logs.
- **FR-013**: RDEV MUST handle a container that stops, restarts, is recreated or is removed:
  transition connection state, preserve unsaved buffers, report the cause, invalidate caches, and
  reconnect only when the same container is available again.
- **FR-014**: RDEV MUST support multiple simultaneous container targets independently, including
  a local and a remote container that share a name.
- **FR-015**: RDEV MUST support connecting to containers on a Docker engine reachable through the
  developer's existing SSH configuration, using that configuration and authentication unchanged.
  This capability is required in this feature and is not deferred.
- **FR-016**: RDEV MUST NOT open new network listeners for container access, MUST NOT store Docker
  or registry credentials, and MUST rely on the developer's existing Docker and SSH permissions.
- **FR-017**: RDEV MUST expose container target configuration through the existing customization
  mechanism and MUST document it alongside SSH configuration.
- **FR-018**: RDEV MUST distinguish container, engine, SSH, helper, filesystem and process
  failures in errors, status and logs, without exposing credentials or sensitive environment
  values.
- **FR-019**: RDEV MUST provide a way to disconnect from a container and to restart the
  in-container helper without stopping or restarting the container.
- **FR-020**: RDEV MUST leave the container and its own long-running services untouched when the
  developer disconnects or Emacs exits.

### Key Entities *(include if data involved)*

- **Container target**: a running container a developer can attach to; identified by a readable
  name and an immutable ID, with its engine location, default account and running status.
- **Container engine**: the Docker engine that hosts a target; either local or reached through an
  SSH host. It provides the namespace that keeps same-named containers distinct.
- **Container connection**: the RDEV session for one target; carries connection state, a
  generation used to invalidate caches, and the processes started through it.
- **Container target configuration**: the developer's saved description of a target (which
  container, which engine, which account) used for reuse and completion.
- **In-container helper**: the RDEV component installed inside the container; has a version, an
  integrity identity, an owning account and a lifecycle independent of the container's services.

### Documented Security Exception (FR-007)

The explicit root opt-in departs from the constitution's requirement that the agent never run as
root. The exception is deliberately narrow:

- It is off by default and applies only to the target it is set on.
- Every connection made with it active shows a privilege warning and records the elevated privilege
  in the connection log.
- Security tests cover both the refusal path and the opted-in path.
- **Rationale**: many development containers provide only a root account, so refusing
  unconditionally would exclude a large share of real containers.
- **Risk**: the helper then has the container's full privileges, so a defect or misuse could affect
  the whole container filesystem.
- **Remediation**: add an unprivileged account to the image, or target an existing one, after which
  the opt-in is no longer needed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer with a running container and a clean Emacs session can open, edit and
  save a container file in under 2 minutes with zero manual in-container installation.
- **SC-002**: 100% of the existing file-integrity acceptance scenarios (interrupted save, external
  modification, permissions, symlinks, large files) pass unchanged against container targets.
- **SC-003**: For a defined parity suite of commands, output and exit codes inside a container
  match direct execution in the container in 100% of cases.
- **SC-004**: In 100% of tested container stop, restart and removal events, unsaved buffers are
  preserved, the cause is reported, and no non-idempotent operation is replayed.
- **SC-005**: Container discovery lists every running container within 3 seconds on a machine
  running 50 containers.
- **SC-006**: The existing SSH and TCP test suites pass with zero regressions.
- **SC-007**: An unsupported container environment is detected and reported with an actionable
  message within 10 seconds of the connection attempt.
- **SC-008**: At least 90% of developers who already use RDEV over SSH complete their first
  container connection without consulting documentation.
- **SC-009**: With the root opt-in off, 100% of root-only container connection attempts are refused
  with guidance; with it on, 100% of connections show and log a privilege warning.

## Assumptions

- Containers are already running; creating, starting, stopping, building and removing containers
  or images is out of scope.
- Docker is the container runtime in scope; other runtimes are not required for this feature.
- The local Docker engine is the primary case; the remote-engine scope decision is recorded in
  Clarifications, and delivery follows the increments above.
- Container images are Linux-based and provide, or can be given, a POSIX shell and the helper's
  supported runtime (Python 3.8 or later); RDEV does not install packages.
- Docker command-line access and engine permissions are already configured for the developer; RDEV
  neither configures nor stores them.
- The default account inside a container is unprivileged; root-only containers are usable only
  through the explicit opt-in described in FR-007.
- The connection uses the container's process interface and does not depend on the container
  having network access or a published port.
- Container targets are configured through the existing host customization mechanism, extended
  with container-specific fields rather than a second configuration system.
- A container restarted or recreated under the same name is treated as a new session generation,
  so cached attributes and pending work from the previous instance are not reused.
