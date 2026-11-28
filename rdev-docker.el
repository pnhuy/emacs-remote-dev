;;; rdev-docker.el --- Docker container transports for rdev  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Huy Pham

;;; Commentary:

;; Docker container transport.  A running container is another remote target:
;; one persistent `docker exec -i' carries the same JSON-RPC stream that ssh
;; carries, so the bootstrap, agent, relay, file handlers and state machine are
;; reused.  A target is an `rdev-hosts' entry with :transport docker.
;;
;; The helper runs unprivileged.  A root-only container needs :allow-root on
;; the target or `rdev-docker-allow-root' globally; every such connection warns
;; and is logged.

;;; Code:

(require 'rdev)

;;;; Validation

(defun rdev-docker--validate-name (name)
  "Validate NAME as a Docker container name or ID, returning it.
Names must match [A-Za-z0-9][A-Za-z0-9_.-]* (which also covers hex IDs);
anything else could smuggle options into the `docker exec' command line."
  (unless (and (stringp name)
               (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]*\\'" name))
    (user-error "rdev: invalid container name %S (must match [A-Za-z0-9][A-Za-z0-9_.-]*)"
                name))
  name)

(defun rdev-docker--validate-user (user)
  "Validate USER as a `docker --user' account, returning it.
Accepts a name, a numeric UID, or NAME:GROUP / UID:GID; the first character
must not be `-' so it can never read as a Docker option."
  (unless (and (stringp user)
               (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_.:-]*\\'" user))
    (user-error "rdev: invalid docker user %S" user))
  user)

;;;; CLI invocation

(defconst rdev-docker--ps-format
  "{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Status}}"
  "`docker ps' template: tab-separated name, ID, image and status.
Names and image references never contain a tab, so one split per line is
unambiguous.")

(defconst rdev-docker--discovery-max-bytes (* 1024 1024)
  "Most `docker ps' output kept for discovery; the rest is reported as truncated.
Bounds memory when an engine (or something posing as one) floods stdout.")

(defvar rdev-docker--info (make-hash-table :test #'equal)
  "HOST -> inspect plist for the current connection attempt.
Filled by `rdev-docker--cached-info' during session-key resolution and
cleared by rdev.el before each (re)connect, so one connect costs exactly one
`docker inspect' and never reuses another session's answer.")

(defvar rdev-docker--discovery (make-hash-table :test #'equal)
  "Engine key -> (FLOAT-TIME ENTRIES . TRUNCATED) discovery snapshot.")

(defvar rdev-docker--inflight (make-hash-table :test #'equal)
  "Engine key -> the running background `docker ps' for that engine.
At most one lookup per engine is in flight.")

(defvar rdev-docker--failed (make-hash-table :test #'equal)
  "Engine key -> time of the last failed background discovery.
Within `rdev-docker-discovery-backoff' no new background lookup starts for
that engine, so a down daemon is not queried on every completion.")

(defun rdev-docker--program (spec)
  "Docker executable for SPEC: :docker-program or `rdev-docker-program'."
  (or (plist-get spec :docker-program) rdev-docker-program))

(defun rdev-docker--container (host spec)
  "Validated container name or ID for target HOST with connection SPEC."
  (rdev-docker--validate-name (or (plist-get spec :container) host)))

(defun rdev-docker--engine-key (spec)
  "Identity of SPEC's engine: `local' or the canonical SSH key of :docker-host."
  (if-let* ((dh (plist-get spec :docker-host)))
      (progn (rdev--validate-host dh)
             (rdev-state-session-key dh))
    "local"))

(defun rdev-docker--engine-label (spec)
  "Human-readable name of SPEC's engine for messages (no ssh lookup)."
  (if-let* ((dh (plist-get spec :docker-host)))
      (format "the engine on %s" dh)
    "the local engine"))

(defun rdev-docker--account-label (spec)
  "The account that talks to SPEC's engine, for permission messages."
  (if-let* ((dh (plist-get spec :docker-host)))
      (format "your ssh account on %s" dh)
    (format "local account %s" (user-login-name))))

(defun rdev-docker--remote-command (spec args)
  "Remote-shell command string that runs SPEC's Docker CLI with ARGS.
ssh joins its arguments and the destination host's shell parses them, so
every element is `shell-quote-argument'ed; validated names come out
unquoted, templates and payloads come out safely quoted."
  (mapconcat #'shell-quote-argument
             (cons (rdev-docker--program spec) args)
             " "))

(defun rdev-docker--argv (spec args)
  "Full argv to run SPEC's Docker CLI with arguments ARGS.
A remote engine (:docker-host) runs the same CLI through ssh, with `--'
separating ssh options from the destination."
  (if-let* ((dh (plist-get spec :docker-host)))
      (progn (rdev--validate-host dh)
             (append '("ssh") rdev-ssh-args (list "--" dh)
                     (list (rdev-docker--remote-command spec args))))
    (append (list (rdev-docker--program spec)) args)))

;; The CLI is a short-lived child process; the loop bounds a hung daemon by
;; TIMEOUT instead of blocking Emacs in `call-process'.
(defun rdev-docker--capped-filter (max-bytes)
  "Process filter that keeps at most MAX-BYTES of output, then stops the process.
The process gets the `rdev-overflow' property when output was cut."
  (lambda (proc string)
    (when (buffer-live-p (process-buffer proc))
      (with-current-buffer (process-buffer proc)
        (goto-char (point-max))
        (let ((room (- max-bytes (buffer-size))))
          (insert (if (> (length string) room) (substring string 0 (max 0 room)) string))
          (when (> (length string) room)
            (process-put proc 'rdev-overflow t)
            (delete-process proc)))))))

(defun rdev-docker--call (spec args &optional timeout max-bytes)
  "Run SPEC's Docker CLI with ARGS; return (CODE STDOUT STDERR).
Bounded by TIMEOUT seconds, default `rdev-docker-timeout'.  With MAX-BYTES,
stdout is cut at that size and the run counts as successful (the caller
sees the cut as a partial last line).  A missing CLI or a hung daemon maps
to `engine-unreachable'."
  (let* ((argv (rdev-docker--argv spec args))
         (out (generate-new-buffer " *rdev-docker-out*"))
         (err (generate-new-buffer " *rdev-docker-err*"))
         ;; Do not inherit a buffer's directory (it may be remote or
         ;; `~'-abbreviated).
         (default-directory temporary-file-directory)
         (deadline (+ (float-time)
                      (or timeout (or rdev-docker-timeout rdev-timeout))))
         (waited (or timeout (or rdev-docker-timeout rdev-timeout))))
    (unwind-protect
        (condition-case perr
            (let (proc)
              (setq proc (make-process
                          :name "rdev-docker" :buffer out :command argv
                          :connection-type 'pipe :coding 'binary :noquery t
                          :sentinel #'ignore
                          :stderr err))
              (when max-bytes
                (set-process-filter proc (rdev-docker--capped-filter max-bytes)))
              ;; Silence the stderr pipe's default sentinel, which would
              ;; append "Process ... finished" to the captured error.
              (when-let* ((errproc (get-buffer-process err)))
                (set-process-sentinel errproc #'ignore))
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output proc 0.05 nil t))
              (when (process-live-p proc)
                (delete-process proc)
                (rdev-docker--error
                 'engine-unreachable
                 "%s did not answer: `%s' did not finish within %ss; check that it is running or adjust `rdev-docker-timeout'"
                 (rdev-docker--engine-label spec)
                 (mapconcat #'identity argv " ") waited))
              ;; Drain the stderr pipe before reading: its output arrives
              ;; asynchronously, and a fast failure would look empty.
              (when-let* ((errproc (get-buffer-process err)))
                (let ((grace (+ (float-time) 1)))
                  (while (and (process-live-p errproc)
                              (< (float-time) grace))
                    (accept-process-output errproc 0.05 nil t))))
              (list (if (process-get proc 'rdev-overflow) 0 (process-exit-status proc))
                    (with-current-buffer out (buffer-string))
                    (with-current-buffer err (buffer-string))))
          (file-error
           (rdev-docker--error
            'engine-unreachable
            "cannot reach %s: cannot run %S (%s); install Docker or set :docker-program"
            (rdev-docker--engine-label spec)
            (rdev-docker--program spec) (error-message-string perr))))
      (kill-buffer out) (kill-buffer err))))

(defun rdev-docker--error (reason fmt &rest args)
  "Signal `rdev-docker-error' with REASON and the message from FMT and ARGS."
  (signal 'rdev-docker-error
          (list (concat "rdev: " (apply #'format fmt args)) reason)))

(defconst rdev-docker--stderr-signatures
  '(("got permission denied" . permission)
    ("permission denied" . permission)
    ("no such object" . not-found)
    ("no such container" . not-found)
    ("is not running" . not-running)
    ("cannot connect to the docker daemon" . engine-unreachable)
    ("is the docker daemon running" . engine-unreachable)
    ("daemon is not running" . engine-unreachable)
    ("no configuration file provided" . engine-unreachable)
    ("executable file not found" . unsupported)
    ("cannot connect" . engine-unreachable))
  "STDERR substring -> `rdev-docker-error' reason, most specific first.")

(defun rdev-docker--classify (stderr)
  "Return the `rdev-docker-error' reason suggested by Docker STDERR text."
  (let ((low (downcase stderr)) reason)
    (catch 'done
      (dolist (sig rdev-docker--stderr-signatures)
        (when (string-match-p (car sig) low)
          (setq reason (cdr sig))
          (throw 'done t))))
    reason))

(defconst rdev-docker--ssh-error-signatures
  '("could not resolve hostname" "connection refused" "connection timed out"
    "permission denied (publickey" "host key verification failed"
    "no route to host" "ssh: connect to host" "ssh_exchange_identification"
    "connection closed by remote host")
  "STDERR substrings that identify an ssh failure, not a Docker failure.")

(defun rdev-docker--ssh-failure-p (spec code stderr)
  "Non-nil when SPEC's remote-engine run failed in ssh, not in Docker.
CODE is the CLI exit status and STDERR its captured error text."
  (and (plist-get spec :docker-host)
       (let ((low (downcase (or stderr ""))))
         (or (= code 255)
             (cl-some (lambda (sig) (string-match-p sig low))
                      rdev-docker--ssh-error-signatures)))))

(defun rdev-docker--exit (spec code stdout stderr &optional fallback container)
  "Turn SPEC's finished CLI run (CODE STDOUT STDERR) into data or an error.
Zero CODE returns STDOUT; otherwise classify STDERR, using FALLBACK when it
matches nothing known.  The message names CONTAINER (when given), the
engine, the account for permission errors, and a remedy.  A remote engine's
ssh failure signals `rdev-ssh-error' instead of a Docker reason."
  (if (zerop code) stdout
    (when (rdev-docker--ssh-failure-p spec code stderr)
      (signal 'rdev-ssh-error
              (list (format "rdev: ssh to %s failed: %s"
                            (plist-get spec :docker-host)
                            (string-trim (or stderr ""))))))
    (let* ((reason (or (rdev-docker--classify stderr) fallback 'engine-unreachable))
           (engine (rdev-docker--engine-label spec))
           (what (if container (format "container %s" container) "the request"))
           (detail (string-trim (or stderr "")))
           (prog (rdev-docker--program spec)))
      (pcase reason
        ('not-found
         (rdev-docker--error reason "no container %s on %s (%s); check the name with `rdev-docker-list'"
                             (or container "?") engine detail))
        ('not-running
         (rdev-docker--error reason "%s on %s is not running (%s); start it and reconnect"
                             what engine detail))
        ('permission
         (rdev-docker--error reason "permission denied for %s on %s as %s (%s); add the account to the `docker' group or use a rootless engine"
                             what engine (rdev-docker--account-label spec) detail))
        ('engine-unreachable
         (rdev-docker--error reason "cannot reach %s: `%s' failed (%d): %s; start the daemon or check :docker-host"
                             engine prog code detail))
        (_
         (rdev-docker--error reason "%s on %s failed: `%s' exited %d: %s"
                             what engine prog code detail))))))

;;;; Inspection and discovery

(defun rdev-docker--inspect (spec container)
  "Inspect CONTAINER on SPEC's engine; return an info plist or signal.
The plist has :id :name :image :running :paused :status :user."
  (let* ((res (rdev-docker--call spec (list "inspect" "--format" "{{json .}}"
                                            (rdev-docker--validate-name container))))
         (out (rdev-docker--exit spec (car res) (nth 1 res) (nth 2 res) 'not-found container))
         (obj (condition-case jerr
                  (json-parse-string out :object-type 'plist
                                     :null-object nil :false-object :json-false)
                (json-error
                 (rdev-docker--error 'bootstrap
                                     "unparsable `docker inspect' output (%s)"
                                     (error-message-string jerr))))))
    (let ((state (plist-get obj :State))
          (config (plist-get obj :Config)))
      (list :id (plist-get obj :Id)
            :name (string-trim-left (or (plist-get obj :Name) "") "/")
            :image (plist-get config :Image)
            :running (eq (plist-get state :Running) t)
            :paused (eq (plist-get state :Paused) t)
            :status (or (plist-get state :Status) "unknown")
            :user (or (plist-get config :User) "")))))

(defun rdev-docker--cached-info (host spec)
  "HOST's inspect plist for SPEC, reusing the session-key resolution answer.
One connect performs exactly one `docker inspect'."
  (or (gethash host rdev-docker--info)
      (let ((info (rdev-docker--inspect spec (rdev-docker--container host spec))))
        (puthash host info rdev-docker--info)
        info)))

(defun rdev-docker--forget (host)
  "Drop HOST's cached inspect plist so the next connect re-resolves it."
  (remhash host rdev-docker--info))

(defun rdev-docker--parse-ps (text)
  "Parse `docker ps --format' TEXT into (ENTRIES . TRUNCATED).
ENTRIES are (:name :id :image :status) plists, capped at
`rdev-docker-discovery-max' entries and `rdev-docker--discovery-max-bytes'
of TEXT; TRUNCATED is non-nil when either cap cut lines."
  (let* ((cut (>= (length text) rdev-docker--discovery-max-bytes))
         (text (if cut
                   ;; Drop the partial last line.
                   (let ((s (substring text 0 rdev-docker--discovery-max-bytes)))
                     (substring s 0 (or (string-match-p "\n[^\n]*\\'" s) 0)))
                 text))
         (lines (split-string text "[\r\n]+" t))
         (keep (max 1 rdev-docker-discovery-max))
         (entries nil))
    (while (and lines (< (length entries) keep))
      (let ((f (split-string (pop lines) "\t")))
        (when (>= (length f) 2)
          (push (list :name (nth 0 f) :id (nth 1 f)
                      :image (nth 2 f) :status (nth 3 f))
                entries))))
    (cons (nreverse entries) (or cut (> (length lines) 0)))))

(defun rdev-docker--discovery (host spec &optional refresh)
  "Running containers on HOST's SPEC engine as (ENTRIES . TRUNCATED).
The snapshot is cached per engine for `rdev-docker-discovery-ttl'; REFRESH
forces a new query.  A failed refresh keeps the previous snapshot so
completion keeps working when the engine is down; with no snapshot the
error is signaled."
  (let* ((engine (rdev-docker--engine-key spec))
         (hit (gethash engine rdev-docker--discovery))
         (fresh (and hit (< (- (float-time) (car hit))
                            (max 0 rdev-docker-discovery-ttl)))))
    (if (and fresh (not refresh))
        (cdr hit)
      (let ((res (rdev-docker--call spec (list "ps" "--format" rdev-docker--ps-format)
                                    nil rdev-docker--discovery-max-bytes)))
        (if (zerop (car res))
            (rdev-docker--store-snapshot engine (rdev-docker--parse-ps (nth 1 res)))
          (or (cdr hit)
              (rdev-docker--error
               (or (rdev-docker--classify (nth 2 res)) 'engine-unreachable)
               "cannot list containers for %s on engine %s: %s"
               host engine (string-trim (nth 2 res)))))))))

(defun rdev-docker--discovery-for-host (host &optional refresh)
  "Discovery snapshot for the Docker target HOST; REFRESH forces a query."
  (rdev-docker--discovery host (rdev--host-spec host) refresh))

(defun rdev-docker--store-snapshot (engine snap)
  "Record SNAP as ENGINE's discovery snapshot, clear its failure; return SNAP."
  (puthash engine (cons (float-time) snap) rdev-docker--discovery)
  (remhash engine rdev-docker--failed)
  snap)

;;;; Background discovery (completion)
;;
;; Completion must never wait on the engine: it serves the cached snapshot
;; (stale-while-revalidate) and refreshes it with an asynchronous `docker
;; ps'.  Explicit commands (`rdev-docker-list', connect) keep using the
;; blocking `rdev-docker--discovery'.

(defun rdev-docker--backing-off-p (engine)
  "Non-nil when ENGINE's last background discovery failed recently."
  (when-let* ((t0 (gethash engine rdev-docker--failed)))
    (< (- (float-time) t0) (max 0 rdev-docker-discovery-backoff))))

(defun rdev-docker--refresh-finish (proc)
  "Record the outcome of the background discovery PROC (once)."
  (unless (process-get proc 'rdev-done)
    (process-put proc 'rdev-done t)
    (let ((engine (process-get proc 'rdev-engine))
          (out (process-buffer proc))
          (err (process-get proc 'rdev-stderr)))
      (when-let* ((timer (process-get proc 'rdev-timer)))
        (cancel-timer timer))
      (when (eq (gethash engine rdev-docker--inflight) proc)
        (remhash engine rdev-docker--inflight))
      (if (and (buffer-live-p out)
               (or (process-get proc 'rdev-overflow)
                   (and (eq (process-status proc) 'exit)
                        (zerop (process-exit-status proc)))))
          (rdev-docker--store-snapshot
           engine (rdev-docker--parse-ps (with-current-buffer out (buffer-string))))
        (puthash engine (float-time) rdev-docker--failed))
      (when (buffer-live-p out) (kill-buffer out))
      (when (buffer-live-p err) (kill-buffer err)))))

(defun rdev-docker--refresh-async (spec)
  "Start a background `docker ps' for SPEC's engine; return it, or nil.
Nil when a lookup for the engine is already running, the engine failed
within `rdev-docker-discovery-backoff', or the CLI cannot be started (which
counts as a failure).  The lookup is killed after
`rdev-docker-auto-detect-timeout' seconds, which also counts as a failure."
  (let ((engine (rdev-docker--engine-key spec)))
    (unless (or (process-live-p (gethash engine rdev-docker--inflight))
                (rdev-docker--backing-off-p engine))
      (let ((out (generate-new-buffer " *rdev-docker-ps*"))
            (err (generate-new-buffer " *rdev-docker-ps-err*"))
            ;; Do not inherit a buffer's (possibly remote) directory.
            (default-directory temporary-file-directory)
            proc)
        (condition-case nil
            (progn
              (setq proc (make-process
                          :name "rdev-docker-ps" :buffer out
                          :command (rdev-docker--argv
                                    spec (list "ps" "--format" rdev-docker--ps-format))
                          :connection-type 'pipe :coding 'binary :noquery t
                          :stderr err
                          :sentinel (lambda (p _)
                                      (unless (process-live-p p)
                                        (rdev-docker--refresh-finish p)))))
              (set-process-filter
               proc (rdev-docker--capped-filter rdev-docker--discovery-max-bytes))
              (when-let* ((errproc (get-buffer-process err)))
                (set-process-sentinel errproc #'ignore)
                (set-process-query-on-exit-flag errproc nil))
              (process-put proc 'rdev-engine engine)
              (process-put proc 'rdev-stderr err)
              (process-put proc 'rdev-timer
                           (run-at-time (max 0.1 rdev-docker-auto-detect-timeout) nil
                                        (lambda ()
                                          (when (process-live-p proc)
                                            (delete-process proc))
                                          (rdev-docker--refresh-finish proc))))
              (puthash engine proc rdev-docker--inflight)
              proc)
          (error
           (when (buffer-live-p out) (kill-buffer out))
           (when (buffer-live-p err) (kill-buffer err))
           (puthash engine (float-time) rdev-docker--failed)
           nil))))))

(defun rdev-docker--reset-discovery ()
  "Stop background lookups and forget every discovery snapshot and failure."
  (maphash (lambda (_engine proc)
             (when (process-live-p proc) (delete-process proc))
             (rdev-docker--refresh-finish proc))
           rdev-docker--inflight)
  (clrhash rdev-docker--inflight)
  (clrhash rdev-docker--failed)
  (clrhash rdev-docker--discovery))

(defun rdev-docker--snapshot (spec)
  "SPEC's engine discovery for completion, without blocking.
Returns the cached (ENTRIES . TRUNCATED), possibly stale, or nil.  A stale
or missing snapshot starts a background refresh; only when there is no
snapshot at all does this call wait, at most `rdev-docker-discovery-wait'
seconds, for the lookup it started.  Never signals."
  (condition-case nil
      (let* ((engine (rdev-docker--engine-key spec))
             (hit (gethash engine rdev-docker--discovery))
             (fresh (and hit (< (- (float-time) (car hit))
                                (max 0 rdev-docker-discovery-ttl)))))
        (unless fresh
          (let ((proc (rdev-docker--refresh-async spec)))
            (when (and proc (not hit))
              (let ((deadline (+ (float-time) (max 0 rdev-docker-discovery-wait))))
                ;; With JUST-THIS-ONE the sentinel does not run here, so
                ;; stop on exit too and record the result directly.
                (while (and (not (process-get proc 'rdev-done))
                            (process-live-p proc)
                            (< (float-time) deadline))
                  (accept-process-output proc 0.02 nil t)))
              (when (and (not (process-get proc 'rdev-done))
                         (not (process-live-p proc)))
                (rdev-docker--refresh-finish proc))
              (setq hit (gethash engine rdev-docker--discovery)))))
        (cdr hit))
    (error nil)))

;;;; Transport process

(defun rdev-docker--exec-args (spec container payload)
  "Docker CLI arguments (after SPEC's program) to run PAYLOAD in CONTAINER.
Used for the synchronous UID probe, for the local engine's transport (where
argv elements pass to `docker exec' unchanged) and, through
`rdev-docker--remote-command', for a remote engine."
  (append (list "exec" "-i")
          (let ((u (plist-get spec :docker-user)))
            (and u (list "--user" (rdev-docker--validate-user u))))
          (list (rdev-docker--validate-name container) "sh" "-c" payload)))

(defun rdev-docker--transport-argv (spec container remote)
  "Argv for SPEC's persistent stdio transport to CONTAINER running REMOTE.
Local engine: the CLI is execed directly, so REMOTE travels as one argv
element.  Remote engine: ssh joins its arguments and the remote shell parses
them, so the whole `docker exec ...' line is built as one quoted string."
  (if-let* ((dh (plist-get spec :docker-host)))
      (progn (rdev--validate-host dh)
             (append '("ssh") rdev-ssh-args
                     (list "--" dh
                           (rdev-docker--remote-command
                            spec (rdev-docker--exec-args spec container remote)))))
    (append (list (rdev-docker--program spec))
            (rdev-docker--exec-args spec container remote))))

(defun rdev-docker--probe-uid (spec target &optional container)
  "Effective UID the helper would run with inside TARGET (an ID or name) for SPEC.
CONTAINER is the name used in messages (default TARGET).  Signals
`unsupported' when `sh' is missing; bounded by `rdev-docker-probe-timeout'."
  (setq container (or container target))
  (let* ((res (rdev-docker--call spec
                                 (rdev-docker--exec-args spec target "id -u")
                                 rdev-docker-probe-timeout))
         (code (car res)) (out (nth 1 res)) (err (nth 2 res)))
    (cond
     ((zerop code)
      ;; UID 0 is a valid answer: the root policy decides whether it is
      ;; allowed.  Only a non-numeric answer is unusable (never guess).
      (let ((text (string-trim out)))
        (if (string-match-p "\\`[0-9]+\\'" text)
            (string-to-number text)
          (rdev-docker--error 'unsupported
                              "container %s reported unusable uid %S" container out))))
     ((memq code '(126 127))
      (rdev-docker--error 'unsupported
                          "container %s has no usable POSIX shell (`id -u': %s)"
                          container (string-trim err)))
     (t (rdev-docker--exit spec code out err nil container)))))

(defun rdev-docker--allow-root-p (spec)
  "Non-nil when SPEC's target may run the helper as root.
An explicit :allow-root wins, including nil (a per-target opt-out);
otherwise the global `rdev-docker-allow-root' applies.  Both are off by
default."
  (if (plist-member spec :allow-root)
      (plist-get spec :allow-root)
    rdev-docker-allow-root))

(defun rdev-docker--apply-root-policy (host spec container uid key)
  "Enforce the root policy for HOST's SPEC and CONTAINER (uid UID) on KEY.
Refuse root unless the per-target or global opt-in is set; the opt-in warns
and records the elevated privilege."
  (when (= uid 0)
    (if (not (rdev-docker--allow-root-p spec))
        (rdev-docker--error
         'root-refused
         "container %s runs as root (uid 0); use an unprivileged account, set :docker-user, or set :allow-root t on this target"
         container)
      ;; Explicit opt-in: surface and record the elevated privilege.
      (display-warning
       'rdev
       (format "rdev: %s: helper runs as root in container %s (explicit :allow-root)"
               host container))
      (rdev-state-log key "helper runs with container-root privileges (uid 0)")))
  nil)

(defun rdev-docker--process (host spec)
  "Start SPEC's stdio agent inside HOST's container; return the transport process.
The container must exist and be running, the root policy must pass, and the
bootstrap is the same size/SHA-256 verified script used over ssh."
  (let* ((container (rdev-docker--container host spec))
         (key (rdev-state-session-key host))
         (info (rdev-docker--cached-info host spec))
         ;; Exec by the inspected immutable ID, not the name: a container
         ;; recreated under the same name between inspect and exec must not
         ;; receive this session.  Messages keep using the name.
         (target (rdev-docker--validate-name (or (plist-get info :id) container)))
         (_ (unless (plist-get info :running)
              (rdev-docker--error
               'not-running "container %s is %s; start it and reconnect"
               container (or (plist-get info :status) "not running"))))
         (_ (when (plist-get info :paused)
              (rdev-docker--error
               'not-running "container %s is paused; unpause it and reconnect"
               container)))
         (uid (rdev-docker--probe-uid spec target container))
         (_ (rdev-docker--apply-root-policy host spec container uid key))
         (script (rdev--server-script))
         (sha (secure-hash 'sha256 script))
         (bootstrap (rdev--bootstrap-script
                     t (and (rdev-docker--allow-root-p spec) (= uid 0)
                            " --allow-root")))
         (remote (format bootstrap (substring sha 0 12) (length script) sha))
         (default-directory temporary-file-directory)
         (stderr (get-buffer-create (format " *rdev-stderr %s*" host)))
         ;; The `docker exec' process is the transport: its stdin/stdout carry
         ;; the JSON-RPC stream and its death is the connection-loss signal,
         ;; exactly as the ssh process is for the ssh transport.
         (proc (make-process
                :name (format "rdev-%s" host)
                :command (rdev-docker--transport-argv spec target remote)
                :connection-type 'pipe :coding 'binary :noquery t
                :stderr stderr
                :filter #'rdev--bootstrap-filter)))
    (process-put proc 'rdev-log "")
    (process-put proc 'rdev-script script)
    (process-put proc 'rdev-root-mode
                 (and (rdev-docker--allow-root-p spec) (= uid 0)))
    (process-put proc 'rdev-container (plist-get info :id))
    (process-put proc 'rdev-container-name (or (plist-get info :name) container))
    (rdev--wait-for proc (lambda () (process-get proc 'rdev-state))
                    (format "docker exec in %s" container))
    (when (eq (process-get proc 'rdev-state) 'error)
      (let ((msg (process-get proc 'rdev-error))
            (errtext (with-current-buffer stderr (buffer-string))))
        (delete-process proc)
        ;; A remote engine that never reached Docker failed in ssh, not in
        ;; the container.
        (when (and (plist-get spec :docker-host)
                   (rdev-docker--ssh-failure-p spec 255 errtext))
          (signal 'rdev-ssh-error
                  (list (format "rdev: ssh to %s failed: %s"
                                (plist-get spec :docker-host)
                                (string-trim errtext)))))
        (signal 'rdev-docker-error
                (list (format "rdev: %s: %s" host msg)
                      (cond ((string-match-p "python" msg) 'unsupported)
                            ((string-match-p "writable" msg) 'unsupported)
                            (t 'bootstrap))))))
    proc))

;;;; Session identity and replacement

(defun rdev-docker--session-key (host)
  "Session key for the Docker target HOST: `docker:<engine>:<container-id>'.
Installed as `rdev-state-docker-key-function'; returns nil when HOST is not
a Docker target.  The immutable container ID (not the name) is part of the
key, so a container recreated under the same name is a new session."
  (when (rdev--docker-p host)
    ;; Never signal: the key is also looked up by status views, which must
    ;; keep working when the container or engine is gone.
    (condition-case nil
        (let* ((spec (rdev--host-spec host))
               (info (rdev-docker--cached-info host spec))
               (id (or (plist-get info :id) "unknown")))
          (format "docker:%s:%s" (rdev-docker--engine-key spec) id))
      (error (rdev-docker--unresolved-key host)))))

(defun rdev-docker--unresolved-key (host)
  "Session key for HOST whose container could not be inspected.
It names the engine and the configured container, marked `unresolved/'."
  (let ((spec (rdev--host-spec host)))
    (format "docker:%s:unresolved/%s"
            (or (ignore-errors (rdev-docker--engine-key spec))
                (plist-get spec :docker-host) "local")
            (or (plist-get spec :container) host))))

(defun rdev-docker--unresolved-key-p (key)
  "Non-nil when KEY is an `rdev-docker--unresolved-key'."
  (and (stringp key) (string-match-p "\\`docker:.*:unresolved/" key)))

(defun rdev-docker--refresh-identity (host)
  "Re-resolve HOST's container identity for a (re)connect; return its session key.
Signals when the container cannot be inspected.  HOST's cached key is then
left in place, so its state, log and reconnect keep working (see
`rdev-docker--fallback-key')."
  (rdev-docker--forget host)
  ;; Inspect before dropping the old key: errors surface here, never from a
  ;; later key lookup.
  (rdev-docker--cached-info host (rdev--host-spec host))
  (remhash host rdev-state--keys)
  (rdev-docker--note-replacement host))

(defun rdev-docker--fallback-key (host)
  "Session key to record HOST's failed identity resolution under.
The key cached for HOST is kept; with none, an unresolved key naming the
engine and container is cached, so the failure is shown and logged."
  (or (gethash host rdev-state--keys)
      (puthash host (rdev-docker--unresolved-key host) rdev-state--keys)))

(defun rdev-docker--note-replacement (host)
  "Retire HOST's previous session when the container identity changed.
A recreated container starts a fresh session with empty caches; operations
are never replayed."
  (let ((new-key (rdev-state-session-key host))
        (old-key (gethash host rdev--host-keys)))
    (when (and old-key (not (equal old-key new-key)))
      (unless (rdev-docker--unresolved-key-p old-key)
        (rdev-state-log old-key "container replaced: %s -> %s" old-key new-key))
      (unless (eq (rdev-state old-key) 'disconnected)
        (rdev-state-cancel-reconnect old-key)
        (ignore-errors (rdev-state-user-disconnect old-key)))
      (remhash old-key rdev--key-hosts))
    new-key))

(setq rdev-state-docker-key-function #'rdev-docker--session-key)

;;;; Completion

(defun rdev-docker--address (name &optional docker-host)
  "Explicit host key for container NAME, on DOCKER-HOST's engine if given.
The key has the form `docker+NAME' or `docker+NAME@DOCKER-HOST'; see
`rdev--docker-address-spec'."
  (concat "docker+" name (if docker-host (concat "@" docker-host) "")))

(defun rdev-docker--completion-engines ()
  "Unique (ENGINE-KEY . SPEC) pairs whose containers completion offers.
The engines of configured Docker targets, plus the local engine when
`rdev-docker-auto-detect' is non-nil and the Docker CLI is installed."
  (let (engines)
    (dolist (e rdev-hosts)
      (when (eq (plist-get (cdr e) :transport) 'docker)
        (ignore-errors
          (let ((engine (rdev-docker--engine-key (cdr e))))
            (unless (assoc engine engines)
              (push (cons engine (cdr e)) engines))))))
    (when (and rdev-docker-auto-detect
               (not (assoc "local" engines))
               (executable-find (or rdev-docker-program "docker")))
      (push (cons "local" (list :transport 'docker)) engines))
    (nreverse engines)))

(defun rdev-docker--completion-hosts ()
  "Running containers offered for completion, as `docker+NAME[@DH]' keys.
Each engine is queried at most once, in the background (see
`rdev-docker--snapshot'), so completion never waits on a slow engine.
Containers a configured Docker target already names are left out; an
unreachable engine adds nothing."
  (let ((taken (make-hash-table :test #'equal))
        names)
    (dolist (e rdev-hosts)
      (when (eq (plist-get (cdr e) :transport) 'docker)
        (ignore-errors
          (puthash (cons (rdev-docker--engine-key (cdr e))
                         (or (plist-get (cdr e) :container) (car e)))
                   t taken))))
    (dolist (en (rdev-docker--completion-engines))
      (let ((dh (plist-get (cdr en) :docker-host)))
        (dolist (c (car (rdev-docker--snapshot (cdr en))))
          (let ((n (plist-get c :name)))
            (when (and (stringp n)
                       (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]*\\'" n)
                       (not (gethash (cons (car en) n) taken)))
              (push (rdev-docker--address n dh) names))))))
    (delete-dups (nreverse names))))

;;;; Commands

;;;###autoload
(defun rdev-docker-list ()
  "List running containers on the engines of the configured Docker targets.
With no Docker target configured, the local engine is listed.  Output is
bounded by `rdev-docker-discovery-max'."
  (interactive)
  (let* ((specs (cl-remove-if-not
                 (lambda (e) (eq (plist-get (cdr e) :transport) 'docker))
                 rdev-hosts))
         (specs (or specs (list (cons "local" (list :transport 'docker))))))
    (with-help-window "*rdev-docker*"
      (princ "rdev docker containers\n\n")
      (dolist (e specs)
        (let* ((host (car e))
               (spec (cdr e))
               (snap (rdev-docker--discovery host spec)))
          (princ (format "  engine %s\n" (rdev-docker--engine-key spec)))
          (if (null (car snap))
              (princ "    (no running containers)\n")
            (dolist (c (car snap))
              (princ (format "    %-24s %-20s %s\n"
                             (plist-get c :name) (plist-get c :id)
                             (or (plist-get c :status) "")))))
          (when (cdr snap)
            (princ (format "    (list truncated at %d entries)\n"
                           rdev-docker-discovery-max))))))))

;;;###autoload
(defun rdev-docker-connect (&optional name)
  "Connect to a running Docker container NAME (or ask with completion).
NAME is a configured Docker target key, an explicit `docker+NAME[@DH]'
address, or a bare container name on the local engine, which connects as
`docker+NAME'.  Returns the host key, so `/rdev:KEY:/path' reaches the
container; nothing is added to `rdev-hosts'."
  (interactive
   (list (completing-read
          "rdev docker container: "
          (completion-table-dynamic
           (lambda (_)
             (delete-dups
              (append (mapcar #'car (cl-remove-if-not
                                     (lambda (e)
                                       (eq (plist-get (cdr e) :transport) 'docker))
                                     rdev-hosts))
                      (rdev-docker--completion-hosts)))))
          nil nil)))
  (let* ((entry (assoc name rdev-hosts))
         (key (cond
               ((and entry (eq (plist-get (cdr entry) :transport) 'docker)) name)
               (entry
                (user-error "rdev: %s is configured as an %s target; use a distinct key for the container"
                            name (or (plist-get (cdr entry) :transport) 'ssh)))
               ((rdev--docker-address-spec name) name)
               (t (rdev-docker--address (rdev-docker--validate-name name))))))
    (rdev--conn key)
    (when (called-interactively-p 'interactive)
      (message "rdev: connected to %s (open files under /rdev:%s:/)" key key))
    key))

(provide 'rdev-docker)
;;; rdev-docker.el ends here
