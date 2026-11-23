# RDEV (emacs-remote-dev)

Emacs remote-development package: file-name handler `/rdev:HOST:/path`, JSON-RPC 2.0 over one
persistent SSH connection, Python agent on the remote.

- Governing rules: `.specify/memory/constitution.md` (read before changing behavior).
- Current feature spec/plan/tasks: `specs/001-rdev-modernization/` (plan.md first).
- Contributor guide and test commands: `docs/DEVELOPING.md`; `make check` runs the local gates.
- Layout: `rdev*.el` and the two `rdev-*.py` live at the repo root (the client finds the agent
  next to `rdev.el`); `test/` (ERT, Python, `e2e/`), `bench/`, `docs/`, `specs/`.
- Do not commit unless asked. Do not weaken the agent's refusal to run as root.
