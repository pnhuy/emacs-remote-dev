# RDEV security model

## Trust boundaries
- **SSH is the transport and the authenticator.** RDEV uses your `ssh` command, keys, agent and
  `known_hosts` as-is. It never stores passwords or manages keys (Article IV).
- The **agent runs as your remote user** and refuses to run as root (exit 5). It can do exactly
  what that account can do, nothing more.
- The local **relay socket** lives in a 0700 directory (`$XDG_RUNTIME_DIR/rdev` or
  `~/.cache/rdev/run`) and is itself 0600, so other local users cannot connect. Emacs Lisp cannot
  read a peer's uid, so the Lisp side relies on directory ownership plus modes and on a
  per-session token: Emacs passes 16 random bytes (hex) to each relay in `RDEV_RELAY_TOKEN`
  (removed from the relay's environment at start), the relay sends it as a fourth field of
  its `H` hello frame, and Emacs aborts any socket whose hello lacks the right token. The relay
  itself checks (`SO_PEERCRED` / `LOCAL_PEERCRED`) that the socket server runs as its own uid
  and exits 255 otherwise. The cross-uid refusal is covered by a unit test with a patched
  uid; it was not exercised with a real second user.
- The JSON-RPC input is validated: bounded headers/messages, typed parameters, no NUL in paths,
  commands as argv (never through a shell unless you ask for `shell-command`).

## Docker container targets

A Docker target keeps the same model: the transport is one `docker exec -i` whose stdin/stdout
carry the JSON-RPC stream. There is **no new listening socket or published port**, no Docker or
registry credential is read or stored, and the developer's existing Docker and SSH permissions
apply. Commands are passed as argv, container names are validated against the Docker charset, and
the remote `sh -c` payload is quoted with `--` separators. The UID probe and the transport
address the container by the immutable ID that `docker inspect` just returned, not by name, so a
container recreated under the same name in between cannot receive the session.

The helper is installed under `$HOME/.cache/rdev`. When `HOME` is unusable it falls back to
`/tmp/rdev-<uid>/rdev`, but only if the connecting account owns both directories and neither is a
symlink; a directory planted there by another account is refused (`unsupported`) instead of used.

The helper runs as an unprivileged container account by default. The agent still refuses uid 0
(exit 5). A container whose only account is root is refused with `root-refused` and the three
remedies (use an unprivileged account, set `:docker-user`, or enable the opt-in). The opt-in is
off by default and can be set per target (`:allow-root t`) or globally
(`rdev-docker-allow-root`); it is the only documented exception to the
default refusal:

- Every connection to a root container with the opt-in active calls `display-warning` and writes
  `helper runs with container-root privileges` to the redacted log.
- The Emacs client passes the agent's `--allow-root` flag **only** when the effective opt-in is
  active (per target or global). The flag is command-line only: it is never read from an
  environment variable, a configuration file or RPC, so an ordinary SSH or TCP deployment cannot
  become root by accident.
- The global option is broader: use it only on a machine where every container you may connect to
  is trusted. Per-target `:allow-root` remains the narrower choice. An explicit `:allow-root nil`
  opts a target out even when the global default is on.
- A refused connection installs nothing: no helper file, no partial upload, no transport process.

Treat container root as host-equivalent when the container mounts host paths or the Docker socket;
the opt-in is for development containers that genuinely have no other account.

## Recommended TCP setup: tunnel over SSH
The agent's `--listen` mode exists for tests and special setups. It binds loopback only and
refuses anything else unless `--allow-non-loopback` is given (the traffic is then plaintext and
every connect warns). Prefer a tunnel:

```sh
# on your machine: forward a local port to the agent listening on the remote loopback
ssh -N -L 7777:127.0.0.1:7777 user@host &
# on the remote host (started by you, as yourself):
python3 rdev-server.py --listen 127.0.0.1:7777 --token-file ~/.rdev/token
```

Then connect with the token from `~/.rdev/token`. Use `--token-file` (or `RDEV_TOKEN`), not
`--token`: argv is visible in the process list and the agent warns about it. Five failed
authentications close the connection, and failures are counted process-wide: once the budget is
spent, further failed attempts (including after reconnecting) are slowed. Generated tokens are
256-bit, stored in a 0600 file; a user-supplied token shorter than 16 characters is accepted but
the agent warns that it is weak. Tokens are never written to logs, `rdev-status` or messages.

## What is logged
Connection transitions and agent stderr go to the per-connection log buffer. Values of
environment variables whose names look sensitive (token, secret, password, key) and token
strings are redacted before they are written.

## Known limits
- Same-uid processes on a machine can reach that uid's relay socket and agent; RDEV does not
  defend against an attacker who already runs as you.
- Emacs cannot verify the peer uid of a relay connection (no Lisp API); the token above stands in.
- Plain `--allow-non-loopback` exposes an unencrypted channel by design of that opt-in.
