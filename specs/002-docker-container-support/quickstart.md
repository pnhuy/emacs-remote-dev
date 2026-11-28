# Quickstart Validation: Docker Container Remote Development

**Feature**: `002-docker-container-support` | **Date**: 2026-11-28

Use this guide to validate the feature end to end. It describes runnable scenarios, not the
implementation. Contracts and the data model hold the details:
[docker-target.md](contracts/docker-target.md), [bootstrap.md](contracts/bootstrap.md),
[data-model.md](data-model.md).

---

## Prerequisites

- Emacs 30.1 or later with this repository on `load-path`.
- Docker 20.10 or later, with the developer able to run `docker ps` and `docker exec`.
- For the remote-engine scenario: an SSH destination that can run `docker` (the disposable
  `sshd` fixture from `test/e2e/sshd-fixture.sh` works).
- A Linux container image with `sh` and Python 3.8 or later. The automated fixture defaults to
  `python:3.11-slim`; override with `RDEV_TEST_DOCKER_IMAGE`.
- A non-root account in the container for the default path. A root-only container is used only in
  the opt-in scenario.

Create a local fixture:

```sh
docker run -d --name rdev-demo -w /workspace python:3.11-slim sleep infinity
docker exec rdev-demo sh -c 'useradd -m dev || true'
docker exec rdev-demo sh -c 'mkdir -p /workspace && printf "hello\n" > /workspace/hello.txt'
docker exec rdev-demo chown -R dev /workspace
```

Load RDEV and configure the target:

```elisp
(add-to-list 'load-path "/path/to/emacs-remote-dev")
(require 'rdev)
(setq rdev-hosts
      '(("demo" . (:transport docker
                   :container "rdev-demo"
                   :docker-user "dev"))))
```

---

## Scenario 1 — Edit and save a file (P1)

1. `M-x rdev-find-file RET demo RET`, then open `/rdev:demo:/workspace/hello.txt`.
2. Edit the buffer and `C-x C-s`.
3. In a shell, run `docker exec rdev-demo cat /workspace/hello.txt`.

**Expected**: the file opens as an ordinary buffer; the save succeeds; the container shows the new
content; `M-x rdev-status` shows `demo` as a Docker target in `connected` state; the log shows the
helper was installed and verified (or reused).

---

## Scenario 2 — Conflict detection (P1)

1. Open `/rdev:demo:/workspace/hello.txt` and modify the buffer without saving.
2. In a shell, run `docker exec rdev-demo sh -c 'printf "external\n" >> /workspace/hello.txt'`.
3. Save from Emacs.

**Expected**: the save is refused with a conflict error; the buffer keeps the unsaved edits; the
developer can refresh, compare or explicitly overwrite.

---

## Scenario 3 — Interrupted save (P1)

1. Open a large file in the container and modify it.
2. Start a save and, during the transfer, run `docker stop rdev-demo` (or kill the `docker exec`
   process).
3. Inspect the file from the host or after restarting the container.

**Expected**: the file contains either the complete old content or the complete new content, never
a partial write; the Emacs buffer still holds the unsaved edits; the connection reports the loss
and reconnects with bounded backoff when the container returns.

---

## Scenario 4 — Processes, shell and compile (P2)

1. `M-x rdev-shell RET demo RET`, run `pwd` and `id`.
2. `M-x compile` with a command such as `python3 -c 'print(1/0)'` or a project build.
3. Interrupt a long-running command and resize the shell window.

**Expected**: output streams incrementally; the working directory is inside the container; `id`
shows the configured account; the exit code matches direct `docker exec`; signals terminate the
process group; the terminal size follows; compile errors open the container file at the right
location.

---

## Scenario 5 — Discovery and status (P2)

1. Start two more containers.
2. `M-x rdev-docker-list`.
3. `M-x rdev-docker-connect` and use completion.
4. `M-x rdev-list-connections`.

**Expected**: all running containers are listed with readable names; completion does not require
an ID; Docker targets are visibly distinct from SSH hosts; discovery completes within 3 seconds for
50 containers.

---

## Scenario 6 — Stop, restart, recreate (P2)

1. With a file open, run `docker stop rdev-demo`.
2. Observe `M-x rdev-status` and the log.
3. Run `docker start rdev-demo`; reconnect.
4. Remove and recreate the container under the same name, then reconnect.

**Expected**: stop moves the connection to `reconnecting`/`failed` and preserves buffers; restart
with the same ID reconnects under the same session; recreation produces a new session, empty
caches and a `container replaced` log line; no non-idempotent operation is replayed.

---

## Scenario 7 — Root policy (P1)

1. Start a root-only container (no unprivileged account).
2. Connect without `:allow-root`.

**Expected**: refused with `root-refused`, naming the container and the three remedies; no helper
file is installed.

3. Add `:allow-root t` to the target and connect.

**Expected**: the connection succeeds; a privilege warning is shown on every connect; the log
records the elevated privilege.

---

## Scenario 8 — Remote engine over SSH (P3, required)

1. Make a Docker engine reachable through SSH (for example, the `sshd` fixture on the same machine,
   or a real development host).
2. Configure:

```elisp
(setq rdev-hosts
      '(("remote-demo" . (:transport docker
                          :container "rdev-demo"
                          :docker-host "dev-server"))))
```

3. Open `/rdev:remote-demo:/workspace/hello.txt`, edit and save; run a command.
4. Connect to a local container with the same name.

**Expected**: both targets work with the same guarantees; they have separate state, caches and
processes; an unreachable SSH host reports `rdev-ssh-error`, not `not-found`; a Docker permission
failure reports `permission` with the account.

---

## Automated validation

```sh
make check                 # ERT + Python unit tests + quality + portability
make e2e S=docker          # real local Docker and remote-engine scenarios
RDEV_TEST_DOCKER_IMAGE=python:3.11-slim make e2e S=docker
```

The E2E fixture starts and stops its own containers and the disposable `sshd`; it must leave no
container, listener or temporary file behind. A missing image or Docker daemon is reported as a
skip with the reason, not silently ignored.

---

## What to record

- The Docker version, image, and whether the default user was root.
- Discovery time for the 50-container check.
- Which environments were exercised (Docker Desktop, rootless Docker, a real second engine host)
  and which were not.
- Any known failures, with the exact command and error, in `test/KNOWN-FAILURES.md` rather than
  hidden.
