# Debugging remote programs with Dape

Dape (optional, `M-x package-install RET dape`) drives a Debug Adapter Protocol adapter that
runs **on the remote host**, started through rdev's `make-process`, while Emacs stays local.
Verified by `test/e2e/dape.el` against `debugpy` 1.8+ on Linux (Dape 0.28, Emacs 31 client).

## Recipe (Python / debugpy)

1. On the remote: `python3 -m venv ~/dbg && ~/dbg/bin/pip install debugpy`.
2. Open a remote file (`/rdev:HOST:/path/prog.py`), set a breakpoint (`dape-breakpoint-toggle`).
3. Reach the adapter port.  rdev does not forward ports, so open a tunnel yourself
   (any free port P):

       ssh -N -L P:127.0.0.1:P HOST

4. Start the session with an explicit config (`M-x dape`, or `(dape CONFIG)`):

       (dape '(modes (python-mode)
               command "/home/me/dbg/bin/python"
               command-args ("-m" "debugpy.adapter" "--host" "127.0.0.1" "--port" "P")
               command-cwd "/rdev:HOST:/home/me/proj/"
               port P  host "localhost"
               prefix-local "/rdev:HOST:"  prefix-remote ""
               :request "launch" :type "python"
               :cwd "/home/me/proj"  :program "/home/me/proj/prog.py"
               :console "internalConsole" :justMyCode :json-false))

Notes:
- `:cwd` and `:program` are paths **as the remote sees them** (no `/rdev:` prefix);
  `prefix-local`/`prefix-remote` let Dape map adapter-reported paths back to `/rdev:` buffers.
- `command-cwd` must be an `/rdev:` directory so the adapter is launched on the remote.
- Debuggee output arrives in `*dape-repl*`; with `:console "integratedTerminal"` Dape would need
  the adapter's `runInTerminal` request, which is not tested here.  Debuggee stdin is not
  covered.
- Dape's built-in `debugpy` config binds `0.0.0.0`; prefer `127.0.0.1` plus the tunnel so
  the DAP port is never exposed (Article IV).

## What is verified

| Behavior | Test |
|---|---|
| Breakpoint hit; stack-frame path maps to the `/rdev:` file name | `e2e-dape-breakpoint-hit-with-path-mapping` |
| Working directory and stdout of the debuggee; adapter gone after exit | `e2e-dape-cwd-output-and-termination` |
| `dape-quit` kills the remote adapter | `e2e-dape-quit-kills-remote-adapter` |
| Connection loss ends the session without hanging; rdev reconnects afterwards | `e2e-dape-connection-loss-ends-session-and-recovers` |
| Missing executable gives a clear message | `e2e-dape-missing-adapter-is-actionable` |

No rdev code change was needed for Dape (T103): the existing `make-process`, file-name and
`executable-find` handlers were sufficient.  Fixture: `test/e2e/dape-fixture.sh` (or the test
creates `/tmp/rdev-dape-venv` itself); tests skip visibly if dape or debugpy is unavailable.

## Limitations

- No automatic port forwarding (manual `ssh -L`; the test automates it).
- Attach-mode and multi-session debugging are not tested.
- Not run: macOS remote host, Windows.
