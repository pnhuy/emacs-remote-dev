# Emacs versions actually run

Each line is appended by `test/emacs-matrix.sh`. A version not listed here has NOT been run.


## Baseline (pre-fix) runs — 2026-11-22, `test/run-all.sh` on the unmodified agent/client

| Host | OS | Emacs | Python | Python tests | Emacs tests | Result |
|---|---|---|---|---|---|---|
| local | macOS (Darwin 25.6) | 31.1 | 3.9.6 | 39 run, 8 expected failures | 73 run, 9 expected failures, 0 unexpected | PASS |
| devbox | Linux 7.2 (Fedora 44) | 30.2 | 3.14.8 | 39 run, 8 expected failures | 73 run, 9 expected failures, 0 unexpected | PASS |
| devbox | Linux 7.2 (Fedora 44) | 30.2 | 3.8.20 (pyenv) | 39 run, 8 expected failures | 73 run, 9 expected failures, 0 unexpected | PASS |
| devbox | Linux 7.2 (Fedora 44) | 30.2 | 3.12.11 (pyenv) | 39 run, 8 expected failures | 73 run, 9 expected failures, 0 unexpected | PASS |

Not run: Emacs 30.1 (no such binary available; 30.2 is the nearest), Emacs snapshot, Python
3.10 and 3.11 (installed on devbox via pyenv but not executed), Windows. The `python3.8`
shim on devbox is broken (`pyenv: python3.8: command not found`); 3.8.20 was run by its
absolute path `~/.pyenv/versions/3.8.20/bin/python3`.

Scope: these runs use the local `--stdio` agent (no ssh hop). Real-sshd coverage is T031.
