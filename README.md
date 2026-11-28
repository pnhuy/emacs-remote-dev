# emacs-remote-dev (RDEV)

Remote development for Emacs, in the style of VS Code Remote-SSH, built on Emacs's own file
and process APIs. A remote file is an ordinary file name, `/rdev:HOST:/path/to/file`, so
`find-file`, `save-buffer`, Dired, `project.el`, `compile`, `shell`, Eglot, Magit and Dape work on
it without special modes. One persistent SSH connection carries JSON-RPC 2.0 to a small Python
agent that RDEV installs on the host for you.

```
Emacs ── jsonrpc.el ── ssh (stdio) ── rdev-server.py   (agent on the remote, Python stdlib only)
   └── rdev-relay.py   gives Emacs a real local subprocess (pty, signals) for a remote process
```

## Requirements

- Client: Emacs 30.1 or later, `ssh`. Developed and tested on Emacs 30.2 and 31.1.
- Remote: Linux with Python 3.8 or later (standard library only). No root, no system install.
  The agent refuses to run as root.
- Optional: Docker 20.10 or later for container targets. Containers need `sh` and Python 3.8+
  and are reached through `docker exec`; no port is published and no package is installed.
- Optional, never required for editing: `rg`, `git`, language servers (`pylsp`, `clangd`), `debugpy`.

## Install

```elisp
(add-to-list 'load-path "~/path/to/emacs-remote-dev")
(require 'rdev)
```

Keep the `.py` files next to `rdev.el`; the client finds the agent there.

## Use

`M-x rdev-find-file RET myhost RET`, or `C-x C-f /rdev:myhost:~/project/ RET`.
`HOST` is whatever `ssh HOST` accepts, including `~/.ssh/config` aliases. Authentication, keys,
agents and host-key checking are all done by your `ssh`; RDEV stores no credentials.

Useful commands: `rdev-shell`, `rdev-status`, `rdev-reconnect`, `rdev-restart-server`,
`rdev-show-logs`, `rdev-grep`, `rdev-clear-cache`. Full list, options and troubleshooting:
[docs/README.md](docs/README.md).

A running Docker container is another target (a **container target**, also called a Docker
target):

```elisp
(setq rdev-hosts
      '(("demo" . (:transport docker :container "rdev-demo" :docker-user "dev"))))
```

Then `/rdev:demo:/workspace/hello.txt` works like any other remote file. Without any
configuration, `/rdev:docker+NAME:/path` opens a file in the running container NAME, and `/rdev:`
completion offers running containers under those keys.
`M-x rdev-docker-list` lists running containers and `M-x rdev-docker-connect` completes over
them. A root-only container is refused unless that target sets `:allow-root t` or you set
`rdev-docker-allow-root` globally (see [docs/security.md](docs/security.md)). `:docker-host "ssh-dest"` reaches an engine on another
machine through your existing SSH configuration.

## What it guarantees

- **Saves are safe**: write to a temp file and rename; refuse with `rdev-conflict` if the remote
  file changed since you read it. Edits stay in the buffer.
- **Connection loss never discards edits**: reconnect with backoff; reads retry,
  `exec/run` and `proc/spawn` are never replayed.
- **Bounded resources**: large files move in chunks (500 MiB round trip: agent peak 40 MiB),
  process output is flow controlled.
- **Security**: SSH only by default, per-session relay token, restrictive socket permissions,
  bounded and validated requests. See [docs/security.md](docs/security.md).
- **Coexists with TRAMP**: it adds to `tramp-ignored-file-name-regexp`, never replaces it.

Emacs file APIs are synchronous, so an uncached `file-exists-p` costs a round trip. RDEV caches
and batches but cannot remove that; see [docs/blocking.md](docs/blocking.md).

## Layout

| Path | Contents |
|---|---|
| `rdev.el` | client: file-name handlers, connections, process handlers |
| `rdev-docker.el` | Docker transport: inspect/discovery, `docker exec` process, root policy |
| `rdev-state.el` `rdev-ui.el` `rdev-project.el` `rdev-search.el` `rdev-notify.el` | state machine and keepalive, UI, project.el backend, remote grep, change notifications |
| `rdev-bench.el` | benchmark driver (RDEV vs TRAMP) |
| `rdev-server.py` `rdev-relay.py` | remote agent and local relay |
| `docs/` | user and protocol documentation, `DEVELOPING.md` for contributors |
| `test/` | ERT and Python unit tests, `test/e2e/` real Emacs and real ssh scenarios |
| `bench/` | benchmark scripts, delay proxy, recorded results |
| `specs/`, `.specify/` | Spec Kit feature spec, plan, tasks and the project constitution |

## Develop

```sh
make check                                   # ERT + Python tests, quality gate, portability lint
make e2e S=baseline                          # end-to-end against a throwaway local sshd
make e2e S=docker                            # end-to-end against disposable containers
make e2e S=workflow RDEV_TEST_SSH_TARGET=myhost
make bench HOST=myhost OUT=out.csv PROFILES="rtt50 slow1mbit"
```

See [docs/DEVELOPING.md](docs/DEVELOPING.md) for the rules (compatibility, data integrity,
regression test for every fix) and [test/MILESTONE-REPORT.md](test/MILESTONE-REPORT.md) for
what has and has not been verified. Not yet run: Windows, a macOS remote host, Emacs 30.1, a
timed fresh-user walk-through.

## Status

Version 0.1.0, pre-release. License: [MIT](LICENSE).
