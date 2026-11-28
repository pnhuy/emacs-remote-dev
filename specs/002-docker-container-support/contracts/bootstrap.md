# Contract: In-Container Bootstrap and Root Policy

**Feature**: `002-docker-container-support` | **Version**: 1.0 | **Date**: 2026-11-28

This contract covers how RDEV installs and starts its helper inside a running container. It reuses
the SSH bootstrap markers and verification rules; only the process wrapper and the root opt-in are
new.

---

## 1. Process shape

**Local engine**:

```text
docker exec -i <container> sh -c '<bootstrap>'
```

**Remote engine**:

```text
ssh <rdev-ssh-args> -- <docker-host> docker exec -i <container> sh -c '<bootstrap>'
```

Rules:
- No `-t`: the stream carries `Content-Length`-framed JSON-RPC.
- `<container>` is validated (name or ID charset) and separated from options; no user string is
  interpolated unquoted.
- `:docker-user` adds `--user <user>` before the container name.
- The `docker` executable is `:docker-program` or `rdev-docker-program`.
- The bootstrap is one shell-quoted argument.

---

## 2. Bootstrap protocol (unchanged markers)

The client sends the agent script only after the remote side reports that it is needed.

| Marker | Meaning | Client action |
|---|---|---|
| `RDEV-BOOT ok` | a verified helper already exists | send nothing; wait for `RDEV-READY` |
| `RDEV-BOOT need` | no verified helper | send the script bytes once |
| `RDEV-ERR <message>` | bootstrap failed | close the process; map to `rdev-docker-error` |
| `RDEV-READY` | the agent is starting on stdio | hand the stream to the JSON-RPC layer |

The agent is then executed as:

```text
python3 -u <helper> --stdio [--allow-root]
```

The `hello` exchange, capability negotiation and protocol-major check are unchanged.

---

## 3. Installation

- Directory: `${HOME}/.cache/rdev` with mode 0700, or `/tmp/rdev-<uid>/rdev` with mode 0700 when
  `HOME` is unset, empty, or not writable. The fallback is used only when the exec user owns both
  `/tmp/rdev-<uid>` and its `rdev` subdirectory and neither is a symlink; otherwise the bootstrap
  fails with `RDEV-ERR no writable directory ...` (`unsupported`).
- File: `rdev-server-<sha256-prefix>.py`, mode 0700, owned by the `docker exec` user.
- Verification: exact byte size and SHA-256 before execution.
- Atomicity: write to a temporary file in the same directory, verify, `mv` into place; remove the
  temporary file on any failure.
- No package installation, no `sudo`, no system-wide path, no change to unrelated container files.
- A read-only or unwritable location is an `unsupported` error naming the path and a remedy.

---

## 4. Root policy

The effective UID is determined before installing the helper (probe or inspection).

| Effective UID | Opt-in (`:allow-root` or `rdev-docker-allow-root`) | Contract |
|---|---|---|
| non-zero | either | Install and run normally. |
| 0 | off | Do not install. Signal `rdev-docker-error` reason `root-refused` with the remedies: use an unprivileged account, set `:docker-user`, or enable the opt-in. |
| 0 | on | Install and run with `--allow-root`; show a warning on every connection; log the elevated privilege. |
| unknown | either | Do not install. Signal `unsupported`; never guess. |

Agent CLI:

- The default remains: if `os.geteuid() == 0`, write `RDEV-ERR refusing to run as root ...` and
  exit 5.
- The opt-in is the per-target `:allow-root` or the global `rdev-docker-allow-root`; both are off
  by default. `--allow-root` is the only override. It is accepted only on the command line, never through
  RPC, environment variables or configuration files.
- The flag does not change any other behavior; all file and process operations still run as the
  container account.

Security notes:
- The opt-in is per target and is never inherited.
- The warning is emitted on every connect, not only the first.
- The exception, rationale, risk and remediation are recorded in `spec.md` and `plan.md`.
- Negative tests cover the default refusal; positive tests cover the opted-in path.

---

## 5. Failure mapping

| Bootstrap condition | Reason |
|---|---|
| container missing | `not-found` |
| container stopped/paused | `not-running` |
| `docker`/daemon missing or SSH host unreachable | `engine-unreachable` |
| permission denied by Docker or the container | `permission` |
| no `sh`, no Python ≥ 3.8, unusable home | `unsupported` |
| size/hash mismatch, upload truncation, temp-file failure | `bootstrap` |
| root without opt-in | `root-refused` |

A failed bootstrap leaves no helper file and does not stop or modify the container.

---

## 6. Compatibility

- The agent script content, markers, protocol and methods are unchanged; only the wrapper and the
  optional flag differ from SSH.
- An older cached helper is replaced by the verified current script, as today.
- The helper version is reported in `hello`; an incompatible protocol major is rejected with an
  actionable error.
