;;; dape.el --- E2E Dape with a real debugpy adapter on the remote host (T102, FR-028)  -*- lexical-binding: t; -*-
;; Needs the optional `dape' package locally and `debugpy' on the remote.  A venv with debugpy
;; is created on demand (/tmp/rdev-dape-venv, see dape-fixture.sh); tests tagged :needs-debugpy
;; skip with a visible reason when dape or debugpy cannot be provided.
;;
;; The DAP socket is reached through an `ssh -L' tunnel (rdev does not forward ports itself);
;; the adapter process itself is started through rdev's `make-process' handler.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(let ((d (car (file-expand-wildcards (expand-file-name "~/.emacs.d/elpa/dape-*")))))
  (when d (add-to-list 'load-path d)))
(require 'dape nil t)
(require 'python)

(defvar e2e-dape--venv "/tmp/rdev-dape-venv")

(defun e2e-dape--sh (cmd)
  (let ((default-directory (concat (e2e--root) "/tmp/")) out code)
    (with-temp-buffer
      (setq code (process-file "sh" nil t nil "-c" cmd))
      (setq out (string-trim (buffer-string))))
    (cons code out)))

(defun e2e-dape--python ()
  "Return the remote python that has debugpy (creating the venv), or nil."
  (let ((py (concat e2e-dape--venv "/bin/python")))
    (when (/= 0 (car (e2e-dape--sh (format "%s -c 'import debugpy'" py))))
      (e2e-dape--sh (format "python3 -m venv %s && %s -m pip install --quiet debugpy"
                            e2e-dape--venv py)))
    (and (= 0 (car (e2e-dape--sh (format "%s -c 'import debugpy'" py)))) py)))

(defun e2e-dape--free-port ()
  (let* ((s (make-network-process :name "p" :server t :host "127.0.0.1" :service t
                                  :noquery t))
         (port (process-contact s :service)))
    (delete-process s)
    port))

(defun e2e-dape--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun e2e-dape--adapters ()
  "Number of debugpy adapter processes on the remote for this test run's venv."
  (string-to-number
   (cdr (e2e-dape--sh (format "pgrep -f '%s/bin/python -m [d]ebugpy.adapter' | wc -l"
                              e2e-dape--venv)))))

(defmacro e2e-dape-with-session (&rest body)
  "Run BODY with `proj', `prog', `py', `port', `tunnel' and `config' bound."
  (declare (indent 0))
  `(progn
     (unless (featurep 'dape) (ert-skip "dape is not installed locally"))
     (let ((py (e2e-dape--python)))
       (unless py (ert-skip "debugpy could not be installed on the remote host"))
       (e2e-with-dir
         (let* ((proj (concat e2e--dir "proj/")) (prog (concat proj "prog.py"))
                (vc-handled-backends nil)
                (port (e2e-dape--free-port))
                (dape-debug (and (getenv "RDEV_TEST_DEBUG") t))
                (tunnel nil) (config nil))
           (make-directory proj t)
           (write-region (concat "import os, sys\n"
                                 "x = 41\n"
                                 "y = x + 1\n"
                                 "print('OUT:' + os.getcwd())\n"
                                 "sys.stdout.flush()\n")
                         nil prog nil 'silent)
           (setq config
                 (list 'modes '(python-mode)
                       'command py
                       'command-args (list "-m" "debugpy.adapter" "--host" "127.0.0.1"
                                           "--port" (number-to-string port))
                       'command-cwd proj
                       'port port 'host "localhost"
                       'prefix-local (e2e--root) 'prefix-remote ""
                       :request "launch" :type "python"
                       :cwd (file-local-name proj) :program (file-local-name prog)
                       :console "internalConsole" :justMyCode :json-false
                       :args []))
           (setq tunnel (make-process
                         :name "e2e-dape-tunnel" :noquery t :buffer nil
                         :command (append (list "ssh") rdev-ssh-args
                                          (list "-N" "-L"
                                                (format "%d:127.0.0.1:%d" port port)
                                                e2e-host))))
           (unwind-protect (progn ,@body)
             (ignore-errors (dape-quit))
             (ignore-errors (dape--kill-busy-wait))
             (ignore-errors (delete-process tunnel))
             (dolist (b (buffer-list))
               (when (and (buffer-file-name b) (string-prefix-p e2e--dir (buffer-file-name b)))
                 (with-current-buffer b (set-buffer-modified-p nil))
                 (kill-buffer b)))))))))

(defun e2e-dape--conn () (and (fboundp 'dape--live-connection) (dape--live-connection 'last t)))

(defun e2e-dape--stopped-p ()
  (let ((c (e2e-dape--conn))) (and c (dape--stopped-threads c))))

(defun e2e-dape--start-and-stop (prog config)
  "Open PROG, break on line 3, start the session, wait for the stop."
  ;; Without a REPL buffer Dape sends debuggee output to `message' only.
  (ignore-errors (dape-repl))
  (with-current-buffer (find-file-noselect prog)
    (python-mode)
    (goto-char (point-min)) (forward-line 2)
    (dape-breakpoint-toggle)
    (let ((default-directory (file-name-directory prog)))
      (dape config)))
  (should (e2e-dape--wait #'e2e-dape--stopped-p 60))
  ;; Stack frames arrive in a follow-up request after the `stopped' event.
  (should (e2e-dape--wait
           (lambda () (plist-get (dape--current-stack-frame (e2e-dape--conn)) :source))
           30)))

(ert-deftest e2e-dape-breakpoint-hit-with-path-mapping ()
  :tags '(:needs-debugpy)
  (e2e-dape-with-session
    (e2e-dape--start-and-stop prog config)
    (let* ((conn (e2e-dape--conn))
           (frame (dape--current-stack-frame conn))
           (rpath (plist-get (plist-get frame :source) :path)))
      ;; The adapter reports a plain remote path; Dape maps it back to an /rdev: file name.
      (should (equal rpath (file-local-name prog)))
      (should (equal (dape--file-name-local conn rpath) prog))
      (should (= 3 (plist-get frame :line))))))

(ert-deftest e2e-dape-cwd-output-and-termination ()
  :tags '(:needs-debugpy)
  (e2e-dape-with-session
    (e2e-dape--start-and-stop prog config)
    (should (> (e2e-dape--adapters) 0))
    (dape-continue (e2e-dape--conn))
    (when (getenv "RDEV_TEST_DEBUG")
      (e2e-dape--wait (lambda () nil) 8)
      (message "REPL=%S conn=%S" (and (get-buffer "*dape-repl*")
                                      (with-current-buffer "*dape-repl*" (buffer-string)))
               (e2e-dape--conn)))
    (should (e2e-dape--wait
             (lambda ()
               (when-let* ((b (get-buffer "*dape-repl*")))
                 (with-current-buffer b
                   (save-excursion (goto-char (point-min))
                                   (search-forward (concat "OUT:" (directory-file-name (file-local-name proj))) nil t)))))
             30))
    ;; Debuggee ran with the requested working directory on the remote host.
    (should (e2e-dape--wait (lambda () (null (e2e-dape--conn))) 30))
    ;; Termination must not leave the adapter running on the remote.
    (should (e2e-dape--wait (lambda () (= 0 (e2e-dape--adapters))) 15))))

(ert-deftest e2e-dape-quit-kills-remote-adapter ()
  :tags '(:needs-debugpy)
  (e2e-dape-with-session
    (e2e-dape--start-and-stop prog config)
    (should (> (e2e-dape--adapters) 0))
    (dape-quit)
    (should (e2e-dape--wait (lambda () (= 0 (e2e-dape--adapters))) 20))))

(ert-deftest e2e-dape-missing-adapter-is-actionable ()
  "A python without debugpy gives a clear message instead of a hang."
  (unless (featurep 'dape) (ert-skip "dape is not installed locally"))
  (e2e-with-dir
    (let* ((proj (concat e2e--dir "p/")) (vc-handled-backends nil)
           (default-directory proj)
           (err (progn (make-directory proj t)
                       (condition-case e (dape--ensure-executable "/nonexistent/python-xyz")
                         (user-error (cadr e))))))
      (should (stringp err))
      (should (string-match-p "Unable to locate" err)))))

(ert-deftest e2e-dape-connection-loss-ends-session-and-recovers ()
  "Losing the rdev connection mid-session ends the session cleanly; rdev then reconnects."
  :tags '(:needs-debugpy)
  (e2e-dape-with-session
    (e2e-dape--start-and-stop prog config)
    (let ((rpc (rdev-conn-rpc (rdev--conn e2e-host))))
      (delete-process (jsonrpc--process rpc)))
    ;; The adapter's relay died with the transport: the session must end, not hang.
    (should (e2e-dape--wait (lambda () (null (e2e-dape--conn))) 40))
    ;; A later file operation reconnects transparently and the adapter is gone.
    ;; (While reconnecting, rdev reports "retry shortly" instead of blocking.)
    (should (e2e-dape--wait
             (lambda () (condition-case nil (file-exists-p prog)
                          (rdev-connection-lost nil)))
             60))
    (should (e2e-dape--wait (lambda () (= 0 (e2e-dape--adapters))) 20))))
