# Tasks: Docker Container Remote Development

**Input**: Design documents from `specs/002-docker-container-support/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: Included because the project constitution (Article VII) and the spec's security
exception require automated coverage. Where a test task precedes its implementation, it must fail
first.

**Organization**: Tasks are grouped by user story so each story is independently implementable and
testable.

**Analysis remediation**: Tasks T020, T034 and T035 and the amendments to T013, T016, T018, T021,
T025, T030, T038 and T049 close the gaps found by `/speckit.analyze` (see the Analysis Remediation
Log in `plan.md`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `US1`–`US4`, mapped to the user stories in `spec.md`
- Every task names the exact file path it changes

## Path Conventions

This is the existing single-package layout: `rdev.el`, `rdev-docker.el`, `rdev-state.el`,
`rdev-ui.el`, `rdev-server.py`, `rdev-relay.py` at the repository root; tests under `test/`;
documentation under `docs/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Configuration surface, module skeleton, error family, and test fixtures.

- [x] T001 Configure Docker target keys in the `rdev-hosts` `defcustom` in `rdev.el` (`:transport`, `:container`, `:docker-host`, `:docker-user`, `:docker-program`, `:allow-root`) and add `rdev-docker-program` (default `"docker"`), `rdev-docker-discovery-ttl` (default `5`), `rdev-docker-discovery-max` (default `200`), `rdev-docker-timeout` (default `rdev-timeout`); add a lazy `(require 'rdev-docker)` hook without changing SSH/TCP defaults.
- [x] T002 [P] Create `rdev-docker.el` with a file header, `(require 'rdev)`, `declare-function` declarations for the client internals it calls, and no load-time side effects.
- [x] T003 Add `rdev-docker-error` as a child of `rdev-transport-error` in `rdev.el`, plus a helper that signals it with a `reason` in `{not-found, not-running, permission, engine-unreachable, unsupported, root-refused, bootstrap}`.
- [x] T004 [P] Create executable `test/fixtures/fake-docker` supporting `version`, `inspect`, `ps`, and `exec` with canned output and env-var-configurable failures; it must not touch the network.
- [x] T005 [P] Create `test/rdev-docker-test.el` with ERT helpers that bind `rdev-docker-program` to `test/fixtures/fake-docker`, clear `rdev--conns`, `rdev--chans`, and `rdev-state--keys` between tests, and restore `rdev-hosts`.
- [x] T006 [P] Create `test/e2e/docker-fixture.sh` that starts/stops an unprivileged fixture container (image from `RDEV_TEST_DOCKER_IMAGE`, default `python:3.11-slim`, user `dev`) and a root-only container, seeds `/workspace`, prints the container names, and removes both on stop.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared Docker transport, identity, bootstrap, root policy, and reconnect behavior
that every user story needs.

**⚠️ CRITICAL**: No user-story work can begin until this phase is complete.

- [x] T007 Implement `rdev-docker--run` in `rdev-docker.el`: argv-only invocation of `rdev-docker-program` (local) or `ssh` plus `:docker-host` (remote), bounded stdout/stderr, timeout `rdev-docker-timeout`, no shell interpolation of user input, and mapping of non-zero exits to `rdev-docker-error` reasons.
- [x] T008 [P] Implement `rdev-docker--inspect` in `rdev-docker.el`: read `.Id`, `.Name`, `.Image`, `.State.Running`, `.State.Paused`, `.Config.User`; validate the container name against `[A-Za-z0-9][A-Za-z0-9_.-]*` or an ID of 12–64 lowercase hex characters; connect only when `running` is true and `paused` is false; signal `not-found` or `not-running` otherwise.
- [x] T009 [P] Implement `rdev-docker--ps` and the discovery snapshot cache in `rdev-docker.el`: one `docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}'`, cap at `rdev-docker-discovery-max` (200) and mark truncation, cache per engine for `rdev-docker-discovery-ttl` (5 s), and keep the previous snapshot on error.
- [x] T010 Implement `rdev-docker--process` in `rdev-docker.el`: build `docker exec -i [--user USER] CONTAINER sh -c '<quoted bootstrap>'` with `:connection-type 'pipe`, `:coding 'binary`, `:noquery t`, a stderr buffer and the existing bootstrap filter; never pass `-t`; never interpolate an unvalidated name.
- [x] T011 Integrate the Docker branch in `rdev--connect-1` in `rdev.el`: `(eq (plist-get spec :transport) 'docker)` calls `rdev-docker--process`; SSH and TCP code paths keep their current behavior; set `:transport 'docker` on the connection.
- [x] T012 Extend `rdev-state-session-key` in `rdev-state.el`: for a Docker target return `docker:<engine>:<container-id>` where `<engine>` is `local` or the canonical SSH key of `:docker-host`; add a helper for the Docker key and leave SSH keys unchanged.
- [x] T013 Implement the root policy in `rdev-docker.el`: probe the effective UID with a probe timeout of at most 10 seconds (SC-007); UID 0 without `:allow-root` signals `root-refused` with the three remedies (use an unprivileged account, set `:docker-user`, or set `:allow-root`); UID 0 with `:allow-root` proceeds, calls `display-warning` on every connect, and logs `helper runs with container-root privileges`; unknown UID signals `unsupported`; refusal must install nothing.
- [x] T014 Add the `--allow-root` argument to `rdev-server.py` argparse; keep the default `os.geteuid() == 0` refusal and exit 5 unchanged; accept the flag only from the command line, never from RPC, environment variables or configuration files.
- [x] T015 Extend `test/py/test_root_refusal.py`: monkeypatch `os.geteuid` to 0, assert the default exit 5 and refusal message, assert `--allow-root` reaches session startup, and assert no environment variable enables the override.
- [x] T016 Implement the bootstrap install in the Docker path (`rdev-docker.el` plus a parameterized install location in the shared template in `rdev.el`): verify exact size and SHA-256; `mv` atomically; remove the temporary file on failure; use `${HOME}/.cache/rdev` with mode 0700 when writable, otherwise `/tmp/rdev-<uid>` with mode 0700 (Docker only — the SSH install path stays byte-for-byte unchanged); report `unsupported` when `sh` or Python ≥ 3.8 is missing (probe timeout ≤ 10 s, SC-007); install no packages.
- [x] T017 Implement reconnect re-resolution in `rdev.el`: re-inspect the configured container on every reconnect; the same ID resumes the same session key with a bumped generation; a new ID closes the old key, starts a new key with empty caches, and logs `container replaced: <old> → <new>`; a missing/stopped container retries to `failed`; never replay non-idempotent operations.
- [x] T018 [P] Add ERT tests for configuration defaults, local and remote command construction/quoting, inspect/ps parsing, every error reason, and an assertion that a Docker connect changes no container files outside the helper path (checked through the fake Docker CLI) in `test/rdev-docker-test.el`.
- [x] T019 Add ERT tests for Docker session keys, the root policy (refuse, opt-in, unknown), container replacement, and generation/cache invalidation in `test/rdev-docker-test.el`.
- [x] T020 Add ERT security negative tests in `test/rdev-docker-test.el`: a Docker connect creates no listening process or socket beyond the existing local relay, no Docker or registry credential is read or stored, and values matching the log-redaction list (token, secret, password, key) never appear in `*rdev-log NAME*`.
- [x] T021 [P] Record the agent `--allow-root` flag, the Docker transport, and the bootstrap location parameterization (SSH install path unchanged) in `test/INTENTIONAL-CHANGES.md` with justification, migration path, and the covering test names.

**Checkpoint**: The Docker transport connects, bootstraps, applies the root policy, and reconnects.
User stories can now proceed.

---

## Phase 3: User Story 1 — Edit files inside a running local container (Priority: P1) 🎯 MVP

**Goal**: Open, edit, create, rename, delete and save files in a local container with the existing
data-integrity guarantees.

**Independent Test**: With the unprivileged fixture running, open `/rdev:NAME:/workspace/...`,
edit and save, verify content and permissions, modify the file externally and confirm a conflict,
and interrupt a save and confirm complete old/new content.

### Tests for User Story 1

- [x] T022 [P] [US1] Add ERT tests that a Docker host key routes file-name handler operations (read, write, rename, delete, attributes) to the Docker connection and leaves SSH/TCP behavior unchanged in `test/rdev-docker-test.el`.
- [x] T023 [P] [US1] Add E2E scenarios 1–2 (open/edit/save; external-modification conflict) in `test/e2e/docker.el` against the unprivileged fixture.
- [x] T024 [US1] Add E2E scenario 3 (interrupted save leaves complete old/new content, the buffer keeps edits, and the connection reconnects) in `test/e2e/docker.el`.

### Implementation for User Story 1

- [x] T025 [US1] Verify and fix any container-specific file-handler gaps in `rdev.el` (atomic save, conflict detection, permissions, symlinks, binary/encoding, chunked large files). Pass condition: quickstart scenarios 1–3 have been executed against a real container and their results recorded; if no container-specific gaps are found, record that verification in the `test/e2e/docker.el` header.
- [x] T026 [P] [US1] Document local container editing and the `:transport docker` example in `docs/README.md`.

**Checkpoint**: User Story 1 works independently and is the MVP.

---

## Phase 4: User Story 2 — Run commands, shells, builds and tools (Priority: P2)

**Goal**: Run processes, interactive shells, builds, searches and language tooling inside the
container with exact output, exit codes, signals and PTY behavior.

**Independent Test**: Compare output and exit codes with direct `docker exec`, interrupt a build,
resize a shell, follow a compile error, and confirm a lost connection marks processes interrupted
without replay.

### Tests for User Story 2

- [x] T027 [US2] Add ERT process-parity tests (stdout/stderr, exit codes, signals, PTY resize, environment filtering) in `test/rdev-docker-test.el` using the fake Docker CLI.
- [x] T028 [P] [US2] Add E2E scenario 4 (shell, compile, Eglot, interrupt, resize) in `test/e2e/docker.el`.
- [x] T029 [US2] Add an ERT test that a container loss marks owned processes interrupted (exit 255) and never replays them in `test/rdev-docker-test.el`.

### Implementation for User Story 2

- [x] T030 [US2] Verify and fix any container-specific process gaps in `rdev.el` and `rdev-docker.el`. Pass condition: quickstart scenario 4 has been executed against a real container and its results recorded; if no container-specific gaps are found, record that verification in the E2E header.
- [x] T031 [P] [US2] Document in-container workflows (shell, compile, Eglot, Magit, Dape) in `docs/connections.md`.

**Checkpoint**: User Stories 1 and 2 work independently.

---

## Phase 5: User Story 3 — Discover, monitor and reconnect container targets (Priority: P2)

**Goal**: List running containers, connect by readable name, show container targets distinctly, and
handle stop/restart/replacement clearly.

**Independent Test**: With several containers running, discover and connect by completion, stop and
restart one while a file is open, recreate it under the same name, and verify state, logs, caches
and buffer preservation.

### Tests for User Story 3

- [x] T032 [US3] Add ERT tests for discovery cache/TTL/bounds/truncation, completion, status labels, connect/disconnect, and stop/restart/replacement in `test/rdev-docker-test.el`.
- [x] T033 [P] [US3] Add E2E scenario 6 (stop, restart, recreate, reconnect, replacement log, no replay) in `test/e2e/docker.el`.
- [x] T034 [US3] Add an ERT test that `rdev-restart-server` on a Docker target replaces the helper and reconnects without stopping the container (asserted through the fake Docker CLI) in `test/rdev-docker-test.el`.
- [x] T035 [US3] Add an E2E assertion in `test/e2e/docker.el` that disconnecting and exiting Emacs leave the container and its own services running (`docker ps` still shows it) and only RDEV's helper and owned processes are affected.

### Implementation for User Story 3

- [x] T036 [US3] Implement `rdev-docker-list` in `rdev-docker.el` using the discovery snapshot; show name, ID, image and status with bounded output.
- [x] T037 [US3] Implement `rdev-docker-connect` in `rdev.el` with completion over configured Docker targets and running containers.
- [x] T038 [US3] Extend `rdev--ssh-hosts` and target completion in `rdev.el` to include configured Docker keys and a fresh discovery snapshot; include a precedence test that a configured `rdev-hosts` key wins over an `~/.ssh/config` alias of the same name; discovery failure must not break SSH completion.
- [x] T039 [P] [US3] Add container labels/rows to `rdev-status` and `rdev-list-connections` in `rdev-ui.el`, showing the engine and container name.
- [x] T040 [US3] Document discovery, status and lifecycle behavior in `docs/connections.md`.

**Checkpoint**: User Stories 1–3 work independently.

---

## Phase 6: User Story 4 — Reach containers on a remote Docker engine (Priority: P3, required)

**Goal**: Target containers on a Docker engine reached through an SSH host, with local and remote
same-named containers kept independent.

**Independent Test**: Configure `:docker-host` to the disposable `sshd` fixture (or a real host),
edit and save a file, run a command, and connect to a same-named local container to confirm
separate state; confirm an unreachable SSH host reports an SSH error.

### Tests for User Story 4

- [x] T041 [US4] Add ERT tests for remote-engine command construction/quoting, engine namespacing, and SSH-versus-Docker error mapping in `test/rdev-docker-test.el`.
- [x] T042 [P] [US4] Add E2E scenario 8 (remote engine through the `sshd` fixture) in `test/e2e/docker.el`.

### Implementation for User Story 4

- [x] T043 [US4] Implement the remote-engine process path in `rdev-docker.el`: `ssh <rdev-ssh-args> -- <docker-host> <docker-program> exec -i [--user USER] CONTAINER sh -c '<quoted bootstrap>'`, with `--` separators and one shell-quoted bootstrap payload.
- [x] T044 [US4] Implement engine identity and namespacing in `rdev-state.el` and `rdev.el`: use the canonical SSH key for `:docker-host` and keep local and remote same-named containers independent.
- [x] T045 [US4] Map SSH failures to `rdev-ssh-error` and Docker failures to `rdev-docker-error` with the correct reason in `rdev.el` and `rdev-docker.el`.
- [x] T046 [US4] Add remote discovery through `:docker-host` in `rdev-docker.el` using the same `docker ps` contract.
- [x] T047 [US4] Document remote-engine configuration and failure modes in `docs/README.md`.

**Checkpoint**: All four user stories work independently.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, measurement, full regression, and explicit verification limits.

- [x] T048 [P] Update `docs/security.md` with the root opt-in, its warning/log behavior, the no-new-listener guarantee, and the trust boundary.
- [x] T049 [P] Update `README.md` and `docs/DEVELOPING.md` with the Docker usage section and the fixture/test commands; use "container target" as the canonical term and note it is also called a Docker target.
- [x] T050 [P] Add `bench/docker-discovery.sh` to measure discovery for 50 containers and first-connect overhead; record the numbers under `bench/`.
- [x] T051 Run `make check` and fix all regressions in the existing ERT, Python, quality and lint suites.
- [x] T052 Run `make e2e S=docker` and record pass/fail and the environment in `test/MILESTONE-REPORT.md`.
- [x] T053 Run the quickstart scenarios 1–8 and record which environments were exercised and which were not in `test/MILESTONE-REPORT.md` and `test/e2e/PLATFORMS.md`.
- [x] T054 Update `test/KNOWN-FAILURES.md` for unresolved environment limits; do not hide skips.
- [x] T055 Re-run the Constitution Check against the implementation, update `specs/002-docker-container-support/plan.md` if behavior differs, and confirm the root exception remains documented.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Starts immediately; T001–T006 have no user-story dependency.
- **Foundational (Phase 2)**: Depends on Setup; blocks all user stories.
- **User Stories (Phases 3–6)**: Depend on Foundational. US1, US2 and US3 can run in parallel after
  Phase 2. US4 depends on the US1 transport and US3 discovery for its remote discovery path.
- **Polish (Phase 7)**: Depends on all four stories.

### User Story Dependencies

- **US1 (P1)**: No dependency on other stories. MVP.
- **US2 (P2)**: No dependency on US1; shares only the foundational transport.
- **US3 (P2)**: No dependency on US1/US2; uses the foundational inspect/discovery.
- **US4 (P3, required)**: Uses the US1 transport and the US3 discovery for the remote-engine path;
  its editing and process behavior can be tested independently once those exist.

### Within Each Story

- Tests are written before the corresponding fix where the task order allows and must fail first.
- Core transport and identity precede story-specific behavior.
- Story checkpoints are validated independently before the next priority.

### Parallel Opportunities

- T002, T004, T005, T006 are independent files.
- T008 and T009 are independent `rdev-docker.el` functions but share a file, so run them
  sequentially; T014 and T021 are independent files.
- T018 and T021 are independent files.
- After Phase 2: US1, US2 and US3 can proceed in parallel by different developers.
- T026, T031, T039, T042, T048, T049 and T050 touch different files and can run in parallel.

---

## Parallel Example: User Story 1

```text
Task: "T022 [P] [US1] Add ERT file-handler routing tests in test/rdev-docker-test.el"
Task: "T023 [P] [US1] Add E2E edit/save/conflict scenarios in test/e2e/docker.el"
Task: "T026 [P] [US1] Document local container editing in docs/README.md"
```

## Parallel Example: After Foundational

```text
Developer A: US1 (T022–T026)
Developer B: US2 (T027–T031)
Developer C: US3 (T032–T040)
Developer D: US4 (T041–T047), after US1 transport and US3 discovery (T038) are ready
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational — the Docker transport, bootstrap, root policy and reconnect.
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: run `make check`, `make e2e S=docker` for the US1 scenarios, and the
   quickstart scenarios 1–3.
5. Demo local container editing.

### Incremental Delivery

1. Setup + Foundational → transport ready.
2. US1 → local editing MVP.
3. US2 → in-container processes and tools.
4. US3 → discovery, status and lifecycle.
5. US4 → remote engine (required for the feature's full scope).
6. Polish → docs, measurements, full regression, explicit environment limits.

### Parallel Team Strategy

1. One developer completes Setup + Foundational.
2. Then US1, US2 and US3 proceed in parallel.
3. US4 starts once the US1 transport and US3 discovery are stable.
4. Polish is shared after all stories.

---

## Notes

- `[P]` means a different file and no incomplete dependency; tasks that edit the same file are
  sequential even when logically independent.
- Every task names its file path.
- Tests must be executed, not inferred; record actual results and environment limits.
- The root opt-in is the only constitutional exception; keep its warning, log and tests intact.
- Do not weaken or remove the agent's default root refusal.
