;;; docker.el --- E2E over real Docker containers  -*- lexical-binding: t; -*-

;; End-to-end scenarios against disposable containers.
;;
;; Prerequisites come from test/e2e/run.sh (make e2e S=docker):
;;   RDEV_TEST_DOCKER_DEV   unprivileged container name
;;   RDEV_TEST_DOCKER_ROOT  root-only container name
;;   RDEV_TEST_SSH_CONFIG / RDEV_TEST_HOST  the disposable sshd used as the
;;                                          remote Docker engine host
;; A missing prerequisite skips with a reason; it never passes silently.
;;
;; The file-handler and process paths are the same code the SSH E2E suite
;; exercises; no container-specific gap was found for atomic save, conflict
;; detection, permissions, symlinks, binary/encoding, chunked large files,
;; streaming, exit codes, signals or PTY resize.

(require 'ert)
(require 'rdev)
(require 'rdev-docker)
(require 'rdev-ui)
(require 'compile)

(declare-function eglot-ensure "eglot" (&rest args))
(declare-function eglot-current-server "eglot" (&optional buffer))
(declare-function eglot-shutdown "eglot" (server &optional interactive))

(defconst e2e-docker-dev (getenv "RDEV_TEST_DOCKER_DEV"))
(defconst e2e-docker-root (getenv "RDEV_TEST_DOCKER_ROOT"))
(defconst e2e-docker-image (or (getenv "RDEV_TEST_DOCKER_IMAGE") "python:3.11-slim"))

(defun e2e-docker--need (name value)
  "Skip unless VALUE (from environment variable NAME) is set."
  (unless (and value (not (string-empty-p value)))
    (ert-skip (format "%s not set (run make e2e S=docker)" name))))

(defun e2e-docker--docker (&rest args)
  "Run docker ARGS; return (CODE . OUTPUT)."
  (with-temp-buffer
    (let ((code (apply #'call-process "docker" nil t nil args)))
      (cons code (buffer-string)))))

(defun e2e-docker--exec (container command)
  "Run COMMAND with sh in CONTAINER; return its stdout."
  (let ((res (e2e-docker--docker "exec" container "sh" "-c" command)))
    (unless (zerop (car res))
      (error "docker exec %s failed (%d): %s" container (car res) (cdr res)))
    (cdr res)))

(defun e2e-docker--reset ()
  "Clear connection, session and Docker caches between scenarios."
  (setq rdev--conns (make-hash-table :test #'equal)
        rdev--chans (make-hash-table :test #'equal)
        rdev--gens (make-hash-table :test #'equal)
        rdev--key-hosts (make-hash-table :test #'equal)
        rdev--host-keys (make-hash-table :test #'equal)
        rdev-state--table (make-hash-table :test #'equal)
        rdev-state--timers (make-hash-table :test #'equal)
        rdev-state--attempts (make-hash-table :test #'equal)
        rdev-state--keys (make-hash-table :test #'equal))
  (clrhash rdev-docker--info)
  (rdev-docker--reset-discovery))

(defun e2e-docker--configure (host container &optional plist)
  "Add HOST as a Docker target for CONTAINER with PLIST overrides."
  (setq rdev-hosts
        (cons (cons host (append (list :transport 'docker :container container)
                                 plist))
              rdev-hosts)))

(defmacro e2e-docker--with-target (host container plist &rest body)
  "Run BODY with HOST configured for CONTAINER and PLIST, then reset."
  (declare (indent 3))
  `(progn
     (e2e-docker--reset)
     (e2e-docker--configure ,host ,container ,plist)
     (unwind-protect (progn ,@body)
       (ignore-errors (rdev-disconnect ,host))
       (e2e-docker--reset)
       (setq rdev-hosts nil))))

(defun e2e-docker--transport (host)
  "The transport process behind HOST's connection, or nil."
  (when-let* ((c (gethash host rdev--conns)))
    (ignore-errors (jsonrpc--process (rdev-conn-rpc c)))))

(defun e2e-docker--wait (pred &optional timeout)
  "Accept output until PRED is true or TIMEOUT (default 30) elapses."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun e2e-docker--state (host)
  (rdev-state (rdev-state-session-key host)))

(defun e2e-docker--wait-state (host state &optional timeout)
  (e2e-docker--wait (lambda () (eq (e2e-docker--state host) state)) timeout))

(defun e2e-docker--kill-transport (host)
  "Kill HOST's transport as a container loss would."
  (when-let* ((proc (e2e-docker--transport host)))
    (when (process-live-p proc)
      (signal-process (process-id proc) 'KILL)
      t)))

(defun e2e-docker--read (file)
  "Read FILE, retrying while a reconnect is in flight."
  (let ((deadline (+ (float-time) 60)) out)
    (while (and (not out) (< (float-time) deadline))
      (condition-case nil
          (setq out (with-temp-buffer (insert-file-contents file) (buffer-string)))
        (rdev-connection-lost (accept-process-output nil 0.2))))
    out))

(defun e2e-docker--recreate (container)
  "Recreate CONTAINER under the same name and seed /workspace again."
  (e2e-docker--docker "rm" "-f" container)
  (let ((res (e2e-docker--docker
              "run" "-d" "--name" container "--user" "1000:1000"
              "-e" "HOME=/home/dev" "-w" "/workspace"
              e2e-docker-image "sleep" "infinity")))
    (unless (zerop (car res))
      (error "recreate %s failed: %s" container (cdr res))))
  (let ((res (e2e-docker--docker
              "exec" "-u" "0" container "sh" "-c"
              "mkdir -p /workspace /home/dev && chown 1000:1000 /workspace /home/dev && \
printf 'hello\n' > /workspace/hello.txt && chown 1000:1000 /workspace/hello.txt")))
    (unless (zerop (car res))
      (error "seed %s failed: %s" container (cdr res)))))

;;;; Edit and save

(ert-deftest e2e-docker-edit-save ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (should (eq (e2e-docker--state "dev") 'connected))
    (e2e-docker--exec e2e-docker-dev "printf 'hello\n' > /workspace/hello.txt")
    (let ((f "/rdev:dev:/workspace/hello.txt"))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                     "hello\n"))
      (write-region "edited in docker\n" nil f nil 'silent)
      (should (equal (e2e-docker--exec e2e-docker-dev "cat /workspace/hello.txt")
                     "edited in docker\n"))
      ;; The unprivileged account owns the file; the helper did not change it.
      (should (equal (string-trim
                      (e2e-docker--exec e2e-docker-dev
                                        "stat -c %u:%g /workspace/hello.txt"))
                     "1000:1000")))))

;;;; External modification is a conflict

(ert-deftest e2e-docker-conflict ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (let ((f "/rdev:dev:/workspace/hello.txt")
          (make-backup-files nil)
          (rdev-conflict-functions nil))
      (write-region "ORIGINAL\n" nil f nil 'silent)
      (with-current-buffer (find-file-noselect f)
        (unwind-protect
            (progn
              (erase-buffer) (insert "my edit\n")
              (e2e-docker--exec e2e-docker-dev
                                "printf 'external\\n' > /workspace/hello.txt")
              (cl-letf (((symbol-function 'ask-user-about-supersession-threat)
                         (lambda (_) nil))
                        ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                        ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (should-error (save-buffer) :type 'rdev-conflict))
              ;; The outside change survives and the edit is still unsaved.
              (should (equal (e2e-docker--exec e2e-docker-dev
                                               "cat /workspace/hello.txt")
                             "external\n"))
              (should (buffer-modified-p))
              (should (equal (buffer-string) "my edit\n")))
          (set-buffer-modified-p nil)
          (kill-buffer))))))

;;;; Interrupted save leaves complete old/new content

(ert-deftest e2e-docker-interrupted-save ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (let* ((rdev-reconnect-base 0.3) (rdev-reconnect-cap 2.0)
           (make-backup-files nil)
           (body (lambda (tag)
                   (mapconcat (lambda (i) (format "%s line %06d\n" tag i))
                              (number-sequence 1 30000) "")))
           (old (funcall body "old")) (new (funcall body "NEW"))
           (corrupt nil) (lost nil) (saved 0) (failed 0))
      (rdev--connect "dev")
      (dotimes (i 3)
        (let* ((f (format "/rdev:dev:/workspace/f%02d.txt" i))
               (gen (rdev-conn-gen (rdev--conn "dev")))
               (fired nil) timer)
          (write-region old nil f nil 'silent)
          (with-current-buffer (find-file-noselect f)
            (unwind-protect
                (progn
                  (erase-buffer) (insert new)
                  (setq timer (run-at-time 0.02 nil
                                           (lambda ()
                                             (setq fired (e2e-docker--kill-transport "dev")))))
                  (let ((ok (condition-case nil (progn (save-buffer) t) (error nil))))
                    (cancel-timer timer)
                    (unless fired (e2e-docker--kill-transport "dev"))
                    (should (e2e-docker--wait
                             (lambda ()
                               (and (eq (e2e-docker--state "dev") 'connected)
                                    (> (or (rdev-conn-gen (rdev--conn "dev")) 0) gen)))
                             60))
                    (let ((remote (e2e-docker--read f)))
                      (cond ((equal remote new) (cl-incf saved))
                            ((equal remote old) (cl-incf failed))
                            (t (push (cons i (length remote)) corrupt)))
                      ;; A failed save keeps the new text in a modified buffer.
                      (unless (or ok
                                  (and (buffer-modified-p)
                                       (equal (buffer-string) new)))
                        (push i lost)))))
              (set-buffer-modified-p nil)
              (kill-buffer)))))
      (message "docker interrupted-save: %d saved, %d failed, corrupt %S, lost %S"
               saved failed corrupt lost)
      (should-not corrupt)
      (should-not lost))))

;;;; Shell, compile, interrupt, resize

(ert-deftest e2e-docker-shell-and-command ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (let ((default-directory "/rdev:dev:/workspace/"))
      (should (equal (string-trim (shell-command-to-string "pwd")) "/workspace"))
      (should (equal (string-trim (shell-command-to-string "id -u")) "1000"))
      (with-temp-buffer
        (should (= 7 (process-file "sh" nil t nil "-c" "exit 7"))))
      ;; Streaming and an exact exit code through the relay.
      (let* ((default-directory "/rdev:dev:/workspace/")
             (out "")
             (p (make-process :name "e2e-docker-stream" :connection-type 'pipe
                              :noquery t :file-handler t
                              :command '("sh" "-c" "echo one; sleep 0.2; echo two; exit 3")
                              :filter (lambda (_p s) (setq out (concat out s))))))
        (should (e2e-docker--wait (lambda () (not (process-live-p p)))))
        (should (string-match-p "one" out))
        (should (string-match-p "two" out))
        (should (= 3 (process-exit-status p)))))))

(ert-deftest e2e-docker-compile ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (let* ((default-directory "/rdev:dev:/workspace/")
           (compilation-buffer-name-function (lambda (_) "*e2e-docker-compile*"))
           (buf (compile "echo compile-ok")))
      (unwind-protect
          (progn
            (should (e2e-docker--wait
                     (lambda ()
                       (with-current-buffer buf
                         (string-match-p "compile-ok" (buffer-string))))))
            (should (e2e-docker--wait
                     (lambda ()
                       (with-current-buffer buf
                         (not (get-buffer-process (current-buffer))))))))
        (kill-buffer buf)))))

(ert-deftest e2e-docker-eglot ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (unless (require 'eglot nil t)
    (ert-skip "eglot is not available in this Emacs"))
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (let ((server (string-trim
                   (e2e-docker--exec e2e-docker-dev
                                     "command -v pylsp || command -v clangd || true"))))
      (unless (not (string-empty-p server))
        (ert-skip "no language server (pylsp/clangd) in the image"))
      (let* ((default-directory "/rdev:dev:/workspace/")
             (file "/rdev:dev:/workspace/eglot.py"))
        (write-region "def f():\n    return 1\n" nil file nil 'silent)
        (with-current-buffer (find-file-noselect file)
          (unwind-protect
              (progn
                (eglot-ensure)
                (should (e2e-docker--wait
                         (lambda () (eglot-current-server)) 60)))
            (ignore-errors (eglot-shutdown (eglot-current-server)))
            (set-buffer-modified-p nil)
            (kill-buffer)))))))

(ert-deftest e2e-docker-interrupt-and-resize ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (let* ((default-directory "/rdev:dev:/workspace/")
           (buf (generate-new-buffer " *e2e-docker-pty*"))
           (p (make-process :name "e2e-docker-pty" :buffer buf
                            :command '("sh") :connection-type 'pty
                            :file-handler t :noquery t)))
      (unwind-protect
          (progn
            ;; Wait for the relay to spawn the PTY before resizing it.
            (should (e2e-docker--wait (lambda () (process-live-p p))))
            (accept-process-output nil 0.3)
            (set-process-window-size p 31 97)
            (process-send-string p "stty size\n")
            (should (e2e-docker--wait
                     (lambda ()
                       (with-current-buffer buf
                         (string-match-p "31 97" (buffer-string))))))
            (process-send-string p "sleep 30\n")
            (accept-process-output nil 0.3)
            (interrupt-process p)
            (process-send-string p "echo after-interrupt\n")
            (should (e2e-docker--wait
                     (lambda ()
                       (with-current-buffer buf
                         (string-match-p "after-interrupt" (buffer-string))))))
            (process-send-string p "exit 5\n")
            (should (e2e-docker--wait (lambda () (not (process-live-p p)))))
            (should (= 5 (process-exit-status p))))
        (when (process-live-p p) (delete-process p))
        (kill-buffer buf)))))

;;;; Discovery, completion and status

(ert-deftest e2e-docker-discovery-and-status ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev-docker-list)
    (with-current-buffer "*rdev-docker*"
      (should (string-match-p (regexp-quote e2e-docker-dev) (buffer-string))))
    ;; The configured key completes; its container is not offered again as
    ;; an address, and the (background) snapshot has it.
    (let ((hosts (rdev--target-completion)))
      (should (member "dev" hosts))
      (should-not (member (concat "docker+" e2e-docker-dev) hosts)))
    (should (cl-find e2e-docker-dev
                     (car (rdev-docker--snapshot (rdev--host-spec "dev")))
                     :key (lambda (c) (plist-get c :name)) :test #'equal))
    (rdev--connect "dev")
    ;; The list shows the container's name, not its ID.
    (should (equal (rdev-ui--target "dev") (concat "docker:local/" e2e-docker-dev)))
    (let ((row (rdev-ui--row "dev")))
      (should (equal (aref (cadr row) 1) (rdev-ui--target "dev"))))))

;;;; Stop, restart, recreate

(ert-deftest e2e-docker-stop-restart-recreate ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (let ((rdev-reconnect-base 0.3) (rdev-reconnect-cap 2.0)
          (rdev-reconnect-max-attempts 100))
      (rdev--connect "dev")
      (let ((key (rdev-state-session-key "dev")))
        (should (eq (e2e-docker--state "dev") 'connected))
        ;; Stop: the transport dies and the session starts reconnecting.
        (e2e-docker--docker "stop" e2e-docker-dev)
        (should (e2e-docker--wait
                 (lambda () (memq (e2e-docker--state "dev")
                                  '(reconnecting failed)))
                 30))
        ;; Restart with the same ID: same key, new generation.
        (e2e-docker--docker "start" e2e-docker-dev)
        (should (e2e-docker--wait-state "dev" 'connected 60))
        (should (equal (rdev-state-session-key "dev") key))
        ;; Recreate under the same name: a new ID is a new session.
        (e2e-docker--recreate e2e-docker-dev)
        (should (e2e-docker--wait
                 (lambda ()
                   (and (eq (e2e-docker--state "dev") 'connected)
                        (not (equal (rdev-state-session-key "dev") key))))
                 60))
        (let ((new-key (rdev-state-session-key "dev")))
          (should-not (equal new-key key))
          (should (eq (rdev-state new-key) 'connected))
          (should (eq (rdev-state key) 'disconnected))
          (should (let ((b (get-buffer (format "*rdev-log %s*" key))))
                    (and b (with-current-buffer b
                             (string-match-p "container replaced" (buffer-string))))))
          (should (file-exists-p "/rdev:dev:/workspace/hello.txt")))))))

;;;; Root policy

(ert-deftest e2e-docker-root-policy ()
  (e2e-docker--need "RDEV_TEST_DOCKER_ROOT" e2e-docker-root)
  (e2e-docker--with-target "rootc" e2e-docker-root nil
    (let ((err (should-error (rdev--connect "rootc"))))
      (should (eq (car err) 'rdev-docker-error))
      (should (eq (car (last err)) 'root-refused))
      (should (string-match-p ":allow-root" (cadr err))))
    (should (eq (e2e-docker--state "rootc") 'failed)))
  (e2e-docker--with-target "rootc" e2e-docker-root '(:allow-root t)
    (let ((conn (rdev--connect "rootc")))
      (should (rdev-conn-root-mode conn))
      (should (eq (e2e-docker--state "rootc") 'connected))
      (should (equal (string-trim
                      (shell-command-to-string
                       (concat "docker exec " e2e-docker-root " id -u")))
                     "0")))))

(ert-deftest e2e-docker-global-allow-root ()
  (e2e-docker--need "RDEV_TEST_DOCKER_ROOT" e2e-docker-root)
  (let ((rdev-docker-allow-root t))
    (e2e-docker--with-target "rootc" e2e-docker-root nil
      (let ((conn (rdev--connect "rootc")))
        (should (rdev-conn-root-mode conn))
        (should (eq (e2e-docker--state "rootc") 'connected))))))

;;;; Disconnect leaves the container and its services running

(ert-deftest e2e-docker-disconnect-leaves-container ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--with-target "dev" e2e-docker-dev nil
    (rdev--connect "dev")
    (rdev-disconnect "dev")
    ;; The container itself is untouched: still running, still serving.
    (should (equal (string-trim
                    (cdr (e2e-docker--docker "inspect" "-f" "{{.State.Running}}"
                                             e2e-docker-dev)))
                   "true"))
    (should (equal (string-trim
                    (e2e-docker--exec e2e-docker-dev "echo still-here"))
                   "still-here"))))

;;;; Open a container by its explicit address, without configuring `rdev-hosts'

(ert-deftest e2e-docker-open-by-address-without-config ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (e2e-docker--reset)
  (setq rdev-hosts nil)
  (let ((key (concat "docker+" e2e-docker-dev)))
    (unwind-protect
        (let ((f (format "/rdev:%s:/workspace/hello.txt" key)))
          ;; The running container is offered under its address...
          (should (member key (rdev--target-completion)))
          ;; ...and its bare name is never taken for it.
          (should-not (rdev--docker-p e2e-docker-dev))
          (e2e-docker--exec e2e-docker-dev "printf 'hello\n' > /workspace/hello.txt")
          (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                         "hello\n"))
          (write-region "by address\n" nil f nil 'silent)
          (should (equal (e2e-docker--exec e2e-docker-dev "cat /workspace/hello.txt")
                         "by address\n"))
          (should (eq (rdev-conn-transport (rdev--conn key)) 'docker))
          ;; Nothing was added to the configuration.
          (should-not rdev-hosts))
      (ignore-errors (rdev-disconnect key))
      (e2e-docker--reset)
      (setq rdev-hosts nil))))

;;;; Remote engine over SSH

(ert-deftest e2e-docker-remote-engine ()
  (e2e-docker--need "RDEV_TEST_DOCKER_DEV" e2e-docker-dev)
  (let ((cfg (getenv "RDEV_TEST_SSH_CONFIG"))
        (ssh-host (getenv "RDEV_TEST_HOST")))
    (unless (and cfg ssh-host)
      (ert-skip "RDEV_TEST_SSH_CONFIG/RDEV_TEST_HOST not set"))
    (let ((rdev-ssh-args (append (list "-F" cfg) rdev-ssh-args)))
      (e2e-docker--with-target "remote" e2e-docker-dev (list :docker-host ssh-host)
        (rdev--connect "remote")
        (should (eq (e2e-docker--state "remote") 'connected))
        (should (string-prefix-p "docker:" (rdev-state-session-key "remote")))
        (e2e-docker--exec e2e-docker-dev "printf 'hello\n' > /workspace/hello.txt")
        (let ((f "/rdev:remote:/workspace/hello.txt"))
          (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                         "hello\n"))
          (write-region "remote engine\n" nil f nil 'silent)
          (should (equal (e2e-docker--exec e2e-docker-dev "cat /workspace/hello.txt")
                         "remote engine\n")))
        ;; A local target with the same container name is a separate session.
        (e2e-docker--configure "local" e2e-docker-dev)
        (rdev--connect "local")
        (should-not (equal (rdev-state-session-key "remote")
                           (rdev-state-session-key "local")))))
    ;; An unreachable engine host reports an SSH error, not not-found.
    (e2e-docker--with-target "bad" e2e-docker-dev '(:docker-host "rdev-no-such-host")
      (let ((err (should-error (rdev--connect "bad"))))
        (should (eq (car err) 'rdev-ssh-error))))))

(provide 'e2e-docker)
;;; docker.el ends here
