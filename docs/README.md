# RDEV: remote development for Emacs

RDEV edits files, runs processes and drives tools on a remote Linux host through one
persistent SSH connection that carries JSON-RPC 2.0. A remote file is an ordinary Emacs file
name: `/rdev:HOST:/path/to/file`. `find-file`, `save-buffer`, Dired, `project.el`, `compile`,
`shell`, Eglot, Magit and Dape see a regular Emacs file name and work on it.

Requirements: Emacs 30.1 or later on the client; `ssh` on the client; Python 3.8 or later on the
remote (standard library only). No root access and no system-wide install on either side.

## Quick start

```elisp
(add-to-list 'load-path "~/path/to/emacs-remote-dev")
(require 'rdev)
```

Then `M-x rdev-find-file RET myhost RET`, or `C-x C-f /rdev:myhost:~/project/ RET`.
`HOST` is whatever `ssh HOST` accepts (including `~/.ssh/config` aliases). Authentication,
keys, agents and host-key checking are done by your `ssh`; RDEV stores no credentials.
The agent is installed into the remote user's home on first connect, with its hash verified,
and needs no further steps.

## Docker container targets

A running Docker container is another remote target. It uses the same
`/rdev:HOST:/path` names, the same agent and the same file and process handlers; the transport is
one persistent `docker exec -i` instead of `ssh`. Configure a **container target** (also called a
Docker target):

```elisp
(setq rdev-hosts
      '(("demo" . (:transport docker
                   :container "rdev-demo"   ; defaults to the entry's key
                   :docker-user "dev"))))   ; optional; defaults to the image user
```

Then `M-x rdev-find-file RET demo RET`, or open `/rdev:demo:/workspace/hello.txt`. The container
must be running; `M-x rdev-docker-list` lists running containers and
`M-x rdev-docker-connect` completes over them.

You do not have to configure a target first: any running container is reachable by its explicit
address, `/rdev:docker+NAME:/path` on the local engine or `/rdev:docker+NAME@ssh-dest:/path` on an
engine you reach over SSH. In `C-x C-f`, typing `/rdev:` completes the host part over configured
targets, ssh-config hosts and running containers (offered as `docker+NAME`), so you can pick a
container without remembering its name. Discovery runs in the background and completion never
waits on a slow daemon; a container started a moment ago appears on the next TAB. A plain name
such as `/rdev:my-container:` is always SSH, so a container can never take over a host name. Set
`rdev-docker-auto-detect` to nil to stop listing local containers in completion.

The helper is installed under the container user's `$HOME/.cache/rdev` (falling back to
`/tmp/rdev-<uid>` when `HOME` is unusable), verified by size and SHA-256, and no packages are
installed.

A container whose only account is root is refused by default. Add `:allow-root t` to that target
(or set `rdev-docker-allow-root` to t for every Docker target) only if you accept that the helper
runs with container-root privileges; every connection then warns and records it in the log (see
`security.md`).

### Containers on a remote Docker engine

Set `:docker-host` to an SSH destination to run the Docker CLI there through your existing SSH
configuration:

```elisp
(setq rdev-hosts
      '(("remote-demo" . (:transport docker
                          :container "rdev-demo"
                          :docker-host "dev-server"))))
```

Local and remote containers with the same name are independent sessions. An unreachable SSH host
reports `rdev-ssh-error`; a Docker/daemon failure reports `rdev-docker-error` with a reason
(`not-found`, `not-running`, `permission`, `engine-unreachable`, `unsupported`, `root-refused`,
`bootstrap`). `:docker-program` overrides the `docker` executable on the engine host.

## Commands

| Command | Does |
|---|---|
| `rdev-find-file` | prompt for a host and open a file or directory on it |
| `rdev-docker-list` | list running containers on the configured Docker engines |
| `rdev-docker-connect` | connect to a running container (completion over names) |
| `rdev-shell` | interactive shell on the host (pty) |
| `rdev-status` / `rdev-list-connections` | connection state, one row per host, with reconnect and log actions |
| `rdev-reconnect`, `rdev-disconnect`, `rdev-restart-server` | manage a connection |
| `rdev-show-logs` | per-connection log (credentials and tokens are redacted) |
| `rdev-clear-cache`, `rdev-cache-inspect` | drop or inspect cached file metadata |
| `rdev-grep`, `rdev-consult-grep` | search a remote tree on the host (`rg` when present, else a built-in walk) |
| `rdev-project-clear-cache` | forget cached project roots and file lists |
| `rdev-notify-enable-auto-revert` | opt in: revert buffers when the remote file changes |

The mode line shows the connection state of the current host.

## Behavior to know about

- **Saves are safe.** A save writes a temporary file and renames it. If the file changed on
  the remote since you opened it, the save is refused with `rdev-conflict`
  (`rdev-conflict-functions` decides how you are asked); your edits stay in the buffer.
- **Connection loss never discards edits.** RDEV reconnects with backoff
  (`rdev-reconnect*` options). Idempotent reads retry; `exec/run` and `proc/spawn` are never
  replayed. Processes that were running are reported as interrupted.
- **Emacs file APIs are synchronous.** A `file-exists-p` costs at least one round trip while
  the answer is not cached. RDEV shortens that with a metadata cache (`rdev-cache-ttl`),
  batching and prefetch, but cannot remove it. See `blocking.md`.
- **Large files** are transferred in `rdev-chunk-size` pieces with bounded memory.
- **Remote processes** (`make-process` with `:file-handler t`, `process-file`, `compile`,
  `shell`) run through the agent. Output is flow controlled; a stalled Emacs stalls the child
  instead of growing memory.
- **Optional tools** (`rg`, git, Eglot servers, `debugpy`) are never required for editing.
  When one is missing you get a message that names it.

## Customization

All options live in the `rdev` group (`M-x customize-group RET rdev`). The ones most people
touch: `rdev-hosts`, `rdev-ssh-args`, `rdev-python`, `rdev-timeout`, `rdev-cache-ttl`,
`rdev-chunk-size`, `rdev-reconnect`, `rdev-project-markers`, `rdev-search-max-results`.
`rdev-allow-insecure-tcp` is off and must stay off unless you understand `security.md`.

## Troubleshooting

| Symptom | Check |
|---|---|
| "ssh: connection failed" at first connect | Run `ssh HOST true` in a terminal; RDEV uses the same `ssh` and the same config. Extra options go in `rdev-ssh-args`. |
| "python not found" / version error | The remote needs Python 3.8+. Set `rdev-python` to an explicit path (for example `python3.11`). |
| Mode line shows `reconnecting` | The link dropped. RDEV retries with backoff; `M-x rdev-reconnect` forces an attempt and `M-x rdev-show-logs` shows why it fails. Unsaved buffers are untouched. |
| Save refused with `rdev-conflict` | The file changed on the remote after you opened it. Compare, then revert or save again as `rdev-conflict-functions` offers. |
| Stale directory listing or file state | `M-x rdev-clear-cache`; inspect with `M-x rdev-cache-inspect`. Lower `rdev-cache-ttl` for fast-changing trees. |
| Eglot "Server died" | The language server is not installed on the remote, or is not on its `PATH`. The message names the command; install it on the host. |
| Agent seems outdated or wedged | `M-x rdev-restart-server`. The agent is re-installed and its hash re-checked. |

When reporting a problem, attach `M-x rdev-show-logs` output. Credentials and tokens are redacted.

## TCP transport and ssh tunnels

SSH is the only transport enabled by default. The agent can also run as a long-lived daemon
(`rdev-server.py --listen HOST:PORT --token-file FILE`), which is meant for tunnelling
(`ssh -L LOCAL:127.0.0.1:REMOTE HOST`) and for tests, never for direct exposure. It listens on
loopback and every client must present the token. Listening on a non-loopback address needs
`--allow-non-loopback` and prints a warning, because the traffic is then unencrypted. On the
client, `rdev-allow-insecure-tcp` is off and must stay off unless you understand `security.md`.
Tools that need a second port (the Dape debug adapter socket, for example) are reached through
an `ssh -L` tunnel you start yourself; see `dape.md`.

## Integrations

| Tool | Notes |
|---|---|
| Dired, `project.el`, `compile`, `shell` | work as on a local directory |
| Magit | uses the remote `git` through RDEV process handlers |
| Eglot | server runs on the host; a missing server reports "Server died" with the command |
| Dape | the adapter runs on the host; the DAP socket needs an `ssh -L` tunnel, see `dape.md` |

## Further reading

`protocol.md` (wire protocol and limits), `connections.md` (states and reconnect),
`security.md`, `blocking.md` (what blocks and for how long), `dape.md`, `audit.md`,
and `DEVELOPING.md` for contributors.
