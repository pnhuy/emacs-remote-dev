;;; rdev.el --- VS Code-style remote development for Emacs  -*- lexical-binding: t; -*-

;; Author: Huy Pham
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: comm, files, processes, tools
;; URL: https://github.com/pnhuy/emacs-remote-dev

;;; Commentary:

;; rdev is a client/server alternative to TRAMP.  A small headless server
;; (rdev-server.py, Python stdlib only) runs on the remote machine and
;; Emacs talks JSON-RPC to it over ONE persistent, multiplexed channel:
;;
;;   Emacs ── jsonrpc.el ──[ssh stdio | TCP+token]── rdev-server.py
;;     │                                                 ├─ fs/*   (stat, read, write, readdir ...)
;;     │ file-name-handler "/rdev:HOST:/path"             ├─ exec/run  (process-file)
;;     │                                                 └─ proc/*  (streaming pipes / PTYs)
;;     └─ rdev-relay.py (local stand-in per remote process, gives real
;;        exit codes / signals to eglot, compile, shell, magit ...)
;;
;; Unlike TRAMP there is no shell parsing: every operation is one typed
;; RPC (~0.3 ms on a LAN), processes stream concurrently over the same
;; connection, and the server is auto-deployed (hash-versioned) on first
;; connect, like VS Code's server.
;;
;; Usage:  C-x C-f /rdev:devbox:~/project/file.py
;;         M-x rdev-find-file / rdev-shell / rdev-status / rdev-disconnect

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)
(require 'subr-x)
(require 'rdev-state)

(defgroup rdev nil
  "Client/server remote development."
  :group 'files
  :prefix "rdev-")

(defcustom rdev-hosts nil
  "Per-host connection settings, an alist of (HOST . PLIST).
PLIST keys:
  :transport  `ssh' (default), `tcp', or `docker'
  :ssh-host   ssh destination (defaults to HOST)
  :address    TCP address (defaults to HOST)
  :port       TCP port
  :token      TCP auth token, or :token-file FILE
  :tls        non-nil to wrap TCP in TLS
  :insecure-ok non-nil to allow plaintext TCP to a non-loopback address
              (see also `rdev-allow-insecure-tcp')
Docker targets instead use:
  :container  container name or ID (defaults to HOST)
  :docker-host SSH destination of the engine host (nil = local engine)
  :docker-user container account for `docker exec --user'
  :docker-program Docker executable (defaults to `rdev-docker-program')
  :allow-root non-nil to allow a root-only container (documented
              exception; warns and logs on every connection)"
  :type '(alist :key-type string :value-type plist))

(defcustom rdev-allow-insecure-tcp nil
  "When non-nil, allow plaintext TCP connections to non-loopback addresses.
Tokens and file contents then cross the network unencrypted.  Prefer the
ssh transport or `:tls t'; per-host override: `:insecure-ok t'."
  :type 'boolean)

(defcustom rdev-ssh-args '("-T" "-o" "BatchMode=yes" "-o" "ServerAliveInterval=15")
  "Extra arguments given to ssh when bootstrapping a server."
  :type '(repeat string))

(defcustom rdev-docker-program "docker"
  "Docker executable used for :transport `docker' targets.
May be overridden per target with :docker-program; on a remote engine it is
a path on the engine host."
  :type 'string)

(defcustom rdev-docker-discovery-ttl 5
  "Seconds a `docker ps' discovery snapshot stays fresh."
  :type 'number)

(defcustom rdev-docker-discovery-max 200
  "Maximum number of containers listed by discovery and completion."
  :type 'natnum)

(defcustom rdev-docker-timeout 30
  "Seconds to wait for one Docker CLI call (inspect, ps)."
  :type 'integer)

(defcustom rdev-docker-probe-timeout 10
  "Seconds for the in-container environment probe.
The root-policy and shell/Python probes use this short bound so an
unsupported container is reported quickly, independently of
`rdev-docker-timeout'."
  :type 'integer)

(defcustom rdev-docker-auto-detect t
  "Non-nil to offer running local containers in `/rdev:' host completion.
Containers are offered under explicit `docker+NAME' keys, so choosing one
is always a deliberate Docker choice: a plain host name is never resolved
to a container, whatever is running.  Discovery runs in the background and
completion never waits longer than `rdev-docker-discovery-wait'.  Set this
to nil to stop querying the local engine; containers on the engines of
configured Docker targets are still offered."
  :type 'boolean)

(defcustom rdev-docker-auto-detect-timeout 2
  "Seconds allowed for one background discovery `docker ps'.
A lookup that takes longer is killed and counts as a failure (see
`rdev-docker-discovery-backoff')."
  :type 'number)

(defcustom rdev-docker-discovery-wait 0.3
  "Seconds completion may wait for discovery when it has no snapshot yet.
Only the call that starts a lookup waits, and only this long; later calls
use whatever snapshot exists, so a slow or hung engine never stalls
completion."
  :type 'number)

(defcustom rdev-docker-discovery-backoff 30
  "Seconds before a failed background discovery is retried for that engine."
  :type 'number)

(defcustom rdev-docker-allow-root nil
  "Non-nil to allow the helper to run as root in every Docker target.
This is the global default for targets that do not set :allow-root; a
target's :allow-root t still enables it when the global default is nil.
Off by default.  Every connection to a root container warns and logs the
elevated privilege.  Treat container root as host-equivalent when the
container mounts host paths or the Docker socket."
  :type 'boolean)

(defcustom rdev-python "python3"
  "Local Python used to run the process relay."
  :type 'string)

(defcustom rdev-cache-ttl 2.0
  "Seconds to cache remote file attributes."
  :type 'number)

(defcustom rdev-timeout 30
  "Seconds to wait for a synchronous RPC."
  :type 'integer)

(defcustom rdev-cache-max-entries 5000
  "Maximum cached attribute entries per host; the oldest are evicted first."
  :type 'natnum)

(defcustom rdev-chunk-size (* 1024 1024)
  "Bytes per request when transferring large files (capped at 4 MiB).
Only used with agents advertising the `fs.chunk' capability."
  :type 'natnum)

(defcustom rdev-large-file-threshold (* 8 1024 1024)
  "Files larger than this many bytes are transferred in chunks.
Chunked transfers keep memory bounded to about one chunk (plus Emacs's own
buffer), and a \\[keyboard-quit] during a save aborts cleanly without
touching the destination."
  :type 'natnum)

(defconst rdev--max-chunk (* 4 1024 1024)
  "Agent-side hard limit on one chunk (`limits.max_chunk').")

(defcustom rdev-env-exclude
  '("PATH" "HOME" "USER" "LOGNAME" "SHELL" "PWD" "OLDPWD" "DISPLAY"
    "WAYLAND_DISPLAY" "XAUTHORITY" "DBUS_SESSION_BUS_ADDRESS" "SSH_AUTH_SOCK"
    "SSH_AGENT_PID" "SSH_CONNECTION" "SSH_CLIENT" "SSH_TTY" "MAIL" "TMPDIR"
    "XDG_RUNTIME_DIR" "XDG_SESSION_ID" "XDG_DATA_DIRS" "XDG_CONFIG_DIRS"
    "LD_LIBRARY_PATH" "EMACSLOADPATH" "EMACSPATH")
  "Environment variables never forwarded to remote processes."
  :type '(repeat string))

(defconst rdev--dir (file-name-directory (or load-file-name buffer-file-name)))
(defconst rdev--server-file (expand-file-name "rdev-server.py" rdev--dir))
(defconst rdev--relay-file (expand-file-name "rdev-relay.py" rdev--dir))

(defconst rdev--regexp "\\`/rdev:\\([^:/|]+\\):\\(\\(?:.\\|\n\\)*\\)\\'"
  "Matches /rdev:HOST:LOCALNAME.")

;;;; Connections

(cl-defstruct (rdev-conn (:constructor rdev--make-conn))
  host rpc home path (cache (make-hash-table :test #'equal))
  ;; Added for protocol negotiation and diagnostics (appended: keeps
  ;; positional compatibility with the original slots).
  state gen proto caps limits transport log stats procs policy
  ;; Docker target bookkeeping (appended again: same compatibility rule).
  container container-name engine root-mode)

(cl-defstruct (rdev-chan (:constructor rdev--make-chan))
  id host proc sock cmd cwd pty merge env exited
  ;; Non-nil once the connection died under a running process (T056): the
  ;; process is reported as exited 255 and is never replayed.
  interrupted)

(defconst rdev-supported-protocol-major 1
  "Highest protocol major version this client understands.")

(defun rdev--parse-protocol (str)
  "Return (MAJOR . MINOR) for protocol string STR; nil/invalid is legacy 1.0."
  (if (and (stringp str) (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)" str))
      (cons (string-to-number (match-string 1 str))
            (string-to-number (match-string 2 str)))
    (cons 1 0)))

(defun rdev-conn-has-cap (conn cap)
  "Non-nil if CONN's agent advertised capability string CAP."
  (member cap (rdev-conn-caps conn)))

(defvar rdev--conns (make-hash-table :test #'equal)
  "HOST -> `rdev-conn'.")

(defvar rdev--chans (make-hash-table :test #'equal)
  "(HOST . ID) -> `rdev-chan' for remote processes.
Scoping by host means a channel id announced by one agent can never
address another host's channel (D-06).")

(defun rdev--chan-get (host id) (gethash (cons host id) rdev--chans))
(defun rdev--chan-put (chan)
  (puthash (cons (rdev-chan-host chan) (rdev-chan-id chan)) chan rdev--chans))
(defun rdev--chan-del (chan)
  (remhash (cons (rdev-chan-host chan) (rdev-chan-id chan)) rdev--chans))
(defun rdev--chan-find-id (id)
  "Find the channel with local id ID.  Ids come from one client-side counter."
  (let (found)
    (maphash (lambda (_k c) (when (eql (rdev-chan-id c) id) (setq found c))) rdev--chans)
    found))

(defun rdev--parse (name)
  "Return (HOST . LOCALNAME) for rdev file NAME, or nil."
  (when (and (stringp name) (string-match rdev--regexp name))
    (cons (match-string 1 name) (match-string 2 name))))

(defun rdev--host (name) (car (rdev--parse name)))

(defun rdev--prefix (host) (concat "/rdev:" host ":"))

(defun rdev--server-script ()
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally rdev--server-file)
    (buffer-string)))

(defun rdev--wait-for (proc pred what)
  "Accept output from PROC until PRED returns non-nil.
WHAT names the awaited event in the timeout error."
  (let ((deadline (+ (float-time) rdev-timeout)))
    (while (not (funcall pred))
      (unless (process-live-p proc)
        (signal 'rdev-ssh-error
                (list (format "rdev: %s failed (%s)" what
                              (string-trim (or (process-get proc 'rdev-log) ""))))))
      (when (> (float-time) deadline)
        (delete-process proc)
        (signal 'rdev-ssh-error (list (format "rdev: timed out during %s" what))))
      (accept-process-output proc 0.05))))

(defun rdev--validate-host (host)
  "Signal `user-error' unless HOST is a safe ssh destination (D-01)."
  (unless (and (stringp host)
               (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9._@%+:-]*\\'" host))
    (user-error "rdev: invalid host name %S (must not start with `-' or contain unusual characters)"
                host))
  host)

;; The Docker transport lives in rdev-docker.el, loaded only when a Docker
;; target is used, so the ssh/tcp path has no new load-time dependency.
(declare-function rdev-docker--process "rdev-docker" (host spec))
(declare-function rdev-docker--refresh-identity "rdev-docker" (host))
(declare-function rdev-docker--engine-key "rdev-docker" (spec))
(declare-function rdev-docker--fallback-key "rdev-docker" (host))
(declare-function rdev-docker--completion-hosts "rdev-docker" nil)

(defconst rdev--docker-address-regexp
  "\\`docker\\+\\([A-Za-z0-9][A-Za-z0-9_.-]*\\)\\(?:@\\(.+\\)\\)?\\'"
  "Matches the explicit container address `docker+NAME[@ENGINE-HOST]'.
Group 1 is the container name, group 2 the optional SSH destination of a
remote engine.  `+' cannot occur in a DNS host name or a container name.")

(defun rdev--docker-address-spec (host)
  "Docker spec for the explicit container address HOST, or nil.
`docker+NAME' is the container NAME on the local engine and
`docker+NAME@DH' is NAME on the engine reached over SSH at DH.  Parsing is
pure: nothing is queried and `rdev-hosts' is not changed."
  (when (and (stringp host) (string-match rdev--docker-address-regexp host))
    (let ((name (match-string 1 host))
          (dh (match-string 2 host)))
      (append (list :transport 'docker :container name)
              (and dh (list :docker-host dh))))))

(defun rdev--host-spec (host)
  "The connection PLIST for HOST, or nil (SSH).
An `rdev-hosts' entry wins, even one with a nil plist; otherwise an
explicit `docker+NAME[@DH]' address yields its Docker spec."
  (if-let* ((entry (assoc host rdev-hosts)))
      (cdr entry)
    (rdev--docker-address-spec host)))

(defun rdev--docker-p (host)
  "Non-nil when HOST is configured as a Docker (:transport docker) target."
  (eq (plist-get (rdev--host-spec host) :transport) 'docker))

(defun rdev--any-docker-target-p ()
  "Non-nil when any `rdev-hosts' entry is a Docker target."
  (cl-some (lambda (e) (eq (plist-get (cdr e) :transport) 'docker))
           rdev-hosts))

;; One bootstrap for both transports: the ssh path must stay byte-identical
;; (its output is hash-pinned on remote hosts), so HOME-FALLBACK and
;; AGENT-ARGS only change what the Docker transport asks for.
(defun rdev--bootstrap-script (&optional home-fallback agent-args)
  "Return the remote bootstrap script (printf-style: hash, size, sha256).
HOME-FALLBACK adds the /tmp/rdev-<uid> fallback used by Docker targets when
$HOME is unset or unwritable; the ssh path keeps `$HOME/.cache/rdev'
unchanged.  AGENT-ARGS are appended to the agent's command line (the
documented `--allow-root' opt-in)."
  (concat
   "umask 077; D=\"$HOME/.cache/rdev\""
   (if home-fallback
       ;; The shared /tmp fallback is used only when this account owns both
       ;; directories and neither is a symlink (no pre-planted directory).
       "; if ! mkdir -p \"$D\" 2>/dev/null; then B=\"/tmp/rdev-$(id -u)\"; D=\"$B/rdev\"; \
{ mkdir -p \"$D\" 2>/dev/null && [ ! -L \"$B\" ] && [ -O \"$B\" ] && [ ! -L \"$D\" ] && [ -O \"$D\" ] \
&& chmod 700 \"$B\" \"$D\"; } || { echo 'RDEV-ERR no writable directory for the rdev helper \
(/tmp/rdev-UID is missing, not owned by this account, or a symlink)'; exit 4; }; fi"
     "")
   "; F=\"$D/rdev-server-%s.py\"; N=%d; H=%s; "
   "P=$(command -v python3 || echo /usr/bin/python3); "
   ;; Python >= 3.8 probe (Article VI).
   "if ! \"$P\" -c 'import sys;sys.exit(0 if sys.version_info>=(3,8) else 1)' 2>/dev/null; "
   "then echo 'RDEV-ERR python3 >= 3.8 not found on this host'; exit 3; fi; "
   ;; verify FILE: exact size and sha256.
   "v() { [ -f \"$1\" ] && [ \"$(wc -c < \"$1\" | tr -d ' ')\" = \"$N\" ] && "
   "[ \"$(\"$P\" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],\"rb\").read()).hexdigest())' \"$1\" 2>/dev/null)\" = \"$H\" ]; }; "
   "if v \"$F\"; then echo 'RDEV-BOOT ok'; else echo 'RDEV-BOOT need'; "
   "mkdir -p \"$D\" && chmod 700 \"$D\" && T=\"$F.tmp.$$\" && head -c $N > \"$T\"; "
   ;; install only if the received bytes verify.
   "if v \"$T\"; then chmod 700 \"$T\" && mv \"$T\" \"$F\"; "
   "else rm -f \"$T\"; echo 'RDEV-ERR agent upload was truncated or corrupted'; exit 4; fi; fi; "
   "echo RDEV-READY; exec \"$P\" -u \"$F\" --stdio" (or agent-args "")))

(defconst rdev--bootstrap-template (rdev--bootstrap-script)
  "Remote bootstrap script (printf-style: short hash, size, sha256).
Byte-identical to `(rdev--bootstrap-script)' with no arguments.")

(defun rdev--bootstrap-filter (proc string)
  "Track RDEV-BOOT/RDEV-ERR/RDEV-READY markers in output STRING from PROC.
Bytes after the newline that ends RDEV-READY are kept in `rdev-residual'
so the JSON-RPC layer receives them (D-08)."
  (if (eq (process-get proc 'rdev-state) 'ready)
      (process-put proc 'rdev-residual
                   (concat (process-get proc 'rdev-residual) string))
    (let ((acc (concat (process-get proc 'rdev-log) string)))
      (process-put proc 'rdev-log acc)
      (when (and (not (process-get proc 'rdev-sent))
                 (string-match-p "^RDEV-BOOT need$" acc))
        (process-put proc 'rdev-sent t)
        (process-send-string proc (process-get proc 'rdev-script)))
      (cond
       ((string-match "^RDEV-ERR \\(.*\\)$" acc)
        (process-put proc 'rdev-error (match-string 1 acc))
        (process-put proc 'rdev-state 'error))
       ((string-match "^RDEV-READY\n" acc)
        (process-put proc 'rdev-residual (substring acc (match-end 0)))
        (process-put proc 'rdev-log (substring acc 0 (match-beginning 0)))
        (process-put proc 'rdev-state 'ready))))))

(defun rdev--ssh-process (host spec)
  "Start (and deploy if needed) a stdio server on HOST over ssh.
SPEC is the connection plist; its :ssh-host overrides HOST for ssh."
  (rdev--validate-host (or (plist-get spec :ssh-host) host))
  (let* ((script (rdev--server-script))
         (sha (secure-hash 'sha256 script))
         (remote (format rdev--bootstrap-template
                         (substring sha 0 12) (length script) sha))
         (default-directory temporary-file-directory)
         (stderr (get-buffer-create (format " *rdev-stderr %s*" host)))
         ;; ssh is the transport: its stdin/stdout carry the JSON-RPC stream and
         ;; its death is the connection-loss signal (see `rdev--on-shutdown').
         (proc (make-process
                :name (format "rdev-%s" host)
                :command (append '("ssh") rdev-ssh-args
                                 (list "--"
                                       (or (plist-get spec :ssh-host) host)
                                       (concat "sh -c " (shell-quote-argument remote))))
                :connection-type 'pipe :coding 'binary :noquery t
                :stderr stderr
                :filter #'rdev--bootstrap-filter)))
    (process-put proc 'rdev-log "")
    (process-put proc 'rdev-script script)
    (rdev--wait-for proc (lambda () (process-get proc 'rdev-state))
                    (format "ssh to %s" host))
    (when (eq (process-get proc 'rdev-state) 'error)
      (let ((msg (process-get proc 'rdev-error)))
        (delete-process proc)
        (signal 'rdev-agent-error (list (format "rdev: %s: %s" host msg)))))
    proc))

(defun rdev--loopback-address-p (addr)
  "Non-nil if ADDR names the local machine."
  (and (stringp addr)
       (or (string= addr "localhost") (string= addr "::1")
           (string-match-p "\\`127\\.[0-9]+\\.[0-9]+\\.[0-9]+\\'" addr))))

(defun rdev--tcp-process (host spec)
  (let ((addr (or (plist-get spec :address) host)))
    (unless (or (plist-get spec :tls)
                (rdev--loopback-address-p addr)
                rdev-allow-insecure-tcp
                (plist-get spec :insecure-ok))
      (user-error "rdev: refusing plaintext TCP to non-loopback %s; use ssh, :tls t, or set `rdev-allow-insecure-tcp' / :insecure-ok"
                  addr))
    (unless (or (plist-get spec :tls) (rdev--loopback-address-p addr))
      (display-warning 'rdev (format "plaintext TCP to %s: traffic is not encrypted" addr))))
  (let* ((default-directory temporary-file-directory)
         (proc (open-network-stream
                (format "rdev-%s" host) nil
                (or (plist-get spec :address) host) (plist-get spec :port)
                :type (if (plist-get spec :tls) 'tls 'plain)
                :coding 'binary :nowait nil)))
    (set-process-query-on-exit-flag proc nil)
    proc))

(defvar rdev--gens (make-hash-table :test #'equal) "HOST -> connection generation.")
(defvar rdev--key-hosts (make-hash-table :test #'equal)
  "Session key -> the host name used to (re)connect it.")
(defvar rdev--host-keys (make-hash-table :test #'equal)
  "HOST -> the session key last computed for it.
Docker targets use it to detect a container replaced under the same name:
a new identity retires the old session with empty caches.")
(defvar rdev--reconnecting nil "Non-nil while the reconnect timer is connecting.")
(defvar rdev--reconnect-key nil
  "Session key the current reconnect attempt is for, or nil.
A Docker container replaced under the same name resolves to a NEW key during
the attempt; that key is not the one being reconnected, so it must run the
ordinary connecting transitions instead of being treated as already in
flight.")

(defun rdev--flush-stderr-to-log (host key)
  "Move ssh/agent stderr collected for HOST into the redacted log of KEY."
  (when-let* ((buf (get-buffer (format " *rdev-stderr %s*" host)))
              ((buffer-live-p buf)))
    (let ((text (with-current-buffer buf
                  (prog1 (buffer-string) (erase-buffer)))))
      (dolist (line (split-string text "\n" t))
        (rdev-state-log key "stderr: %s" line)))))

(defun rdev--connect (host)
  "Connect to HOST (once per logical session) and return its `rdev-conn'.
State changes are recorded by `rdev-state-transition'.  A second connect
while one is in flight signals `rdev-connection-lost' instead of racing."
  ;; Validate before anything runs ssh (even `ssh -G' for the session key).
  (rdev--validate-host host)
  ;; Docker targets re-resolve their container identity on every connect and
  ;; reconnect: the identity is part of the session key, so a recreated
  ;; container starts a new session with empty caches.
  ;; A container that cannot be inspected (gone, stopped engine) still gets
  ;; a session key, so the failure below is recorded and shown.
  (let* ((ident-err nil)
         (key (if (rdev--docker-p host)
                  (progn
                    (require 'rdev-docker)
                    (condition-case err
                        (rdev-docker--refresh-identity host)
                      ((error quit)
                       (setq ident-err err)
                       (rdev-docker--fallback-key host))))
                (rdev-state-session-key host)))
         ;; Only the key the reconnect was scheduled for is "in flight"; a
         ;; container replaced under the same name yields a new key that
         ;; must connect normally.
         (reconnecting (and rdev--reconnecting
                            (equal key rdev--reconnect-key)))
         (twin (and (not ident-err) (rdev--live-alias-conn host key))))
    (or twin
        (progn
          (when (and (rdev-state-attempt-in-flight-p key) (not rdev--reconnecting))
            (signal 'rdev-connection-lost
                    (list (format "rdev: connection to %s is %s; retry shortly"
                                  host (rdev-state key)))))
          (puthash key host rdev--key-hosts)
          (puthash host key rdev--host-keys)
          (unless reconnecting
            ;; A stale `connected' state (transport already gone) is reset.
            (when (memq (rdev-state key) '(connected degraded))
              (rdev-state-user-disconnect key))
            (rdev-state-transition key 'connecting))
          (condition-case err
              (if ident-err
                  (signal (car ident-err) (cdr ident-err))
                (rdev--connect-1 host key))
            ((error quit)
             (rdev--flush-stderr-to-log host key)
             (rdev-state-log key "connect failed: %s" (error-message-string err))
             (unless (eq (rdev-state key) 'reconnecting)
               (rdev-state-transition key 'failed (error-message-string err)))
             (signal (car err) (cdr err))))))))

(defun rdev--live-alias-conn (host key)
  "A live connection to the same session KEY under another alias, shared as HOST."
  (let (found)
    (maphash (lambda (h c)
               (when (and (not found) (not (equal h host))
                          (equal (rdev-state-session-key h) key)
                          (jsonrpc-running-p (rdev-conn-rpc c)))
                 (setq found c)))
             rdev--conns)
    (when found (puthash host found rdev--conns))
    found))

(defun rdev--connect-1 (host key)
  (let* ((spec (rdev--host-spec host))
         (tcp (eq (plist-get spec :transport) 'tcp))
         (docker (eq (plist-get spec :transport) 'docker))
         (proc (progn
                 (unless (or tcp (eq (rdev-state key) 'reconnecting))
                   (rdev-state-transition key 'bootstrapping))
                 (cond (docker (rdev-docker--process host spec))
                       (tcp (rdev--tcp-process host spec))
                       (t (rdev--ssh-process host spec)))))
         (_ (rdev-state-transition key 'initializing))
         (rpc (jsonrpc-process-connection
               :name (format "rdev-%s" host)
               :process proc
               :events-buffer-config '(:size 0)
               :notification-dispatcher #'rdev--dispatch
               :on-shutdown (lambda (_) (rdev--on-shutdown host))))
         conn)
    ;; Replay bytes that arrived together with the READY marker (D-08).
    (when-let* ((res (process-get proc 'rdev-residual))
                ((not (string-empty-p res))))
      (process-put proc 'rdev-residual nil)
      (funcall (process-filter proc) proc res))
    (when tcp
      (jsonrpc-request rpc :auth
                       `(:token ,(or (plist-get spec :token)
                                     (getenv "RDEV_TOKEN")
                                     (string-trim
                                      (with-temp-buffer
                                        (insert-file-contents
                                         (plist-get spec :token-file))
                                        (buffer-string)))))))
    ;; Always send a zero-param hello first: legacy agents reject params
    ;; with -32603.  An advisory client hello follows only if the agent
    ;; reports a protocol version.
    (let* ((hello (jsonrpc-request rpc :hello nil :timeout rdev-timeout))
           (proto (rdev--parse-protocol (plist-get hello :protocol))))
      (when (> (car proto) rdev-supported-protocol-major)
        (ignore-errors (jsonrpc-shutdown rpc))
        (signal 'rdev-agent-error
                (list (format "Agent on %s speaks protocol %s.x; this client supports %d.x.  Update rdev.el"
                              host (car proto) rdev-supported-protocol-major))))
      (when (plist-get hello :protocol)
        (ignore-errors
          (jsonrpc-request rpc :hello `(:client (:name "rdev.el" :protocol "1.1"))
                           :timeout rdev-timeout)))
      (setq conn (rdev--make-conn :host host :rpc rpc
                                  :home (plist-get hello :home)
                                  :path (append (plist-get hello :path) nil)
                                  :state 'ready
                                  :gen (puthash host (1+ (gethash host rdev--gens 0))
                                                rdev--gens)
                                  :proto (format "%d.%d" (car proto) (cdr proto))
                                  :caps (append (plist-get hello :capabilities) nil)
                                  :limits (plist-get hello :limits)
                                  :transport (cond (docker 'docker)
                                                   (tcp 'tcp)
                                                   (t 'ssh))
                                  :container (and docker (process-get proc 'rdev-container))
                                  :container-name (and docker (process-get proc 'rdev-container-name))
                                  :engine (and docker (rdev-docker--engine-key spec))
                                  :root-mode (and docker (process-get proc 'rdev-root-mode))
                                  :stats (list :agent (plist-get hello :version))))
      (puthash host conn rdev--conns)
      (rdev-state-transition key 'connected)
      (rdev--keepalive-ensure)
      (message "rdev: connected to %s (server %s, python %s)"
               host (plist-get hello :version) (plist-get hello :python))
      conn)))

;;;; Keepalive: CONNECTED <-> DEGRADED (FR-008, data-model.md)

(defcustom rdev-keepalive-interval 15
  "Seconds between keepalive probes of each live connection.
Nil disables probing (the DEGRADED state is then never entered)."
  :type '(choice (const :tag "Off" nil) number)
  :group 'rdev)

(defcustom rdev-degraded-after 5
  "Seconds a keepalive probe may stay unanswered before DEGRADED."
  :type 'number
  :group 'rdev)

(defvar rdev--keepalive-timer nil "Repeating timer that probes connections.")
(defvar rdev--keepalive-pending (make-hash-table :test #'equal)
  "Session key -> timer that marks the session degraded when it fires.
Presence of an entry means a probe is in flight.")

(defun rdev--keepalive-answered (key)
  "A probe on session KEY got a reply (or a definitive error)."
  (let ((tm (gethash key rdev--keepalive-pending)))
    (when (timerp tm) (cancel-timer tm))
    (remhash key rdev--keepalive-pending)
    (when (eq (rdev-state key) 'degraded)
      (rdev-state-transition key 'connected "keepalive answered"))))

(defun rdev--keepalive-forget (key)
  "Drop any in-flight probe bookkeeping for session KEY (transport gone)."
  (let ((tm (gethash key rdev--keepalive-pending)))
    (when (timerp tm) (cancel-timer tm))
    (remhash key rdev--keepalive-pending)))

(defun rdev--keepalive-probe (_host key conn)
  "Send one `hello' probe on session KEY over CONN, unless one is pending."
  (unless (gethash key rdev--keepalive-pending)
    (puthash key
             (run-with-timer
              rdev-degraded-after nil
              (lambda ()
                (when (eq (rdev-state key) 'connected)
                  (rdev-state-transition
                   key 'degraded
                   (format "no answer to keepalive in %ss" rdev-degraded-after)))))
             rdev--keepalive-pending)
    (condition-case nil
        (jsonrpc-async-request
         (rdev-conn-rpc conn) :hello nil
         :success-fn (lambda (_r) (rdev--keepalive-answered key))
         :error-fn (lambda (_e) (rdev--keepalive-answered key))
         :timeout-fn (lambda () (remhash key rdev--keepalive-pending))
         :timeout (max 30 (* 2 rdev-degraded-after)))
      ;; The transport is already gone; `rdev--on-shutdown' deals with it.
      (error (rdev--keepalive-forget key)))))

(defun rdev--keepalive-tick ()
  "Probe every distinct live session once."
  (let (seen)
    (maphash
     (lambda (host conn)
       (let ((key (rdev-state-session-key host)))
         (unless (member key seen)
           (push key seen)
           (when (memq (rdev-state key) '(connected degraded))
             (rdev--keepalive-probe host key conn)))))
     rdev--conns)
    (when (and (null seen) (timerp rdev--keepalive-timer))
      (cancel-timer rdev--keepalive-timer)
      (setq rdev--keepalive-timer nil))))

(defun rdev--keepalive-ensure ()
  "Start the keepalive timer if enabled and not running."
  (when (and rdev-keepalive-interval (not (timerp rdev--keepalive-timer)))
    (setq rdev--keepalive-timer
          (run-with-timer rdev-keepalive-interval rdev-keepalive-interval
                          #'rdev--keepalive-tick))))

(defun rdev--on-shutdown (host)
  "Transport to HOST closed.  Unexpected closes start a reconnect (FR-009)."
  (let* ((key (rdev-state-session-key host))
         (lost (memq (rdev-state key) '(connected degraded))))
    (rdev--flush-stderr-to-log host key)
    (rdev--keepalive-forget key)
    (remhash host rdev--conns)
    ;; Aliases sharing this connection go too.
    (dolist (h (hash-table-keys rdev--conns))
      (unless (gethash h rdev--conns) (remhash h rdev--conns)))
    (maphash (lambda (_k chan)
               (when (equal (rdev-chan-host chan) host)
                 ;; Processes owned by a lost connection are never replayed;
                 ;; the agent kills them on EOF (FR-021).
                 (when lost (setf (rdev-chan-interrupted chan) t))
                 (rdev--chan-exit host (rdev-chan-id chan) 255)))
             rdev--chans)
    (message "rdev: %s %s" (if lost "connection lost to" "disconnected from") host)
    (when lost (rdev-state-connection-lost key))))

(defun rdev--reconnect-attempt (key)
  "Reconnect session KEY; installed in `rdev-state-connect-function'."
  (let ((rdev--reconnecting t)
        (rdev--reconnect-key key)
        (host (gethash key rdev--key-hosts)))
    (unless host (error "No host recorded for session %s" key))
    (rdev--connect host)
    ;; The session key may have changed: a Docker container replaced under the
    ;; same name retires KEY and starts a new one, so report against the
    ;; session that is actually connected now.
    (rdev--connect-succeeded (rdev-state-session-key host))))

(defun rdev--connect-succeeded (_key) nil)

(setq rdev-state-connect-function #'rdev--reconnect-attempt)

(defun rdev--conn (host &optional noconnect)
  (let ((c (gethash host rdev--conns)))
    (if (and c (jsonrpc-running-p (rdev-conn-rpc c)))
        c
      (unless noconnect (rdev--connect host)))))

;;;; RPC helpers

;;;; Error classes (Article X: distinguishable failures)

(define-error 'rdev-conflict "Remote file changed since it was read" 'file-error)
(define-error 'rdev-connection-lost "rdev connection lost" 'file-error)
(define-error 'rdev-ssh-error "rdev SSH error" 'file-error)
(define-error 'rdev-transport-error "rdev transport error" 'file-error)
(define-error 'rdev-docker-error "rdev Docker error" 'rdev-transport-error)
;; `rdev-docker-error' data is (MESSAGE REASON) with REASON one of:
;;   not-found, not-running, permission, engine-unreachable, unsupported,
;;   root-refused, bootstrap.
(define-error 'rdev-agent-error "rdev agent error" 'file-error)
(define-error 'rdev-filesystem-error "rdev remote filesystem error" 'file-error)
(define-error 'rdev-process-error "rdev remote process error" 'file-error)

(defun rdev--signal-error (err filename)
  "Re-signal jsonrpc ERR as an Emacs file error about FILENAME."
  (let* ((msg (alist-get 'jsonrpc-error-message (cdr err)))
         (data (alist-get 'jsonrpc-error-data (cdr err)))
         (errno (plist-get data :errno))
         (code (alist-get 'jsonrpc-error-code (cdr err))))
    (signal (pcase code
              (-32010 'rdev-conflict)
              (-32011 'rdev-filesystem-error)
              (-32012 'rdev-agent-error)
              (-32013 'rdev-transport-error)
              (-32600 'rdev-transport-error)
              (-32800 'rdev-process-error)
              (_ (pcase errno
              ("ENOENT" 'file-missing)
              ("EEXIST" 'file-already-exists)
              ((or "EACCES" "EPERM") 'permission-denied)
              (_ 'file-error))))
            (list "rdev" (or msg "error") (or filename "")))))

(defconst rdev--native-cancel-on-quit
  ;; cl-defun hides keyword args in &rest, so look at the docstring.
  (condition-case nil
      (and (string-match-p "CANCEL-ON-QUIT"
                           (or (documentation 'jsonrpc-request t) ""))
           t)
    (error nil))
  "Non-nil if this Emacs's `jsonrpc-request' accepts :cancel-on-quit (Emacs 31+).")

(defun rdev--request-with-cancel (conn method params cancel)
  "Like `jsonrpc-request' on CONN, calling (CANCEL ID) if the user quits.
METHOD and PARAMS are the request.
Emacs 31 has :cancel-on-quit; Emacs 30 does not, so there the id is
predicted from the connection's counter (Emacs runs one sync request at a
time, so the next id is the one `jsonrpc-request' will use)."
  (if rdev--native-cancel-on-quit
      (jsonrpc-request conn method params :timeout rdev-timeout
                       :cancel-on-quit cancel)
    (let ((id (and (fboundp 'jsonrpc--next-request-id)
                   (1+ (jsonrpc--next-request-id conn)))))
      (condition-case nil
          (jsonrpc-request conn method params :timeout rdev-timeout)
        (quit (when id (funcall cancel id))
              (signal 'quit nil))))))

(defvar rdev--sync-depth 0
  "Number of synchronous `rdev--req' calls currently waiting for a reply.
jsonrpc.el unwinds *all* nested waits when an outer reply arrives, so code
that runs from timers (file-notify callbacks) must not issue a synchronous
request while this is above zero.")

(defun rdev--req (host method params &optional filename)
  "Send METHOD/PARAMS to HOST's agent and wait for the result.
On \\[keyboard-quit] while waiting, tell an agent with the `cancel'
capability to stop working on the request (`$/cancel'), then re-signal."
  (let* ((conn (rdev--conn host))
         (rpc (rdev-conn-rpc conn))
         (rdev--sync-depth (1+ rdev--sync-depth)))
    (condition-case err
        (if (rdev-conn-has-cap conn "cancel")
            (rdev--request-with-cancel
             rpc method params
             (lambda (id)
               (ignore-errors (jsonrpc-notify rpc :$/cancel `(:id ,id)))))
          (jsonrpc-request rpc method params :timeout rdev-timeout))
      (jsonrpc-error
       (if (not (jsonrpc-running-p rpc))
           ;; Pending request on a dead transport: never replayed here.
           (signal 'rdev-connection-lost
                   (list "rdev" (format "connection to %s lost during %s" host method)
                         (or filename "")))
         (rdev--signal-error err filename))))))

(defun rdev--notify (host method params)
  (when-let* ((c (rdev--conn host t)))
    (ignore-errors (jsonrpc-notify (rdev-conn-rpc c) method params))))

(defun rdev--b64 (bytes) (base64-encode-string bytes t))

(defun rdev--read-local-bytes (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents-literally file))
    (buffer-string)))

(defun rdev--write-local-bytes (bytes file)
  (let ((coding-system-for-write 'no-conversion)
        (file-name-handler-alist nil))
    (write-region bytes nil file nil 'silent)))

;;;; Attribute cache
;;
;; Entries are [TIME GEN STAT] keyed by directory-less remote path.  An entry
;; is valid only for the TTL and for the connection generation (`gen') that
;; stored it, so a reconnect invalidates everything at once.  Emacs hash tables
;; reuse freed slots, so iteration order says nothing about age; when the cache
;; is full the oldest tenth (by entry time) is evicted in one pass, which keeps
;; the amortized cost of a put small.

(defun rdev--stat-bump (conn key)
  "Increment statistics counter KEY (:hits :misses :evictions) of CONN."
  (setf (rdev-conn-stats conn)
        (plist-put (rdev-conn-stats conn) key
                   (1+ (or (plist-get (rdev-conn-stats conn) key) 0)))))

(defun rdev-cache-stats (&optional host)
  "Return plist (:hits :misses :evictions :entries) for HOST's attribute cache."
  (let ((c (rdev--conn (or host (rdev--host default-directory)))))
    (list :hits (or (plist-get (rdev-conn-stats c) :hits) 0)
          :misses (or (plist-get (rdev-conn-stats c) :misses) 0)
          :evictions (or (plist-get (rdev-conn-stats c) :evictions) 0)
          :entries (hash-table-count (rdev-conn-cache c)))))

(defun rdev--ls-key (local)
  "Cache key under which the completion listing of directory LOCAL is kept."
  (concat (directory-file-name local) "\0ls"))

(defun rdev--invalidate (host &rest locals)
  "Drop cache entries for LOCALS and their parent directories on HOST."
  (when-let* ((c (rdev--conn host t)))
    (dolist (l locals)
      (let ((l (directory-file-name l)))
        (remhash l (rdev-conn-cache c))
        (remhash (directory-file-name (file-name-directory l)) (rdev-conn-cache c))
        ;; Completion listings of the parent and of L itself.
        (remhash (rdev--ls-key (file-name-directory l)) (rdev-conn-cache c))
        (remhash (rdev--ls-key l) (rdev-conn-cache c))))))

(defun rdev--invalidate-tree (host &rest locals)
  "Like `rdev--invalidate' on HOST but also drop descendants of LOCALS."
  (apply #'rdev--invalidate host locals)
  (when-let* ((c (rdev--conn host t)))
    (dolist (l locals)
      (let ((prefix (file-name-as-directory (directory-file-name l)))
            doomed)
        (maphash (lambda (k _) (when (string-prefix-p prefix k) (push k doomed)))
                 (rdev-conn-cache c))
        (dolist (k doomed) (remhash k (rdev-conn-cache c)))))))

(defun rdev--cache-put (conn local st)
  (let ((key (directory-file-name local))
        (tbl (rdev-conn-cache conn)))
    (remhash key tbl)
    (when (>= (hash-table-count tbl) (max 1 rdev-cache-max-entries))
      (let (all)
        (maphash (lambda (k v) (push (cons (aref v 0) k) all)) tbl)
        (setq all (sort all (lambda (a b) (< (car a) (car b)))))
        (dotimes (_ (max 1 (/ (length all) 10)))
          (when-let* ((old (pop all)))
            (remhash (cdr old) tbl)
            (rdev--stat-bump conn :evictions)))))
    (puthash key (vector (float-time) (or (rdev-conn-gen conn) 0) (or st :none)) tbl)))

(defun rdev--cache-get (conn key)
  "Return the live entry vector for KEY in CONN's cache, else nil."
  (let ((hit (gethash key (rdev-conn-cache conn))))
    (when hit
      (if (and (< (- (float-time) (aref hit 0)) rdev-cache-ttl)
               (equal (aref hit 1) (or (rdev-conn-gen conn) 0)))
          hit
        (remhash key (rdev-conn-cache conn))
        nil))))

(defun rdev--stat (filename)
  "Cached remote stat plist for FILENAME, or nil if it doesn't exist.
A partial `/rdev:par' name (host not finished) has no remote stat: returning
nil keeps completion predicates such as `file-exists-p' quiet."
  (when-let* ((parsed (rdev--parse (expand-file-name filename))))
    (pcase-let* ((`(,host . ,local) parsed)
                 (conn (rdev--conn host))
                 (key (directory-file-name local))
                 (hit (rdev--cache-get conn key)))
      (if hit
          (progn (rdev--stat-bump conn :hits)
                 (unless (eq (aref hit 2) :none) (aref hit 2)))
        (rdev--stat-bump conn :misses)
        (let ((st (rdev--req host :fs/stat `(:path ,key) filename)))
          (rdev--cache-put conn key st)
          st)))))

(defun rdev--time (ns) (cons ns 1000000000))

(defun rdev--attributes (st id-format)
  (when st
    (list (pcase (plist-get st :type)
            ("dir" t) ("symlink" (plist-get st :target)) (_ nil))
          (plist-get st :nlink)
          (if (eq id-format 'string) (plist-get st :user) (plist-get st :uid))
          (if (eq id-format 'string) (plist-get st :group) (plist-get st :gid))
          (rdev--time (plist-get st :atime))
          (rdev--time (plist-get st :mtime))
          (rdev--time (plist-get st :ctime))
          (plist-get st :size)
          (plist-get st :modestr)
          t
          (plist-get st :ino)
          (plist-get st :dev))))

(defun rdev--true (v) (and v (not (eq v :json-false))))

;;;; File name handler

(defconst rdev--inhibit
  '(rdev-file-name-handler tramp-file-name-handler
    tramp-completion-file-name-handler tramp-autoload-file-name-handler
    tramp-archive-file-name-handler tramp-archive-autoload-file-name-handler))

(defun rdev--real (operation &rest args)
  "Run OPERATION with ARGS without rdev (or TRAMP) handling it."
  (let ((inhibit-file-name-handlers
         (append rdev--inhibit
                 ;; Also any other handler claiming /rdev: names (e.g. a
                 ;; lazy-load wrapper), or the fallback would loop forever.
                 (delq nil (mapcar (lambda (e)
                                     (and (stringp (car e))
                                          (string-match-p (car e) "/rdev:h:/")
                                          (cdr e)))
                                   file-name-handler-alist))
                 (and (eq inhibit-file-name-operation operation)
                      inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))
    (apply operation args)))

(defun rdev--local-temp-file (prefix &optional dir-flag suffix)
  "Like `make-temp-file' for PREFIX but always create the file locally.
DIR-FLAG and SUFFIX are as for `make-temp-file'.  With a remote
`default-directory' (or a remote value of the variable
`temporary-file-directory', as callers such as Magit may bind),
`make-temp-file' would pick a remote temp directory and re-enter the rdev
`write-region' handler without end."
  (let* ((tmp (if (file-remote-p temporary-file-directory)
                  (or (default-toplevel-value 'temporary-file-directory) "/tmp/")
                temporary-file-directory))
         (tmp (if (file-remote-p tmp) "/tmp/" tmp))
         (temporary-file-directory tmp)
         (default-directory tmp))
    (make-temp-file prefix dir-flag suffix)))

(defvar rdev--ops (make-hash-table :test #'eq))

(defmacro rdev-defop (op args &rest body)
  "Define the rdev implementation of file operation OP taking ARGS.
BODY is the implementation."
  (declare (indent 2))
  `(puthash ',op (lambda ,args ,@body) rdev--ops))

;;;###autoload
(defun rdev-file-name-handler (operation &rest args)
  "File name handler for /rdev:HOST:PATH names.
OPERATION is the file operation; ARGS are its arguments."
  (if-let* ((fn (gethash operation rdev--ops)))
      (save-match-data (apply fn args))
    (apply #'rdev--real operation args)))

(defun rdev--home (host) (rdev-conn-home (rdev--conn host)))

(defun rdev--normalize (host local)
  "Expand ~ and ./.. in remote LOCAL path on HOST."
  (when (string-match "\\`~\\(/\\|\\'\\)" local)
    (setq local (concat (rdev--home host) (substring local 1))))
  (when (string= local "") (setq local (rdev--home host)))
  (let ((file-name-handler-alist nil))
    (expand-file-name local "/")))

(rdev-defop expand-file-name (name &optional dir)
  (let ((p (rdev--parse name)))
    (cond
     (p (concat (rdev--prefix (car p)) (rdev--normalize (car p) (cdr p))))
     ((file-name-absolute-p name) (rdev--real 'expand-file-name name "/"))
     (t (let ((d (rdev--parse (expand-file-name (or dir default-directory)))))
          (if (not d)
              (rdev--real 'expand-file-name name dir)
            (concat (rdev--prefix (car d))
                    (rdev--normalize
                     (car d) (concat (file-name-as-directory (cdr d)) name)))))))))

(rdev-defop file-remote-p (file &optional identification connected)
  (when-let* ((p (rdev--parse file)))
    (unless (and connected (not (rdev--conn (car p) t)))
      (pcase identification
        ('method "rdev")
        ('host (car p))
        ('user nil)
        ('localname (if (rdev--conn (car p) t)
                        (rdev--normalize (car p) (cdr p))
                      (cdr p)))
        ('hop nil)
        (_ (rdev--prefix (car p)))))))

(rdev-defop file-attributes (file &optional id-format)
  (rdev--attributes (rdev--stat file) id-format))

(rdev-defop file-exists-p (file)
  (when-let* ((st (rdev--stat file))) (and (plist-get st :ftype) t)))

(rdev-defop file-directory-p (file)
  (equal (plist-get (rdev--stat file) :ftype) "dir"))

(rdev-defop file-regular-p (file)
  (equal (plist-get (rdev--stat file) :ftype) "file"))

(rdev-defop file-symlink-p (file)
  (let ((st (rdev--stat file)))
    (and (equal (plist-get st :type) "symlink") (plist-get st :target))))

(rdev-defop file-readable-p (file) (rdev--true (plist-get (rdev--stat file) :r)))
(rdev-defop file-executable-p (file) (rdev--true (plist-get (rdev--stat file) :x)))

(rdev-defop file-writable-p (file)
  (if-let* ((st (rdev--stat file)))
      (rdev--true (plist-get st :w))
    (let ((d (rdev--stat (file-name-directory (directory-file-name (expand-file-name file))))))
      (and (rdev--true (plist-get d :w)) (rdev--true (plist-get d :x))))))

(rdev-defop file-accessible-directory-p (file)
  (let ((st (rdev--stat file)))
    (and (equal (plist-get st :ftype) "dir") (rdev--true (plist-get st :x)))))

(rdev-defop access-file (file string)
  (unless (rdev--stat file)
    (signal 'file-missing (list string "No such file or directory" file))))

(rdev-defop file-modes (file &optional flag)
  (let ((st (rdev--stat file)))
    (when st
      (if (and (equal (plist-get st :type) "symlink") (not (eq flag 'nofollow)))
          (let ((p (rdev--parse (expand-file-name file))))
            (plist-get (rdev--req (car p) :fs/stat
                                  `(:path ,(rdev--req (car p) :fs/realpath `(:path ,(cdr p)))))
                       :mode))
        (plist-get st :mode)))))

(rdev-defop file-newer-than-file-p (f1 f2)
  (let ((a (file-attribute-modification-time (file-attributes f1)))
        (b (file-attribute-modification-time (file-attributes f2))))
    (cond ((not a) nil) ((not b) t) (t (time-less-p b a)))))

(rdev-defop file-truename (file)
  (if-let* ((parsed (rdev--parse (expand-file-name file))))
      (pcase-let ((`(,host . ,local) parsed))
        (let ((real (rdev--req host :fs/realpath `(:path ,local) file)))
          (concat (rdev--prefix host)
                  (if (directory-name-p file) (file-name-as-directory real) real))))
    ;; A partial `/rdev:par' name is not a remote path yet; keep it as typed.
    file))

(rdev-defop file-name-case-insensitive-p (_file) nil)
(rdev-defop file-ownership-preserved-p (_file &optional _group) t)
(rdev-defop file-acl (_file) nil)
(rdev-defop file-selinux-context (_file) '(nil nil nil nil))
(rdev-defop set-file-acl (_file _acl) nil)
(rdev-defop set-file-selinux-context (_file _context) nil)
(rdev-defop lock-file (_file) nil)
(rdev-defop unlock-file (_file) nil)
(rdev-defop file-locked-p (_file) nil)
;; file-notify-add-watch / -rm-watch / -valid-p live in rdev-notify.el.

(rdev-defop file-system-info (file)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name file))))
    (ignore-errors (append (rdev--req host :fs/statvfs `(:path ,local)) nil))))

(rdev-defop unhandled-file-name-directory (_file) nil)

(rdev-defop temporary-file-directory ()
  (concat (rdev--prefix (rdev--host default-directory)) "/tmp/"))

(rdev-defop exec-path ()
  (let ((host (rdev--host default-directory)))
    (append (rdev-conn-path (rdev--conn host))
            (list (file-local-name (expand-file-name default-directory))))))

;;;;; Directories

(defun rdev--inflate-listing (z)
  "Decode the base64+zlib JSON listing string Z from `fs/readdir'.
Return a vector of [NAME ATTRS-OR-FLAG] vectors, as the plain form does."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (base64-decode-string z))
    (unless (zlib-decompress-region (point-min) (point-max))
      (signal 'rdev-agent-error (list "rdev" "cannot decompress directory listing")))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'plist :null-object nil
                       :false-object :json-false)))

(defun rdev--readdir (dir attrs)
  (pcase-let* ((`(,host . ,local) (rdev--parse (expand-file-name dir)))
               (conn (rdev--conn host))
               (zip (and (rdev-conn-has-cap conn "fs.readdirZ")
                         (fboundp 'zlib-available-p) (zlib-available-p)))
               (entries (rdev--req host :fs/readdir
                                   `(:path ,local :attrs ,(if attrs t :json-false)
                                     ,@(and zip '(:compress t)))
                                   dir)))
    ;; A compressed answer is an object {"z": ...}; a plain one is an array.
    (when (and (not (vectorp entries)) (plist-get entries :z))
      (setq entries (rdev--inflate-listing (plist-get entries :z))))
    (when attrs
      (cl-loop for e across entries
               do (rdev--cache-put conn (concat (file-name-as-directory local) (aref e 0))
                                   (aref e 1))))
    (append entries nil)))

(rdev-defop directory-files (dir &optional full match nosort count)
  (let* ((names (append '("." "..") (mapcar (lambda (e) (aref e 0)) (rdev--readdir dir nil))))
         (names (if match (cl-remove-if-not (lambda (n) (string-match-p match n)) names) names))
         (names (if nosort names (sort names #'string<)))
         (names (if (and count (> count 0)) (take count names) names)))
    (if full
        (mapcar (lambda (n) (concat (file-name-as-directory dir) n)) names)
      names)))

(rdev-defop directory-files-and-attributes (dir &optional full match nosort id-format count)
  (let* ((entries (rdev--readdir dir t))
         (res (cl-loop for e across (vconcat entries)
                       for n = (aref e 0)
                       when (or (not match) (string-match-p match n))
                       collect (cons (if full (concat (file-name-as-directory dir) n) n)
                                     (rdev--attributes (aref e 1) id-format)))))
    ;; "." and ".." would each cost a stat round trip; fetch both at once.
    (when (cl-some (lambda (n) (or (not match) (string-match-p match n))) '("." ".."))
      (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name dir))))
        (rdev--prefetch-stats
         host (list (directory-file-name local)
                    (directory-file-name (file-name-directory (directory-file-name local)))))))
    (dolist (n '("." ".."))
      (when (or (not match) (string-match-p match n))
        (push (cons (if full (concat (file-name-as-directory dir) n) n)
                    (file-attributes (expand-file-name n dir) id-format))
              res)))
    (unless nosort (setq res (sort res (lambda (a b) (string< (car a) (car b))))))
    (if (and count (> count 0)) (take count res) res)))

(defun rdev--completion-entries (dir)
  "Return ((NAME . DIRP) ...) for remote directory DIR, or nil if unreadable.
One `fs/readdir' round trip with attributes (which also warms the attribute
cache, so completion predicates cost nothing more).  The listing is kept for
`rdev-cache-ttl' seconds under the same invalidation rules as attributes, so
successive keystrokes in one directory need no further round trips."
  (when-let* ((parsed (rdev--parse (expand-file-name dir))))
    (pcase-let* ((`(,host . ,local) parsed)
                 (conn (rdev--conn host))
                 (key (rdev--ls-key local))
                 (hit (rdev--cache-get conn key)))
      (if hit
          (aref hit 2)
        (when-let* ((entries
                     (condition-case err (rdev--readdir dir t)
                       ;; Transport failures must surface; an unreadable or
                       ;; missing directory simply has no completions.
                       ((rdev-connection-lost rdev-ssh-error rdev-transport-error)
                        (signal (car err) (cdr err)))
                       (file-error nil))))
          (let ((names (mapcar (lambda (e)
                                 (cons (aref e 0)
                                       (equal (plist-get (aref e 1) :ftype) "dir")))
                               entries)))
            (puthash key (vector (float-time) (or (rdev-conn-gen conn) 0) names)
                     (rdev-conn-cache conn))
            names))))))

(defun rdev--host-completion-dir-p (dir)
  "Non-nil when DIR is the `/rdev:' host-completion prefix.
That is the state before the host's closing colon has been typed."
  (and (stringp dir)
       (string-match-p "\\`/rdev:\\'" dir)))

(defun rdev--host-completion-candidates ()
  "Host names offered after `/rdev:', each with its closing colon.
Configured targets, ssh-config hosts and running containers are included;
the colon lets the user continue with `:/path' immediately."
  (mapcar (lambda (h) (concat h ":")) (rdev--target-completion)))

(defun rdev--host-completion-name (file)
  "Strip a leading `rdev:' from FILE for host completion.
`completion-file-name-table' derives the name with `file-name-nondirectory',
which does not consult our `file-name-directory' handler, so the name can
arrive as `rdev:par' instead of `par'."
  (if (and (stringp file) (string-prefix-p "rdev:" file))
      (substring file 5)
    file))

(rdev-defop file-name-directory (file)
  ;; Split `/rdev:par' into directory `/rdev:' and name `par', so the
  ;; minibuffer asks for host completions instead of looking in `/'.
  (if (and (stringp file)
           (string-match "\\`\\(/rdev:\\)[^:/|]*\\'" file))
      (match-string 1 file)
    (rdev--real 'file-name-directory file)))

(rdev-defop file-name-all-completions (file dir)
  (if (rdev--host-completion-dir-p dir)
      (let ((case-fold completion-ignore-case)
            (name (rdev--host-completion-name file)))
        (cl-remove-if-not (lambda (c) (string-prefix-p name c case-fold))
                          (rdev--host-completion-candidates)))
    (when-let* ((entries (rdev--completion-entries dir)))
      (let ((case-fold completion-ignore-case))
        (cl-loop for (name . isdir) in (append '(("." . t) (".." . t)) entries)
                 when (string-prefix-p file name case-fold)
                 collect (if isdir (concat name "/") name))))))

(defun rdev--prefetch-stats (host locals)
  "Fill HOST's attribute cache for LOCALS with one `fs/statMany' round trip.
No-op when the agent lacks `fs.statMany' or LOCALS is empty.  Entries that
fail to stat are simply left uncached, so later single stats report errors."
  (when (and locals (rdev-conn-has-cap (rdev--conn host) "fs.statMany"))
    (let ((conn (rdev--conn host)))
      (cl-loop for chunk on locals by (lambda (l) (nthcdr 4096 l))
               do (let ((res (rdev--req host :fs/statMany
                                        `(:paths ,(vconcat (seq-take chunk 4096))))))
                    (cl-loop for r across (plist-get res :results)
                             unless (plist-get r :error)
                             do (rdev--cache-put conn (plist-get r :path)
                                                 (plist-get r :stat))))))))

(rdev-defop file-name-completion (file dir &optional pred)
  (if (rdev--host-completion-dir-p dir)
      ;; Host names are not files: ignore the predicate, which would try to
      ;; stat `/rdev:HOST:' and start a connection for every candidate.
      (try-completion (rdev--host-completion-name file)
                      (rdev--host-completion-candidates))
    (let ((all (file-name-all-completions file dir)))
      (when (and pred (rdev--parse (expand-file-name dir)))
        ;; The predicate will stat every candidate.
        (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name dir))))
          (rdev--prefetch-stats
           host (mapcar (lambda (n) (concat (file-name-as-directory local)
                                            (directory-file-name n)))
                        (cl-remove-if (lambda (n) (member n '("./" "../"))) all)))))
      (try-completion file all
                      (and pred (lambda (n) (funcall pred (expand-file-name n dir))))))))

(rdev-defop make-directory-internal (dir)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name dir))))
    (rdev--req host :fs/mkdir `(:path ,local) dir)
    (rdev--invalidate host local)
    nil))

(rdev-defop make-directory (dir &optional parents)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name dir))))
    (prog1 (rdev--true (rdev--req host :fs/mkdir
                                  `(:path ,local :parents ,(if parents t :json-false)) dir))
      (rdev--invalidate host local))))

(rdev-defop delete-directory (dir &optional recursive _trash)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name dir))))
    (rdev--req host :fs/delete `(:path ,(directory-file-name local)
                                 :recursive ,(if recursive t :json-false))
               dir)
    (rdev--invalidate-tree host local)
    nil))

(rdev-defop insert-directory (file switches &optional wildcard full-directory-p)
  (pcase-let* ((`(,host . ,local) (rdev--parse (expand-file-name file)))
               (sw (delete "--dired"
                           (if (listp switches) (copy-sequence switches)
                             (split-string-and-unquote switches))))
               (cmd (cond
                     (wildcard
                      (list "sh" "-c"
                            (format "cd %s && ls %s -d -- %s"
                                    (shell-quote-argument (file-name-directory local))
                                    (mapconcat #'shell-quote-argument sw " ")
                                    (file-name-nondirectory local))))
                     (full-directory-p
                      (append '("ls") sw (list "--" (file-name-as-directory local))))
                     (t (append '("ls") sw (list "-d" "--" local)))))
               (res (rdev--req host :exec/run `(:cmd ,(vconcat cmd)) file)))
    (insert (decode-coding-string
             (base64-decode-string (plist-get res :stdout))
             (or file-name-coding-system 'utf-8)))))

;;;;; Reading and writing

;;;;; Chunked transfer (fs.chunk)

(defvar rdev--version)

(defun rdev--chunk-len ()
  (max 1 (min rdev-chunk-size rdev--max-chunk)))

(defun rdev--use-chunks-p (host size)
  "Non-nil if a transfer of SIZE bytes with HOST should use the chunk family."
  (and size (> size rdev-large-file-threshold)
       (rdev-conn-has-cap (rdev--conn host) "fs.chunk")))

(defun rdev--chunked-read (host local filename dest size)
  "Download LOCAL on HOST into the local file DEST chunk by chunk.
Returns the FileVersion of the remote file.  The first chunk's version is
sent back as `:expected' on later chunks, so a remote modification
mid-transfer signals `rdev-conflict' instead of returning a torn file."
  (let ((off 0) (len (rdev--chunk-len)) version eof
        (coding-system-for-write 'no-conversion)
        (file-name-handler-alist nil))
    (write-region "" nil dest nil 'silent)
    (while (not eof)
      (let* ((res (rdev--req host :fs/readChunk
                             `(:path ,local :offset ,off :length ,len
                               ,@(when version `(:expected ,version)))
                             filename))
             (bytes (base64-decode-string (plist-get res :data))))
        (setq version (or version (plist-get res :version))
              eof (or (eq (plist-get res :eof) t) (zerop (length bytes))))
        (write-region bytes nil dest t 'silent)
        (cl-incf off (length bytes))
        (when (and size (> off (* 2 size)))
          (signal 'rdev-transport-error (list "rdev" "runaway chunked read" filename)))))
    version))

(defun rdev--chunked-write (host local src size expected force filename)
  "Upload the local file SRC (SIZE bytes) to LOCAL on HOST atomically.
EXPECTED is the FileVersion to check (or nil); FORCE skips the check.  Any
non-local exit, including quit, aborts the transfer so the remote
destination stays untouched and the temporary file is removed."
  (let* ((begin (rdev--req host :fs/beginWrite
                           `(:path ,local :size ,size
                             ,@(when (and expected (not force)) `(:expected ,expected))
                             ,@(when force '(:force t)))
                           filename))
         (tid (plist-get begin :tid))
         (len (max 1 (min (rdev--chunk-len) (or (plist-get begin :chunk) rdev--max-chunk))))
         (done nil))
    (unwind-protect
        (let ((off 0) res)
          (while (< off size)
            (let* ((end (min size (+ off len)))
                   (bytes (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (let ((coding-system-for-read 'no-conversion))
                              (insert-file-contents-literally src nil off end))
                            (buffer-string))))
              (rdev--req host :fs/writeChunk
                         `(:tid ,tid :offset ,off :data ,(rdev--b64 bytes)) filename)
              (setq off end)))
          (setq res (rdev--req host :fs/commitWrite `(:tid ,tid :size ,size) filename)
                done t)
          res)
      (unless done
        (ignore-errors (rdev--req host :fs/abortWrite `(:tid ,tid)))))))

(rdev-defop insert-file-contents (filename &optional visit beg end replace)
  (pcase-let* ((filename (expand-file-name filename))
               (`(,host . ,local) (rdev--parse filename))
               (size (and (rdev-conn-has-cap (rdev--conn host) "fs.chunk")
                          (plist-get (ignore-errors (rdev--stat filename)) :size)))
               (chunked (rdev--use-chunks-p host size))
               (tmp (rdev--local-temp-file "rdev-"))
               (res (condition-case err
                        (if chunked
                            (let ((v (rdev--chunked-read host local filename tmp size)))
                              (list :version v :mtime (plist-get v :mtime)))
                          (rdev--req host :fs/read `(:path ,local) filename))
                      (file-missing
                       (delete-file tmp)
                       (when visit
                         (setq buffer-file-name filename)
                         (set-visited-file-modtime '(-1 65535))
                         (set-buffer-modified-p nil))
                       (signal (car err) (cdr err)))
                      (error (delete-file tmp) (signal (car err) (cdr err))))))
    (unwind-protect
        (progn
          (unless chunked
            (rdev--write-local-bytes (base64-decode-string (plist-get res :data)) tmp))
          (let ((r (rdev--real 'insert-file-contents tmp visit beg end replace)))
            (when visit
              (setq buffer-file-name filename
                    buffer-file-truename (abbreviate-file-name filename))
              (setq rdev--version (plist-get res :version))
              (set-visited-file-modtime (rdev--time (plist-get res :mtime)))
              (set-buffer-modified-p nil))
            (list filename (cadr r))))
      (delete-file tmp))))

(rdev-defop file-local-copy (filename)
  (pcase-let* ((`(,host . ,local) (rdev--parse (expand-file-name filename)))
               (res (rdev--req host :fs/read `(:path ,local) filename))
               (tmp (rdev--local-temp-file "rdev-" nil (file-name-extension filename t))))
    (rdev--write-local-bytes (base64-decode-string (plist-get res :data)) tmp)
    tmp))

(defvar-local rdev--version nil
  "FileVersion plist of the remote file as last read or written by this buffer.")
(put 'rdev--version 'permanent-local t)

(defcustom rdev-conflict-functions '(rdev-conflict-prompt)
  "Functions called, in order, when a save finds the remote file changed.
Each is called with the remote file name and returns `overwrite' to save
anyway, `abort' to cancel the save, or nil to defer to the next function.
If none decides, the save fails with an `rdev-conflict' error and the
buffer stays modified; nothing is overwritten silently."
  :type 'hook)

(defun rdev--read-remote-for-diff (filename)
  (let ((res (rdev--req (rdev--host filename) :fs/read
                        `(:path ,(file-local-name filename)) filename)))
    (base64-decode-string (plist-get res :data))))

(defun rdev-conflict-show-diff (filename)
  "Show a diff between the current buffer and the remote copy of FILENAME."
  (let ((remote (rdev--local-temp-file "rdev-remote-"))
        (mine (rdev--local-temp-file "rdev-mine-")))
    (unwind-protect
        (progn
          (rdev--write-local-bytes (rdev--read-remote-for-diff filename) remote)
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region nil nil mine nil 'silent))
          (diff remote mine "-u" 'noasync))
      (delete-file remote) (delete-file mine))))

(defun rdev-conflict-prompt (filename)
  "Interactive resolver for a changed remote FILENAME; nil when non-interactive."
  (unless noninteractive
    (let (choice)
      (while (not (memq choice '(?o ?r ?a)))
        (setq choice
              (car (read-multiple-choice
                    (format "%s changed on the remote since you read it: " filename)
                    '((?c "compare" "Show a diff of your buffer vs the remote file")
                      (?r "refresh" "Discard your edits and reload the remote file")
                      (?o "overwrite" "Overwrite the remote file with your buffer")
                      (?a "abort" "Cancel the save, keep your buffer"))))
              )
        (when (eq choice ?c) (rdev-conflict-show-diff filename)))
      (pcase choice
        (?o (if (yes-or-no-p "Really overwrite the newer remote content? ")
                'overwrite 'abort))
        (?r (when (yes-or-no-p "Discard unsaved edits and reload from remote? ")
              (revert-buffer t t t))
            'abort)
        (_ 'abort)))))

(defun rdev--resolve-conflict (filename)
  (let (decision)
    (run-hook-wrapped 'rdev-conflict-functions
                      (lambda (f) (setq decision (funcall f filename)) decision))
    decision))

(defun rdev--legacy-write-note (host)
  (let ((c (rdev--conn host t)))
    (when (and c (not (eq (rdev-conn-state c) 'legacy-noted)))
      (setf (rdev-conn-state c) 'legacy-noted)
      (message "rdev: agent on %s lacks fs.writeAtomic; saving in place (no conflict detection). Update the agent." host))))

(rdev-defop write-region (start end filename &optional append visit _lockname mustbenew)
  (pcase-let* ((filename (expand-file-name filename))
               (`(,host . ,local) (rdev--parse filename))
               (tmp (rdev--local-temp-file "rdev-")))
    (when (and mustbenew (rdev--stat filename))
      (if (eq mustbenew 'excl)
          (signal 'file-already-exists (list "File exists" filename))
        (unless (yes-or-no-p (format "File %s exists; overwrite anyway? " filename))
          (signal 'file-already-exists (list "File exists" filename)))))
    (unwind-protect
        (let* ((own (and (not append) (equal buffer-file-name filename)
                         rdev--version))
               (_ (rdev--real 'write-region start end tmp nil 'silent))
               (size (file-attribute-size (file-attributes tmp)))
               (atomic (and (not append)
                            (rdev-conn-has-cap (rdev--conn host) "fs.writeAtomic")))
               (chunked (and atomic (rdev--use-chunks-p host size)))
               (data (unless chunked (rdev--b64 (rdev--read-local-bytes tmp))))
               res)
          (if (not atomic)
              (progn
                (unless append (rdev--legacy-write-note host))
                (setq res (rdev--req host :fs/write
                                     `(:path ,local :data ,data
                                       :append ,(if append t :json-false))
                                     filename)))
            (let ((force nil))
              (while (not res)
                (condition-case nil
                    (setq res (if chunked
                                  (rdev--chunked-write host local tmp size own force filename)
                                (rdev--req
                                 host :fs/writeAtomic
                                 `(:path ,local :data ,data
                                   ,@(when (and own (not force)) `(:expected ,own))
                                   ,@(when force '(:force t)))
                                 filename)))
                  (rdev-conflict
                   (pcase (rdev--resolve-conflict filename)
                     ('overwrite (setq force t))
                     (_ (signal 'rdev-conflict
                                (list "rdev" "File changed on remote since it was read; not saved"
                                      filename))))))))
            (unless (plist-get res :atomic)
              (message "rdev: %s was written in place (hard link or special file)" filename)))
          (rdev--invalidate host local)
          (let ((ver (plist-get res :version)))
            (when (or (eq visit t) (stringp visit))
              (when (stringp visit) (setq buffer-file-name visit))
              (setq rdev--version (or ver rdev--version))
              (set-visited-file-modtime
               (rdev--time (or (plist-get res :mtime) (plist-get ver :mtime))))
              (set-buffer-modified-p nil)))
          (when (or (eq visit t) (null visit) (stringp visit))
            (message "Wrote %s" filename))
          nil)
      (delete-file tmp))))

(rdev-defop verify-visited-file-modtime (&optional buf)
  (with-current-buffer (or buf (current-buffer))
    (let ((mt (visited-file-modtime)))
      (cond ((not buffer-file-name) t)
            ((not (time-less-p 0 mt)) (not (rdev--stat buffer-file-name)))
            (t (let ((st (rdev--stat buffer-file-name)))
                 (and st (time-equal-p mt (rdev--time (plist-get st :mtime))))))))))

(rdev-defop set-visited-file-modtime (&optional time)
  (if time
      (rdev--real 'set-visited-file-modtime time)
    (let ((st (and buffer-file-name (rdev--stat buffer-file-name))))
      (rdev--real 'set-visited-file-modtime
                  (if st (rdev--time (plist-get st :mtime)) '(-1 65535))))))

(rdev-defop delete-file (file &optional _trash)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name file))))
    (condition-case nil
        (rdev--req host :fs/delete `(:path ,local) file)
      (file-missing nil))
    (rdev--invalidate host local)
    nil))

(defun rdev--target-name (file newname)
  (if (directory-name-p newname)
      (expand-file-name (file-name-nondirectory (directory-file-name file)) newname)
    (expand-file-name newname)))

(defun rdev--check-overwrite (newname ok-if-already-exists)
  (when (and (file-exists-p newname)
             (not (eq ok-if-already-exists t))
             (or (not ok-if-already-exists)
                 (not (yes-or-no-p (format "File %s already exists; overwrite? " newname)))))
    (signal 'file-already-exists (list "File already exists" newname))))

(rdev-defop copy-file (file newname &optional ok-if-already-exists keep-time
                            _preserve-uid-gid preserve-permissions)
  (let* ((file (expand-file-name file))
         (newname (rdev--target-name file newname))
         (src (rdev--parse file)) (dst (rdev--parse newname)))
    (rdev--check-overwrite newname ok-if-already-exists)
    (cond
     ((and src dst (equal (car src) (car dst)))
      (rdev--req (car src) :fs/copy
                 `(:src ,(cdr src) :dst ,(cdr dst)
                   :preserve ,(if (or keep-time preserve-permissions) t :json-false))
                 file)
      (rdev--invalidate (car dst) (cdr dst)))
     (t ;; Go through a local temporary copy.
      (let ((tmp (if src (file-local-copy file) file)))
        (unwind-protect
            (if dst
                (progn
                  (rdev--req (car dst) :fs/write
                             `(:path ,(cdr dst) :data ,(rdev--b64 (rdev--read-local-bytes tmp)))
                             newname)
                  (rdev--invalidate (car dst) (cdr dst)))
              (rdev--real 'copy-file tmp newname t))
          (when src (delete-file tmp)))
        (when keep-time
          (set-file-times newname (file-attribute-modification-time (file-attributes file)))))))
    nil))

(rdev-defop rename-file (file newname &optional ok-if-already-exists)
  (let* ((file (expand-file-name file))
         (newname (rdev--target-name file newname))
         (src (rdev--parse file)) (dst (rdev--parse newname)))
    (rdev--check-overwrite newname ok-if-already-exists)
    (if (and src dst (equal (car src) (car dst)))
        (progn
          (rdev--req (car src) :fs/rename `(:src ,(cdr src) :dst ,(cdr dst)) file)
          (rdev--invalidate-tree (car src) (cdr src) (cdr dst)))
      (copy-file file newname t t)
      (if (file-directory-p file) (delete-directory file t) (delete-file file)))
    (rdev--forget-renamed-version file)
    nil))

(defun rdev--forget-renamed-version (file)
  "Drop the remote version held by a buffer visiting FILE, which was renamed.
This Emacs moved the file away itself (most often `backup-buffer' renaming
it to FILE~ just before a save), so the old version describes no file at
FILE and must not make the next save report a conflict.  The save then
recreates FILE, as it would locally; external edits and deletions are
still detected because only this Emacs's own rename clears the version."
  (let ((buf (get-file-buffer file)))
    (when buf
      (with-current-buffer buf (setq rdev--version nil)))))

(rdev-defop set-file-modes (file mode &optional flag)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name file))))
    (rdev--req host :fs/chmod `(:path ,local :mode ,mode
                                :follow ,(if (eq flag 'nofollow) :json-false t))
               file)
    (rdev--invalidate host local)
    nil))

(rdev-defop set-file-times (file &optional time flag)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name file))))
    (rdev--req host :fs/utime
               `(:path ,local
                 :mtime_ns ,(car (time-convert (or time nil) 1000000000))
                 :follow ,(if (eq flag 'nofollow) :json-false t))
               file)
    (rdev--invalidate host local)
    t))

(rdev-defop make-symbolic-link (target linkname &optional ok-if-already-exists)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name linkname))))
    (rdev--check-overwrite linkname ok-if-already-exists)
    (rdev--req host :fs/symlink `(:target ,(or (cdr (rdev--parse target)) target)
                                  :link ,local :overwrite t)
               linkname)
    (rdev--invalidate host local)
    nil))

(rdev-defop add-name-to-file (file newname &optional ok-if-already-exists)
  (pcase-let ((`(,host . ,local) (rdev--parse (expand-file-name newname))))
    (rdev--check-overwrite newname ok-if-already-exists)
    (rdev--req host :fs/link `(:src ,(cdr (rdev--parse (expand-file-name file)))
                               :dst ,local :overwrite t)
               newname)
    (rdev--invalidate host local)
    nil))

;;;; Processes

(defun rdev--env ()
  "Environment changes Emacs made locally, as a hash table for the remote."
  (let ((env (make-hash-table :test #'equal)))
    (dolist (e process-environment)
      (when (and (not (member e initial-environment))
                 (string-match "\\`\\([^=]+\\)=\\(\\(?:.\\|\n\\)*\\)\\'" e))
        (let ((k (match-string 1 e)))
          (unless (or (member k rdev-env-exclude) (gethash k env))
            (puthash k (match-string 2 e) env)))))
    env))

(defun rdev--program (program)
  "Remote program name for PROGRAM.
A local-only shell (e.g. the user's zsh/fish in `shell-file-name') that
does not exist on the remote is replaced by /bin/sh."
  (let ((p (or (cdr (rdev--parse program)) program))
        (prefix (file-remote-p default-directory)))
    (if (and prefix (file-name-absolute-p p)
             (member p (list (default-value 'shell-file-name)
                             (getenv "SHELL")))
             (not (file-executable-p (concat prefix p))))
        "/bin/sh"
      p)))

(defun rdev--decode (bytes program)
  (let ((cs (or coding-system-for-read
                (car-safe (find-operation-coding-system 'call-process program))
                'undecided)))
    (setq last-coding-system-used cs)
    (decode-coding-string bytes cs)))

(rdev-defop process-file (program &optional infile buffer _display &rest args)
  (let* ((host (rdev--host (expand-file-name default-directory)))
         (cwd (file-local-name (expand-file-name default-directory)))
         (stderr-dest (and (consp buffer) (cadr buffer)))
         (out (if (consp buffer) (car buffer) buffer))
         (merge (not (consp buffer)))
         (stdin (and infile
                     (rdev--b64 (if (rdev--parse (expand-file-name infile))
                                    (let ((tmp (file-local-copy infile)))
                                      (prog1 (rdev--read-local-bytes tmp) (delete-file tmp)))
                                  (rdev--read-local-bytes infile)))))
         (res (condition-case err
                  (jsonrpc-request
                   (rdev-conn-rpc (rdev--conn host)) :exec/run
                   `(:cmd ,(vconcat (cons (rdev--program program) args))
                     :cwd ,cwd :stdin ,stdin :env ,(rdev--env)
                     :mergeStderr ,(if (or merge (eq stderr-dest t)) t :json-false))
                   :timeout most-positive-fixnum)
                (jsonrpc-error
                 (if (equal (plist-get (alist-get 'jsonrpc-error-data (cdr err)) :errno)
                            "ENOENT")
                     (signal 'file-missing
                             (list "Searching for program" "No such file or directory"
                                   program))
                   (rdev--signal-error err program))))))
    ;; An arbitrary command may have changed anything under this host.
    (when-let* ((c (rdev--conn host t))) (clrhash (rdev-conn-cache c)))
    (let ((stdout (base64-decode-string (plist-get res :stdout)))
          (stderr (base64-decode-string (plist-get res :stderr))))
      (when (and (stringp stderr-dest) (> (length stderr) 0))
        (let ((coding-system-for-write 'no-conversion))
          (write-region stderr nil stderr-dest)))
      (when (and out (not (eql out 0)))
        (with-current-buffer (if (eq out t) (current-buffer) (get-buffer-create out))
          (let ((inhibit-read-only t))
            (insert (rdev--decode stdout program)))))
      (if (plist-get res :signal)
          (format "Signal %s" (plist-get res :signal))
        (plist-get res :code)))))

;;;;; Streaming processes via the local relay

(defvar rdev--relay-server nil)
(defvar rdev--next-chan 0)

(defun rdev--relay-dir ()
  "Return the private (mode 0700, user-owned) directory for relay sockets.
Prefers $XDG_RUNTIME_DIR/rdev, falling back to ~/.cache/rdev/run.  Signals
`rdev-transport-error' if an existing directory is owned by someone else."
  (let* ((base (getenv "XDG_RUNTIME_DIR"))
         (dir (if (and base (file-directory-p base))
                  (expand-file-name "rdev" base)
                (expand-file-name "~/.cache/rdev/run"))))
    (with-file-modes #o077 (make-directory dir t))
    (let ((attrs (file-attributes dir 'integer)))
      (unless (= (file-attribute-user-id attrs) (user-uid))
        (signal 'rdev-transport-error
                (list (format "rdev: relay directory %s is not owned by you" dir))))
      (unless (= (logand (file-modes dir) #o077) 0)
        (set-file-modes dir #o700)))
    dir))

(defvar rdev--relay-token nil
  "Per-session secret a relay must present in its hello frame.
Emacs Lisp cannot query SO_PEERCRED on an accepted socket, so the private
directory and the 0600 socket are backed by this token: it is passed to the
relay in its environment (not argv, which other users can read) and a
connection whose hello frame lacks it is dropped before it can write to or
signal any remote process (T065).")

(defun rdev--relay-token ()
  "Return the relay token, creating a random one on first use."
  (or rdev--relay-token
      (setq rdev--relay-token
            (let ((raw (or (ignore-errors
                             (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally "/dev/urandom" nil 0 16)
                               (buffer-string)))
                           ;; Fallback: Emacs' own CSPRNG-seeded generator.
                           (progn (random t)
                                  (apply #'unibyte-string
                                         (cl-loop repeat 16 collect (random 256)))))))
              (mapconcat (lambda (b) (format "%02x" b)) raw "")))))

(defun rdev--relay-socket ()
  (expand-file-name (format "rdev-%d.sock" (emacs-pid)) (rdev--relay-dir)))

(defun rdev--ensure-relay-server ()
  "Start the relay listener on a 0600 socket inside a 0700 directory (D-10).
Emacs Lisp cannot query SO_PEERCRED, so access control rests on the private
directory, the socket mode and the per-session token (see
function `rdev--relay-token')."
  (unless (process-live-p rdev--relay-server)
    (let ((path (rdev--relay-socket)))
      (ignore-errors (delete-file path))
      (setq rdev--relay-server
            (with-file-modes #o077
              ;; Local relay sockets are created under umask 077 so only this
              ;; user can connect; each accepted socket is one remote process.
              (make-network-process
               :name "rdev-relay-server" :server t :family 'local :service path
               :coding 'binary :noquery t
               :filter #'rdev--relay-filter :sentinel #'rdev--relay-sentinel)))
      (set-file-modes path #o600))))

(defun rdev--u32 (n)
  (unibyte-string (logand (ash n -24) 255) (logand (ash n -16) 255)
                  (logand (ash n -8) 255) (logand n 255)))

(defconst rdev--relay-piece 8192
  "Size of the pieces a large relay frame is written in.
A blocking `process-send-string' to a full local socket retries only every
20 ms, which capped remote output at ~330 KB/s on macOS (8 KiB socket buffer).
Writing pieces with a short `accept-process-output' between them lets the
relay drain the socket and measured ~9 MB/s (see `rdev--relay-write').")

(defun rdev--relay-write (sock string)
  "Write STRING to relay SOCK in `rdev--relay-piece' sized pieces."
  (let ((len (length string)) (i 0))
    (if (<= len rdev--relay-piece)
        (process-send-string sock string)
      (while (and (< i len) (process-live-p sock))
        (let ((j (min len (+ i rdev--relay-piece))))
          (process-send-string sock (substring string i j))
          (setq i j)
          ;; Wait on the relay's own process only (JUST-THIS-ONE): reading the
          ;; ssh stream here would pull the whole remote output into Emacs
          ;; ahead of the relay and defeat end-to-end backpressure.
          (when (< i len)
            (let ((proc (when-let* ((chan (process-get sock 'chan)))
                          (rdev-chan-proc chan))))
              (accept-process-output (if (process-live-p proc) proc sock)
                                     0.0005 nil t))))))))

(defun rdev--relay-transport (sock)
  "Return the jsonrpc transport process that feeds relay SOCK, or nil."
  (when-let* ((chan (process-get sock 'chan))
              (conn (gethash (rdev-chan-host chan) rdev--conns))
              (rpc (rdev-conn-rpc conn)))
    (and (fboundp 'jsonrpc--process)
         (let ((p (ignore-errors (jsonrpc--process rpc))))
           (and (processp p) (process-live-p p) p)))))

(defun rdev--relay-send (sock type payload)
  "Send one TYPE frame carrying PAYLOAD to relay SOCK, in order.
Two hazards are handled here, both found by running the flood test against a
real remote host:

* `process-send-string' blocks and, while blocked, runs other process
  filters -- including the one delivering the next `proc/out', which calls
  this function again and nests until `excessive-lisp-nesting'.  A call made
  while a send is in progress only queues its frame; the outermost call drains
  the queue in order.
* Backpressure: while the relay drains, reads from the transport are paused
  (its filter is set to t), so the ssh pipe fills, the agent's bounded queue
  fills and the remote child blocks.  Without this Emacs pulled the whole
  remote output into memory ahead of the relay (RSS grew ~3x the output)."
  (when (process-live-p sock)
    (let ((frame (concat type (rdev--u32 (length payload)) payload)))
      (if (process-get sock 'rdev-sending)
          (process-put sock 'rdev-outq (cons frame (process-get sock 'rdev-outq)))
        (let* ((transport (rdev--relay-transport sock))
               (old (and transport (process-filter transport))))
          (process-put sock 'rdev-sending t)
          ;; Filter t stops Emacs from reading the transport (restored below).
          (when (and old (not (eq old t))) (set-process-filter transport t))
          (unwind-protect
              (progn
                (rdev--relay-write sock frame)
                (let (q)
                  (while (and (process-live-p sock)
                              (setq q (process-get sock 'rdev-outq)))
                    (process-put sock 'rdev-outq nil)
                    (dolist (f (nreverse q))
                      (when (process-live-p sock) (rdev--relay-write sock f))))))
            (process-put sock 'rdev-sending nil)
            (unless (process-live-p sock) (process-put sock 'rdev-outq nil))
            (when (and old (not (eq old t)) (process-live-p transport)
                       (eq (process-filter transport) t))
              (set-process-filter transport old))))))))

(defconst rdev--relay-max-frame (* 1024 1024)
  "Largest relay payload accepted from the local relay process (D-09).")

(defun rdev--relay-abort (sock why)
  "Close relay SOCK after protocol violation WHY and kill its remote process."
  (message "rdev: relay protocol error: %s" why)
  (when-let* ((chan (process-get sock 'chan)))
    (unless (rdev-chan-exited chan)
      (rdev--notify (rdev-chan-host chan) :proc/signal
                    `(:id ,(rdev-chan-id chan) :sig 9))
      (rdev--chan-del chan)))
  (process-put sock 'buf nil)
  (when (process-live-p sock) (delete-process sock)))

(defun rdev--relay-filter (sock string)
  "Parse TYPE(1) LEN(4) PAYLOAD frames of STRING from relay SOCK; never signal."
  (condition-case err
      (let ((buf (concat (or (process-get sock 'buf) "") string))
            (more t))
        (while (and more (>= (length buf) 5))
          (let ((n (+ (ash (aref buf 1) 24) (ash (aref buf 2) 16)
                      (ash (aref buf 3) 8) (aref buf 4)))
                (type (aref buf 0)))
            (cond
             ((not (memq type '(?H ?I ?C ?S ?W)))
              (rdev--relay-abort sock (format "unknown frame type %S" type))
              (setq buf "" more nil))
             ((> n rdev--relay-max-frame)
              (rdev--relay-abort sock (format "frame length %d exceeds limit" n))
              (setq buf "" more nil))
             ((< (length buf) (+ 5 n))
              (setq more nil))
             (t
              (let ((payload (substring buf 5 (+ 5 n))))
                (setq buf (substring buf (+ 5 n)))
                (process-put sock 'buf buf)
                (rdev--relay-frame sock type payload))))))
        (when (process-live-p sock) (process-put sock 'buf buf)))
    (error (rdev--relay-abort sock (error-message-string err)))))

(defun rdev--relay-frame (sock type payload)
  (pcase type
    (?H (let* ((parts (split-string payload))
               (token (nth 3 parts)))
          (if (not (and token (string= token (rdev--relay-token))))
              ;; Not our relay (or a stale one): refuse before it can act (T065).
              (rdev--relay-abort sock "relay authentication failed")
            (pcase-let* ((`(,id ,rows ,cols) (mapcar #'string-to-number (seq-take parts 3)))
                         (chan (rdev--chan-find-id id)))
              (when chan
                (setf (rdev-chan-sock chan) sock)
                (process-put sock 'chan chan)
                (rdev--spawn chan rows cols))))))
    (_ (when-let* ((chan (process-get sock 'chan)))
         (let ((host (rdev-chan-host chan)) (id (rdev-chan-id chan)))
           (pcase type
             (?I (rdev--notify host :proc/write `(:id ,id :data ,(rdev--b64 payload))))
             (?C (rdev--notify host :proc/eof `(:id ,id)))
             (?S (rdev--notify host :proc/signal `(:id ,id :sig ,(string-to-number payload))))
             (?W (pcase-let ((`(,r ,c) (mapcar #'string-to-number (split-string payload))))
                   (rdev--notify host :proc/resize `(:id ,id :rows ,r :cols ,c))))))))))

(defun rdev--relay-sentinel (sock _event)
  (unless (process-live-p sock)
    (when-let* ((chan (process-get sock 'chan)))
      (unless (rdev-chan-exited chan)
        ;; The local relay was killed: kill the remote process too.
        (rdev--notify (rdev-chan-host chan) :proc/signal `(:id ,(rdev-chan-id chan) :sig 9))
        (rdev--chan-del chan)))))

(defun rdev--spawn (chan rows cols)
  (let ((sock (rdev-chan-sock chan)))
    (condition-case err
        (jsonrpc-async-request
         (rdev-conn-rpc (rdev--conn (rdev-chan-host chan))) :proc/spawn
         `(:id ,(rdev-chan-id chan) :cmd ,(vconcat (rdev-chan-cmd chan))
           :cwd ,(rdev-chan-cwd chan) :env ,(rdev-chan-env chan)
           :pty ,(if (rdev-chan-pty chan) t :json-false)
           :mergeStderr ,(if (rdev-chan-merge chan) t :json-false)
           :rows ,rows :cols ,cols)
         :success-fn #'ignore
         :error-fn (lambda (e)
                     (rdev--relay-send sock "E" (format "rdev: %s: %s\n"
                                                         (car (rdev-chan-cmd chan))
                                                         (plist-get e :message)))
                     (rdev--chan-exit (rdev-chan-host chan) (rdev-chan-id chan) 127)))
      (error (rdev--relay-send sock "E" (format "rdev: %s\n" (error-message-string err)))
             (rdev--chan-exit (rdev-chan-host chan) (rdev-chan-id chan) 255)))))

(defun rdev--chan-exit (host id code)
  (when-let* ((chan (rdev--chan-get host id)))
    (setf (rdev-chan-exited chan) t)
    (rdev--chan-del chan)
    (if (rdev-chan-sock chan)
        (rdev--relay-send (rdev-chan-sock chan) "X" (number-to-string code))
      (when (process-live-p (rdev-chan-proc chan))
        (kill-process (rdev-chan-proc chan))))))

(defun rdev--conn-hosts-of (rpc)
  "Return every host name whose connection object is RPC.
Aliases of one machine share a connection (FR-008), so there can be several."
  (let (found)
    (maphash (lambda (h c) (when (eq (rdev-conn-rpc c) rpc) (push h found)))
             rdev--conns)
    found))

(defun rdev--conn-host-of (rpc)
  "Return one host whose connection object is RPC, or nil.
Prefer `rdev--conn-hosts-of' when the answer is used to look up per-host state:
with aliases sharing the connection, any of the names may own it."
  (car (rdev--conn-hosts-of rpc)))

(defun rdev--chan-for (rpc id)
  "Channel ID, only if it belongs to a host that RPC talks to (D-06).
Every alias sharing RPC is tried; ids of other connections never match."
  (cl-some (lambda (host) (rdev--chan-get host id)) (rdev--conn-hosts-of rpc)))

(defvar rdev-watch-event-function nil
  "Function called with (RPC PARAMS) for each `watch/event' notification.
RPC is the jsonrpc connection.
Set by rdev-notify.el.")

(defvar rdev-search-result-function nil
  "Function called with the PARAMS plist of each `search/result' notification.
Bound by `rdev-search' for the duration of one search; nil otherwise.")

(defun rdev--dispatch (conn method params)
  (pcase method
    ('search/result
     (when rdev-search-result-function
       (funcall rdev-search-result-function params)))
    ('proc/out
     (when-let* ((chan (rdev--chan-for conn (plist-get params :id))))
       (rdev--relay-send (rdev-chan-sock chan)
                         (if (equal (plist-get params :stream) "err") "E" "O")
                         (base64-decode-string (plist-get params :data)))))
    ('watch/event
     (when rdev-watch-event-function
       (funcall rdev-watch-event-function conn params)))
    ('proc/exit (when-let* ((chan (rdev--chan-for conn (plist-get params :id))))
                 (rdev--chan-exit (rdev-chan-host chan) (plist-get params :id)
                                  (plist-get params :code))))))

;;;; Client-side protocol validation (FR-029)
;;
;; The agent is trusted to be an rdev agent, not to be bug-free: a truncated
;; or hostile peer must not be able to raise an error out of the process
;; filter (which would wedge the connection) or satisfy a request with a
;; malformed reply.  Every message is checked before jsonrpc.el sees it.

(defvar rdev--protocol-errors nil
  "Most recent protocol violations seen from agents, newest first (max 50).")

(defun rdev--message-problem (_conn msg)
  "Return a string describing why MSG is not valid JSON-RPC, or nil."
  (cond
   ((not (and (consp msg) (plistp msg))) "message is not an object")
   ((not (equal (plist-get msg :jsonrpc) "2.0")) "missing or unsupported jsonrpc version")
   ((plist-member msg :method)
    (let ((m (plist-get msg :method)) (id (plist-get msg :id)))
      (cond ((not (and (stringp m) (not (string-empty-p m)))) "method is not a string")
            ((and (plist-member msg :params)
                  (let ((p (plist-get msg :params))) (not (or (null p) (listp p) (vectorp p)))))
             "params is neither an object nor an array")
            ((and id (not (or (stringp id) (integerp id)))) "id has an invalid type"))))
   (t
    (let ((id (plist-get msg :id))
          (has-result (plist-member msg :result))
          (has-error (plist-member msg :error)))
      (cond ((not (or (stringp id) (integerp id))) "response without a usable id")
            ((and has-result has-error) "response has both result and error")
            ((not (or has-result has-error)) "response has neither result nor error")
            ((and has-error
                  (let ((e (plist-get msg :error)))
                    (not (and (plistp e) (integerp (plist-get e :code))
                              (stringp (plist-get e :message))))))
             "error object lacks integer code or string message"))))))

(defun rdev--protocol-violation (conn msg why)
  "Record that CONN sent MSG, invalid because WHY."
  (let ((host (ignore-errors (rdev--conn-host-of conn))))
    (push (list (float-time) host why) rdev--protocol-errors)
    (setq rdev--protocol-errors (seq-take rdev--protocol-errors 50))
    (when host
      (ignore-errors
        (rdev-state-log (rdev-state-session-key host) "protocol violation: %s (%.80s)"
                        why (prin1-to-string msg))))))

(defun rdev--receive-guard (orig conn msg)
  "Around-advice (ORIG) for `jsonrpc-connection-receive' of CONN and MSG."
  (if (not (eq (ignore-errors (slot-value conn '-notification-dispatcher))
               #'rdev--dispatch))
      (funcall orig conn msg)
    (condition-case err
        (if-let* ((why (rdev--message-problem conn msg)))
            (progn
              (rdev--protocol-violation conn msg why)
              ;; A malformed reply to a pending request fails that request
              ;; now instead of leaving it to time out.
              (let ((id (and (consp msg) (plistp msg) (not (plist-member msg :method))
                             (plist-get msg :id))))
                (when (and id (assq id (jsonrpc--continuations conn)))
                  (funcall orig conn
                           `(:jsonrpc "2.0" :id ,id
                             :error (:code -32600
                                     :message ,(format "malformed response from agent: %s" why)))))))
          (funcall orig conn msg))
      (error (rdev--protocol-violation conn msg (format "handler error: %s" (error-message-string err)))))))

(advice-add 'jsonrpc-connection-receive :around #'rdev--receive-guard)

(rdev-defop make-process (&rest args)
  (let* ((host (rdev--host (expand-file-name default-directory)))
         (cwd (file-local-name (expand-file-name default-directory)))
         (command (plist-get args :command))
         (ctype (let ((c (if (plist-member args :connection-type)
                             (plist-get args :connection-type)
                           process-connection-type)))
                  (if (consp c) (car c) c)))
         (pty (memq ctype '(t pty)))
         (id (cl-incf rdev--next-chan))
         (chan (rdev--make-chan
                :id id :host host :cwd cwd :pty pty
                :merge (not (plist-get args :stderr))
                :env (rdev--env)
                :cmd (cons (rdev--program (car command)) (cdr command)))))
    (rdev--conn host)                   ; connect now, synchronously
    (rdev--ensure-relay-server)
    (rdev--chan-put chan)
    (let* ((default-directory temporary-file-directory)
           (kw (cl-loop for (k v) on args by #'cddr
                        unless (memq k '(:command :file-handler))
                        append (list k v)))
           (process-environment
            (cons (concat "RDEV_RELAY_TOKEN=" (rdev--relay-token)) process-environment))
           (proc (apply #'make-process
                        :command (list rdev-python "-u" rdev--relay-file
                                       (rdev--relay-socket) (number-to-string id))
                        kw)))
      (process-put proc 'remote-command command)
      (process-put proc 'rdev-host host)
      (setf (rdev-chan-proc chan) proc)
      proc)))

(rdev-defop start-file-process (name buffer program &rest args)
  ;; The local process is a relay to the remote one; its sentinel/ownership
  ;; handling (kill the remote process if the relay dies) is in
  ;; `rdev--relay-sentinel'.
  (make-process :name name :buffer buffer
                :command (and program (cons program args))
                :file-handler t))

(defun rdev--with-remote-shell (op args)
  "Run the stock file operation OP on ARGS with remote process primitives."
  ;; Reuse the stock implementation (output buffers, async `&', error
  ;; buffers ...) but make its local process primitives remote.
  (let ((orig-call (symbol-function 'call-process))
        (orig-start (symbol-function 'start-process))
        (orig-region (symbol-function 'call-process-region))
        (dir default-directory))
    (cl-letf (((symbol-function 'call-process-region)
               ;; `shell-command-on-region' (and so `shell-command' with an
               ;; output buffer other than the current one) feeds the region
               ;; through this primitive, which would otherwise run locally.
               (lambda (start end program &optional delete buffer display &rest rest)
                 (if (rdev--host (expand-file-name default-directory))
                     (let ((tmp (rdev--local-temp-file "rdev-stdin"))
                           (coding-system-for-write 'no-conversion))
                       (unwind-protect
                           (progn
                             (if (stringp start)
                                 (write-region start nil tmp nil 'silent)
                               (write-region (or start (point-min)) (or end (point-max))
                                             tmp nil 'silent))
                             (when (and delete (not (stringp start)))
                               (delete-region (or start (point-min)) (or end (point-max))))
                             (apply (gethash 'process-file rdev--ops)
                                    program tmp buffer display rest))
                         (delete-file tmp)))
                   (apply orig-region start end program delete buffer display rest))))
              ((symbol-function 'call-process)
               (lambda (program &rest rest)
                 (if (rdev--host (expand-file-name default-directory))
                     (apply (gethash 'process-file rdev--ops) program rest)
                   (apply orig-call program rest))))
              ((symbol-function 'start-process)
               (lambda (name buffer program &rest rest)
                 (if (rdev--host (expand-file-name default-directory))
                     (apply (gethash 'start-file-process rdev--ops) name buffer program rest)
                   (apply orig-start name buffer program rest)))))
      (pcase-let ((`(,sh ,sw) (with-connection-local-variables
                               (list shell-file-name shell-command-switch))))
        ;; Bind globally: shell-command switches to its output buffer.
        (let ((shell-file-name sh)
              (shell-command-switch sw)
              (default-directory dir))
          (apply #'rdev--real op args))))))

(rdev-defop shell-command (&rest args) (rdev--with-remote-shell 'shell-command args))

;;;; Connection-local defaults: remote shells are POSIX sh/bash.

(connection-local-set-profile-variables
 'rdev-shell-profile
 '((shell-file-name . "/bin/sh")
   (shell-command-switch . "-c")
   (explicit-shell-file-name . "/bin/bash")
   (vc-git-program . "git")))
(connection-local-set-profiles '(:protocol "rdev") 'rdev-shell-profile)

;;;; Registration

(defun rdev--register ()
  (setq file-name-handler-alist
        (cons (cons "\\`/rdev:" #'rdev-file-name-handler)
              ;; Drop every other /rdev: entry too (e.g. a lazy-load stub).
              (assoc-delete-all "\\`/rdev:"
                                (rassq-delete-all 'rdev-file-name-handler
                                                  file-name-handler-alist)))))
(rdev--register)
(defvar tramp-ignored-file-name-regexp)

(defun rdev--tramp-ignore-rdev ()
  "Make TRAMP ignore `/rdev:' names without discarding the user's setting.
Only adds an alternative to `tramp-ignored-file-name-regexp'; a value that
already covers `/rdev:' is left alone, so calling this twice is harmless."
  (let ((cur (and (boundp 'tramp-ignored-file-name-regexp)
                  tramp-ignored-file-name-regexp)))
    (cond ((null cur)
           (setq tramp-ignored-file-name-regexp "\\`/rdev:"))
          ((string-match-p cur "/rdev:h:/x") nil)
          (t (setq tramp-ignored-file-name-regexp
                   (concat "\\(?:" cur "\\)\\|\\`/rdev:"))))))

(with-eval-after-load 'tramp
  (rdev--tramp-ignore-rdev)
  (rdev--register))
(rdev--tramp-ignore-rdev)

;;;; Commands

(defconst rdev--ssh-config-max-depth 10
  "Maximum `Include' nesting when reading ssh configuration files.")

(defun rdev--ssh-config-files ()
  "Return the ssh configuration files to read, in order.
The user and system configs are included, plus any `-F FILE' given in
`rdev-ssh-args' (the test fixtures use that form)."
  (let ((files (list (expand-file-name "~/.ssh/config")
                     "/etc/ssh/ssh_config"))
        (args rdev-ssh-args))
    (while args
      (let ((arg (pop args)))
        (cond ((equal arg "-F")
               (when args (push (expand-file-name (pop args)) files)))
              ((and (stringp arg) (string-prefix-p "-F" arg))
               (push (expand-file-name (substring arg 2)) files)))))
    (nreverse files)))

(defun rdev--ssh-config-blocks ()
  "Return the `Host' pattern lists from the ssh configuration.
`Include' files are followed; `Match' conditions are not evaluated, so a
`Host' line inside one still counts."
  (let ((seen (make-hash-table :test #'equal))
        (blocks nil))
    (cl-labels ((walk (file depth)
                  (when (and (< depth rdev--ssh-config-max-depth)
                             (not (gethash file seen))
                             (file-regular-p file)
                             (file-readable-p file))
                    (puthash file t seen)
                    (with-temp-buffer
                      (insert-file-contents file)
                      (goto-char (point-min))
                      (let ((dir (file-name-directory file)))
                        (while (not (eobp))
                          (cond
                           ((looking-at "^\\s-*Include\\s-+\\(.+\\)$")
                            (dolist (pat (split-string (match-string 1)))
                              (dolist (f (file-expand-wildcards
                                          (expand-file-name pat dir)))
                                (walk f (1+ depth)))))
                           ((looking-at "^\\s-*Host\\s-+\\(.+\\)$")
                            (push (split-string (match-string 1)) blocks)))
                          (forward-line 1)))))))
      (dolist (f (rdev--ssh-config-files))
        (walk f 0)))
    (nreverse blocks)))

(defun rdev--ssh-hosts ()
  "Literal host names from the ssh configuration plus configured targets."
  (let (hosts)
    (dolist (block (rdev--ssh-config-blocks))
      (dolist (h block)
        (unless (or (string-prefix-p "!" h)
                    (string-match-p "[*?]" h))
          (push h hosts))))
    (delete-dups (append (mapcar #'car rdev-hosts) (nreverse hosts)))))

(defun rdev--target-completion ()
  "Host keys for target prompts: configured/known hosts plus containers.
Configured `rdev-hosts' keys come first (they win over same-named ssh
aliases), then ssh-config hosts, then running containers as `docker+NAME'
keys.  Containers come from the engines of configured Docker targets and,
when `rdev-docker-auto-detect' is non-nil, the local engine.  Discovery
never blocks the prompt beyond `rdev-docker-discovery-wait' and an
unreachable engine adds nothing."
  (delete-dups
   (append (rdev--ssh-hosts)
           (when (or rdev-docker-auto-detect (rdev--any-docker-target-p))
             (condition-case nil
                 (progn (require 'rdev-docker)
                        (rdev-docker--completion-hosts))
               (error nil))))))

(defun rdev--target-table ()
  "Completion table over `rdev--target-completion', recomputed on demand.
Containers found by a background discovery appear on the next TAB."
  (completion-table-dynamic (lambda (_) (rdev--target-completion))))

;;;###autoload
(defun rdev-find-file (host)
  "Open a file on HOST through the rdev server."
  (interactive (list (completing-read "rdev host: " (rdev--target-table))))
  (rdev--conn host)
  (let ((default-directory (concat (rdev--prefix host) "~/")))
    (call-interactively #'find-file)))

;;;###autoload
(defun rdev-shell (host)
  "Open an interactive remote shell on HOST (remote PTY)."
  (interactive (list (if (rdev--host default-directory)
                         (rdev--host default-directory)
                       (completing-read "rdev host: " (rdev--target-table)))))
  (let ((default-directory (if (equal (rdev--host default-directory) host)
                               default-directory
                             (concat (rdev--prefix host) "~/"))))
    (shell (generate-new-buffer-name (format "*rdev-shell %s*" host)))))

(defun rdev-disconnect (host)
  "Close the connection to HOST."
  (interactive (list (completing-read "Disconnect: " (hash-table-keys rdev--conns) nil t)))
  (when-let* ((c (gethash host rdev--conns)))
    (rdev-state-user-disconnect (rdev-state-session-key host))
    (jsonrpc-shutdown (rdev-conn-rpc c) t)
    (remhash host rdev--conns)))

;;;###autoload
(defun rdev-reconnect (host)
  "Drop and re-establish the connection to HOST now.
Remote processes started on the old connection are not carried over."
  (interactive (list (completing-read "Reconnect: "
                                      (delete-dups
                                       (append (hash-table-keys rdev--conns)
                                               (mapcar #'car rdev-hosts)))
                                      nil nil)))
  (when (gethash host rdev--conns) (rdev-disconnect host))
  (rdev--connect host))

(defun rdev-clear-cache (&optional host)
  "Drop cached remote file attributes for all hosts.
With a prefix argument, prompt for a single HOST to clear instead."
  (interactive (list (when current-prefix-arg
                       (completing-read "Clear cache for host: "
                                        (hash-table-keys rdev--conns) nil t))))
  (if host
      (when-let* ((c (gethash host rdev--conns))) (clrhash (rdev-conn-cache c)))
    (maphash (lambda (_ c) (clrhash (rdev-conn-cache c))) rdev--conns)))

(defun rdev-status ()
  "Show connections and live remote processes."
  (interactive)
  (with-help-window "*rdev*"
    (princ "rdev connections\n\n")
    (maphash (lambda (host c)
               (princ (format "  %-20s home=%s  cached=%d  %s\n" host (rdev-conn-home c)
                              (hash-table-count (rdev-conn-cache c))
                              (concat (if (jsonrpc-running-p (rdev-conn-rpc c)) "up" "DOWN")
                                      (format "  state=%s" (rdev-state (rdev-state-session-key host))))))
               ;; Docker targets show their container and engine.
               (when (eq (rdev-conn-transport c) 'docker)
                 (princ (format "    container %s (%s) on engine %s%s\n"
                                (or (rdev-conn-container-name c) host)
                                (substring (or (rdev-conn-container c) "?") 0
                                           (min 12 (length (or (rdev-conn-container c) "?"))))
                                (or (rdev-conn-engine c) "local")
                                (if (rdev-conn-root-mode c)
                                    "  [root opt-in]" "")))))
             rdev--conns)
    (princ "\nremote processes\n\n")
    (maphash (lambda (_k ch)
               (princ (format "  #%-4d %-12s %s %s\n" (rdev-chan-id ch) (rdev-chan-host ch)
                              (if (rdev-chan-pty ch) "pty " "pipe")
                              (string-join (rdev-chan-cmd ch) " "))))
             rdev--chans)))

;;;; Mode line (FR-010)

(defcustom rdev-mode-line t
  "When non-nil, show the connection state in the mode line of rdev buffers.
Nothing is shown in buffers that are not on an rdev host."
  :type 'boolean :group 'rdev)

(defun rdev-mode-line-indicator ()
  "Mode-line string for the current buffer's rdev connection, or nil."
  (when (and rdev-mode-line (stringp default-directory)
             (ignore-errors (rdev--host default-directory)))
    (let* ((host (rdev--host default-directory))
           (st (rdev-state (rdev-state-session-key host))))
      (propertize (format " rdev:%s" st)
                  'face (pcase st
                          ('connected 'success)
                          ((or 'reconnecting 'connecting 'bootstrapping 'initializing 'degraded) 'warning)
                          ('failed 'error))
                  'help-echo (format "rdev connection to %s: %s" host st)))))

(unless (member '(:eval (rdev-mode-line-indicator)) mode-line-misc-info)
  (setq mode-line-misc-info
        (append mode-line-misc-info '((:eval (rdev-mode-line-indicator))))))

;; The management UI lives in rdev-ui.el and loads on first use.
(autoload 'rdev-list-connections "rdev-ui" "List rdev connections." t)
(autoload 'rdev-restart-server "rdev-ui" "Restart the agent on a host." t)
(autoload 'rdev-show-logs "rdev-ui" "Show the connection log of a host." t)
(autoload 'rdev-connect "rdev-ui" "Connect to an rdev host." t)

(provide 'rdev)
(require 'rdev-notify)
(require 'rdev-project)
;;; rdev.el ends here
