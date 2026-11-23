# Baseline (characterization) — status: history from the original ~/.emacs.d repo (commit 09d740f); this repo starts from that state

Written 2026-11-22 against the unmodified `*` (agent sha256 pinned in
`test/fixtures/legacy-server.sha256`: 5cf56414…1627).

## Results

- Python: 39 tests, 8 expected failures, 0 unexpected.
- Emacs (ERT): 73 tests, 9 expected failures, 0 unexpected.
- E2E over real ssh (`test/e2e/baseline.el`): 8/8 on devbox, 8/8 on a local sshd fixture.
- Platforms: see `test/emacs-matrix.md` and `test/e2e/PLATFORMS.md`.

## Gate status

`` was un-ignored and committed as 09d740f (agent sha256 matches the pin above).
By the owner's decision `test/`, `docs/` and `bench/` stay git-ignored, so the
characterization tests are **not in git history**; they exist only in the working tree.
Fix tasks therefore cannot show a red-to-green test diff in git.

## Corrections to the plan found while writing the baseline

- **D-07 is not a behavioral defect** (both exit-code paths yield 128 + sig and both carry
  `signal`); see `test/KNOWN-FAILURES.md`.
- `~/.cache/rdev` on devbox already held the current agent, so the E2E runs there used
  the `RDEV-OK` path; the first-time deploy path was **not** exercised remotely.
