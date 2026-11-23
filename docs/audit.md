# RDEV file-operation audit (T014, baseline of the unmodified client)

Source of truth for what each handler does today versus native Emacs. "Native" means the
same call on a local directory tree (twin-tree tests in `test/rdev-handlers-*-test.el`).
Every row is backed by a passing test unless marked otherwise.

## Coverage

53 operations are registered in `rdev--ops` (`test/rdev-handlers-coverage-test.el` fails if
that set changes without this table changing).

- **Remote-backed (46):** file predicates/attributes, directory-files(-and-attributes),
  completion, make/delete-directory, insert-directory, insert-file-contents,
  file-local-copy, write-region, delete/copy/rename-file, set-file-modes/times,
  symlink/hard-link creation, process-file, make-process, start-file-process,
  shell-command, exec-path, temporary-file-directory, file-system-info, file-truename.
- **No-op stubs (7):** `file-acl`, `set-file-acl`, `file-selinux-context`,
  `set-file-selinux-context`, `lock-file`, `unlock-file`, `file-locked-p`.
  `file-notify-add-watch` signals an error (documented gap; watch support is M3).

## Documented differences from native Emacs

| # | Operation | rdev behavior | Native behavior | Test |
|---|---|---|---|---|
| 1 | `file-writable-p` on a dangling symlink | differs | see test | `rdev-attrs-documented-difference-writable-dangling` |
| 2 | `directory-files` with COUNT | first N of the *sorted* list | first N in readdir order, then sorted (filesystem-dependent) | `rdev-dir-directory-files-matches-native` compares length only |
| 3 | Attribute cache (`rdev-cache-ttl`, default 2 s) | positive **and negative** results are cached until TTL; own mutations invalidate | none | `rdev-cache-*` |
| 4 | Locking | `lock-file`/`unlock-file`/`file-locked-p` are no-ops | lock files | `rdev-coverage-noop-stubs-are-inert` |
| 5 | `write-region` | in-place truncate, no conflict detection (D-03) | in-place, no conflict detection | `test_d03_*` (expected failure) |
| 6 | `tramp-ignored-file-name-regexp` | rdev adds an alternative to the user's value (nil -> `\\`/rdev:`) and never replaces it | n/a | `rdev-tramp-ignore-preserves-user-regexp` |
| 7 | Interactive process on a pty | no output observed under batch Emacs (unconfirmed) | works | `rdev-proc-start-file-process-pty-stdin` (expected failure) |

## Error mapping (`rdev--signal-error`)

ENOENT → `file-missing`; EEXIST → `file-already-exists`; EACCES/EPERM → `permission-denied`;
anything else, or no errno → `file-error`. Covered by `test/rdev-errors-test.el`.
Note that SSH, transport, agent and remote-process failures are not yet distinguishable
(FR-040), which is later work.

## Not covered by any test yet

Large-file memory behavior, concurrent writers, `file-notify`, cache size bound (D-15).
