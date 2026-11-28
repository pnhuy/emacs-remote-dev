# Implementation Plan: Docker Container Remote Development

**Branch**: `002-docker-container-support` | **Date**: 2026-11-28 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-docker-container-support/spec.md`

## Summary

Extend the existing RDEV package so a running Docker container is another remote target, reached
through the same `/rdev:HOST:/path` convention and the same JSON-RPC agent. The transport becomes
`docker exec -i` on the local engine, or `ssh HOST docker exec -i` for an engine on an SSH host;
the agent bootstrap, stdio framing, relay, file handlers, process integration and reconnect state
machine are reused unchanged. The work is additive: `rdev-hosts` gains a `:transport 'docker`
kind, the client gains discovery and container-specific errors, and the agent gains a narrow,
explicitly opted-in root mode. No new RPC method, listener, credential store or mandatory
dependency is introduced.

Delivery is three increments from the spec: local container editing (P1), in-container workflows
and visibility (P2), and containers on a remote Docker engine (P3, required).

## Technical Context

**Language/Version**: Emacs Lisp on Emacs ≥ 30.1 (existing client); Python ≥ 3.8, standard library
only (existing agent). No new language or runtime.

**Primary Dependencies**: Existing Emacs built-ins (`jsonrpc`, `subr-x`, `cl-lib`,
`tabulated-list`); the `docker` command-line client, used only when a Docker target is selected;
the existing `ssh` client for remote engines. No new Python packages, no Docker SDK, no daemon
socket API.

**Storage**: The in-container helper lives under the container user's `$HOME/.cache/rdev/` (with a
documented fallback when `HOME` is unusable), installed with `umask 077` and verified by size and
SHA-256, exactly like the SSH bootstrap. Local state remains the existing in-memory connection and
cache tables; no new database.

**Testing**: ERT unit tests with a fake `docker` executable (command construction, inspection
parsing, discovery, errors, root policy, session identity, reconnect); Python `unittest` for the
agent's default root refusal and opt-in path; real E2E against a local Docker engine and a
disposable `sshd` fixture used as the remote engine host. `make check` and `make e2e S=docker` are
the gates.

**Target Platform**: Emacs client on Linux or macOS; containers are Linux; a remote engine host is
Linux or macOS with Docker and SSH. Docker Desktop and rootless Docker are expected to work but are
reported as unverified until exercised.

**Project Type**: Existing Emacs package plus remote agent, extended in place. No new project.

**Performance Goals**: Container discovery lists 50 running containers in ≤ 3 s (one `docker ps`
call plus parsing); first connect adds at most one `docker inspect` and one `docker exec` bootstrap
over the SSH baseline; steady-state file and process operations keep the same round-trip count as
SSH; the persistent `docker exec` process is reused for the session.

**Constraints**: Preserve `/rdev:HOST:/path`, JSON-RPC 2.0 with `Content-Length` framing, the local
relay, public commands and customization, and the stdlib-only agent. No new listening socket, no
stored Docker or registry credentials, no package installation inside containers, and no change to
existing SSH/TCP behavior. Root execution only through the documented opt-in (per target or
global).

**Scale/Scope**: A single developer with a handful of simultaneous container and SSH targets;
projects up to ~10^5 files; files up to hundreds of MB through the existing chunked path; up to 50
running containers for discovery.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Article | Pre-research | Post-design | Notes |
|---|---|---|---|
| I Architecture preservation | PASS | PASS | `/rdev:HOST:/path`, stdio JSON-RPC, bootstrap and relay preserved. Docker is a new transport branch in `rdev--connect-1`, not a fork. The agent's root behavior changes only behind an explicit opt-in, with justification, migration notes and regression tests. |
| II Native Emacs | PASS | PASS | File-name handlers and standard process APIs are reused; container targets are ordinary HOST keys. Dired, project.el, compile, shell, Eglot, Magit and Dape are exercised by E2E. TRAMP is untouched. |
| III Data integrity | PASS | PASS | Atomic save, conflict detection, permission/symlink handling and chunking are reused unchanged. No replay of non-idempotent operations after a container loss. |
| IV Security | PASS with documented exception | PASS with documented exception | No new listener, no credential storage, argv-only execution, validated names, bounded discovery, warnings and logs for the root opt-in. The opt-in is an Article IV exception recorded in Complexity Tracking and in the spec's Security Exception section. |
| V Performance | PASS | PASS | One persistent `docker exec`; discovery is one bounded call with a short cache; no extra round trip per file operation. Benchmarks compare first-connect and discovery against the SSH baseline. |
| VI Dependencies | PASS | PASS | Docker is optional and only required for Docker targets; agent stays stdlib-only; Emacs 30.1+; no package installation. Missing Docker or unsupported images fail with actionable diagnostics. |
| VII Testing | PASS | PASS | ERT + Python unit tests, a fake Docker CLI for determinism, real E2E for local and remote-engine paths, regression tests for the changed root refusal, and documented environment limits. |
| VIII Protocol | PASS | PASS | No new RPC method or framing change. The bootstrap flag is command-line, not protocol. Existing deployed agents are replaced by the verified bootstrap as today. |
| IX Maintainability | PASS | PASS | Docker CLI interaction is isolated in a new `rdev-docker.el`; transport selection stays in `rdev.el`; errors are a small, documented taxonomy; no unrelated refactoring. |
| X User experience | PASS | PASS | Containers are discoverable by name, appear in status/list views, and failures are distinguished from SSH, agent, filesystem and process failures. Existing commands behave as before. |
| XI Workflow | PASS | PASS | Existing client, agent, relay, state machine and tests were inspected before planning; confirmed behavior and assumptions are separated in research.md. |
| XII Definition of done | PASS | PASS | Each increment has executable acceptance; unverified environments (Docker Desktop, rootless Docker, a real second engine host) are reported explicitly. |

The only exception is the root opt-in (Article IV), justified in Complexity Tracking. No other
gate fails.

## Project Structure

### Documentation (this feature)

```text
specs/002-docker-container-support/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── docker-target.md # User-facing target/config/error contract
│   └── bootstrap.md     # In-container bootstrap and root-policy contract
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
rdev.el                  # transport selection, rdev-hosts extension, errors, discovery hook,
                         #   completion, commands, reconnect/session identity integration
rdev-docker.el           # NEW: Docker CLI invocation, inspect/ps parsing, process construction,
                         #   discovery cache, root-policy checks
rdev-state.el            # container-aware session keys (engine + container identity)
rdev-ui.el               # container rows/labels in status and connection list
rdev-server.py           # narrow --allow-root opt-in; default refusal unchanged
rdev-relay.py            # unchanged
test/
├── rdev-docker-test.el  # NEW: ERT unit tests (fake docker CLI)
├── fixtures/fake-docker # NEW: deterministic docker CLI double
├── py/test_root_refusal.py  # extend: default refusal + opt-in
└── e2e/
    ├── docker.el        # NEW: real-Docker scenarios
    └── docker-fixture.sh # NEW: start/stop fixture containers (unprivileged and root-only)
docs/
├── connections.md       # container targets, lifecycle, reconnect
├── security.md          # root opt-in, trust boundary, no new listeners
├── README.md            # user-facing configuration and commands
└── DEVELOPING.md        # test commands and fixture prerequisites
README.md                # short usage section
```

**Structure Decision**: Keep the single-package layout. `rdev.el` remains the public entry point and
owns transport selection; `rdev-docker.el` is loaded lazily when a Docker target is used, so the
SSH-only path has no new load-time dependency. The agent and relay keep their locations because the
client locates them next to `rdev.el`.

## Phase 0: Research (output: [research.md](research.md))

All Technical Context unknowns are resolved there. The decisions that shape the plan:

- **Transport**: reuse stdio JSON-RPC over `docker exec -i`; no TCP, no new listener, no new RPC.
- **Addressing**: `rdev-hosts` entry with `:transport 'docker`; the alist key remains the HOST in
  `/rdev:HOST:/path`; `:container` defaults to HOST.
- **Identity**: session key `docker:<engine>:<container-id>`; a recreated same-name container is a
  new generation with empty caches.
- **Bootstrap**: reuse the existing size+hash bootstrap and agent, run through `sh -c` in the
  container; no package installation.
- **Root policy**: refuse by default; `:allow-root t` or the global `rdev-docker-allow-root` plus
  an agent `--allow-root` flag is the only path, with a warning on every connect and a log record.
- **Remote engine**: `:docker-host` runs `docker` on an SSH host through the existing SSH client
  and configuration; engine identity comes from the canonical SSH session key.
- **Discovery**: one bounded `docker ps` call with a short cache, offered only when Docker targets
  are relevant.
- **Errors**: a `rdev-docker-error` family under the existing transport error, with reasons for
  not-found, not-running, permission, unsupported image and root refusal.
- **Lifecycle**: reuse the existing state machine and reconnect/backoff; re-resolve the container
  on every reconnect and treat a changed ID as a new session.

## Phase 1: Design (outputs: [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md))

### Data model

Five entities: **container engine**, **container target**, **target configuration**, **container
connection**, and **in-container helper**. The model defines the session-key format, the validation
rules for names/IDs/users/programs, the root-policy decision, and the state transitions for
connect, stop, restart, replacement and removal. It reuses the existing `DISCONNECTED → CONNECTING
→ BOOTSTRAPPING → INITIALIZING → CONNECTED ⇄ DEGRADED` machine.

### Contracts

- `contracts/docker-target.md`: the `rdev-hosts` schema extension, discovery and completion
  behavior, command surface, error taxonomy, and lifecycle guarantees.
- `contracts/bootstrap.md`: the in-container bootstrap markers, install path and fallback, the
  root-refusal/opt-in contract, and the rule that no packages are installed.

### Quickstart

`quickstart.md` gives runnable local and remote-engine validation scenarios, the fixture image
requirements, the automated commands (`make check`, `make e2e S=docker`), and expected outcomes.

## Delivery Plan

### Increment 1 — Local container editing (P1)

1. Add `:transport 'docker`, `:container`, `:docker-user`, `:docker-program`, `:docker-host` and
   `:allow-root` to the `rdev-hosts` contract; add `rdev-docker-program` and discovery cache
   customization.
2. Add `rdev-docker.el`: build the local `docker exec -i` process, run `docker inspect` for state
   and identity, parse results, and map failures to the error family.
3. Integrate transport selection in `rdev--connect-1`; keep `rdev--ssh-process` and
   `rdev--tcp-process` untouched.
4. Reuse the bootstrap script; parameterize the install location so the SSH path keeps
   `$HOME/.cache/rdev` unchanged while the Docker path gains the documented `/tmp/rdev-<uid>`
   fallback, and add the root probe (≤ 10 s) before installing.
5. Add the agent `--allow-root` flag with the default refusal unchanged.
6. Extend session identity in `rdev-state.el` and cache invalidation on container replacement.
7. ERT tests with the fake Docker CLI; Python tests for both root paths; first real E2E edit/save.

### Increment 2 — In-container workflows and visibility (P2)

1. Validate processes, PTY resize, signals, exit codes, compile navigation, shell, Eglot, Magit and
   Dape against a real container; fix only container-specific gaps.
2. Add `rdev-docker-connect`, `rdev-docker-list`, and completion of running containers; keep
   `rdev-find-file`, `rdev-shell`, `rdev-reconnect` and `rdev-disconnect` behavior.
3. Show container targets in `rdev-status` and `rdev-list-connections` with engine and container
   labels; add log lines for container stop/restart/replacement.
4. Implement reconnect re-resolution and generation invalidation; verify no replay.
5. Add discovery and status ERT tests and the local Docker E2E suite.

### Increment 3 — Remote Docker engine (P3, required)

1. Build the `ssh HOST docker exec -i` process path with strict argument quoting and the existing
   SSH arguments and configuration.
2. Namespace engine identity in the session key; keep local and remote same-named containers
   independent.
3. Report SSH/host failures separately from container and Docker failures.
4. Add remote-engine discovery through the same SSH host.
5. E2E against the disposable `sshd` fixture acting as the engine host; document a real second-host
   check as an environment-dependent verification.

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Image has no `sh`, no Python ≥ 3.8, or a read-only home | Detect before installing, clean up partial files, fail with a remedy naming the prerequisite. |
| Container runs only as root | Refuse by default with guidance; `:allow-root`/`rdev-docker-allow-root` is the documented exception, warns and logs. |
| Container stopped, removed or recreated under the same name | Re-resolve identity on reconnect; changed ID means new generation and empty caches; never replay. |
| Docker CLI missing, daemon unreachable, or permission denied | Distinct `rdev-docker-error` reasons with the command and account involved. |
| Remote-engine argument injection through names or paths | Validate names against the Docker charset, pass argv, quote the remote `sh -c` payload, use `--` separators. |
| Discovery slows completion | One `docker ps`, bounded output, short TTL cache, timeout, and only when Docker targets exist. |
| Root opt-in weakens the security model | Off by default, per-target or global, warned on every connect, logged, covered by negative and positive tests, documented exception with remediation. |
| Docker Desktop/rootless differences | Report as unverified until exercised; keep the transport to documented CLI behavior. |
| Existing SSH/TCP regressions | Docker code is additive; the full existing suite is a gate, and no shared function changes behavior for non-Docker hosts. |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| In-container helper may run as root under an explicit opt-in, per target or global (Article IV) | The spec requires root-only containers to be usable through a deliberate opt-in; many development containers provide no unprivileged account. | Unconditional refusal excludes a large share of real containers; running as a non-root account is impossible when none exists. |
| New agent `--allow-root` flag changes the unconditional root refusal (Articles I, IV) | The opt-in cannot work while the agent exits 5 for uid 0; a flag keeps the default refusal intact and confines the exception. | A separate root-capable agent fork duplicates the codebase, drifts from the tested agent, and is harder to audit. |

Both exceptions are limited to the root opt-in, are off by default, and have documented rationale,
risk and remediation in the spec. No other constitutional exception is requested.

## Verification Plan

- `make check`: ERT, Python unit tests, byte-compile/checkdoc, portability lint.
- `make e2e S=docker`: local container editing, conflict, save interruption, process/PTY, discovery,
  stop/restart, root refusal and opt-in, and remote-engine path through the `sshd` fixture.
- Manual/recorded: Docker Desktop and rootless Docker, a real second engine host, and a container
  with a non-standard `HOME`; any not run are listed in the milestone report rather than claimed.
- Regression: the complete existing SSH/TCP E2E and unit suites pass unchanged.

## Analysis Remediation Log

Dispositions of the findings from `/speckit.analyze` (2026-11-28). Tasks T020, T034 and T035 were
added, and T013, T016, T018, T021, T025, T030, T038 and T049 were amended in `tasks.md`.

| ID | Disposition |
|---|---|
| C1 (FR-016 negative security tests) | New task T020: no listener/socket beyond the relay, no credential storage, log redaction verified. |
| C2 (FR-019 helper restart untested) | New task T034: `rdev-restart-server` on a Docker target replaces the helper without stopping the container. |
| C3 (FR-020 no-side-effect untested) | New task T035: disconnect/exit leave the container and its services running. |
| C4 (shared bootstrap template) | Resolved as parameterization: SSH install path stays `$HOME/.cache/rdev` byte-for-byte; only Docker gains the `/tmp/rdev-<uid>` fallback. Recorded in plan Increment 1, T016 and T021. |
| C5 (name-collision precedence) | Rule added to `contracts/docker-target.md` §2: the configured `rdev-hosts` entry wins; one target per key. Precedence test added to T038. |
| C6 (SC-007 probe time bound) | Root and environment probes get their own ≤ 10 s timeout in T013/T016, independent of `rdev-docker-timeout`. |
| C7 (duplicated remote-engine statements) | `spec.md` Scope and Assumptions now point to Clarifications as the authority. |
| C8 (verify-task pass conditions) | T025/T030 pass condition defined as executing the quickstart scenarios and recording results. |
| C9 (terminology drift) | "Container target" is canonical; the alias is noted in the docs task T049. |
| C10 (unrelated-files assertion) | Folded into T018: connect changes no container files outside the helper path. |

## Constitution Check — post-implementation (2026-11-28)

Re-checked against the implemented code and the executed suites. All gates remain **PASS**; the
only exception is the root opt-in (Article IV), unchanged and documented in Complexity Tracking
and `docs/security.md`. The implementation matches the design with these clarifications:

- `rdev-docker--inspect` returns the container state; `rdev-docker--process` enforces
  `not-running` (stopped or paused) before `docker exec`, so the documented error reason is
  produced at connect time.
- A remote engine's ssh failure is detected from the ssh exit status/stderr and signals
  `rdev-ssh-error` (T045); Docker failures keep `rdev-docker-error` with a reason.
- A container replaced during a reconnect attempt resolves to a new session key; the new key
  runs the ordinary connecting transitions instead of being mistaken for the in-flight
  reconnect (T017).
- `rdev-docker-probe-timeout` (10 s) is independent of `rdev-docker-timeout`, as SC-007 requires.
- The root opt-in can be set per target (`:allow-root`) or globally (`rdev-docker-allow-root`);
  both are off by default, and the warning/log behavior is identical.
- No new RPC method, listener, credential store or mandatory dependency was introduced; the
  agent's default root refusal and exit 5 are unchanged.
