# Documentation walk-through validation (T112, SC-014)

Date: 2026-11-23. Done by the implementer (not an independent fresh user).

## What was actually done

- **README quick start** (`README.md`): the two-line `load-path` + `require` setup and
  `rdev-find-file` / `C-x C-f /rdev:HOST:/path` were exercised in `emacs -Q` sessions against
  the throwaway local sshd and against `devbox` by the E2E suites (`baseline`, `workflow`,
  `dired`, `compile`, `pty`). Agent auto-install on first connect happened in every run.
- **Contributor commands** (`DEVELOPING.md`): `sh test/run-all.sh`, `sh test/check-quality.sh`,
  `sh test/e2e/run.sh SCENARIO` and `RDEV_TEST_SSH_TARGET=devbox sh test/e2e/run.sh SCENARIO`
  were run as written; results are in `specs/001-rdev-modernization/quickstart-results.md`.
- Corrections found while checking the text against the code: Python minimum stated as 3.9
  (it is 3.8); the TCP section named a client option instead of the agent flags
  (`--listen`, `--token-file`, `--allow-non-loopback`). Both fixed.

## What was not done

- **No timed run by a fresh user.** The "15 minutes" criterion of SC-014 is **not verified**.
  The mechanical steps (load, connect, open, save) take well under a minute on a host where
  `ssh HOST` already works; the unmeasured part is a person reading the guide.
- No Windows client, no macOS remote host, no Emacs 30.1 (only 30.2 and 31.1 were used).

## Follow-up

Have someone who has not seen the project follow `README.md` with a stopwatch and record the
time and every point of confusion here.
