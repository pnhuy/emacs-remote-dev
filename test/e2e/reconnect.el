;;; reconnect.el --- E2E reconnect after kill -9 of ssh (T051, FR-009, SC-005)  -*- lexical-binding: t; -*-
;; RDEV_RECONNECT_TRIALS (default 5) sets the number of kill/recover cycles.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defvar e2e-rc--hook-count 0)
(defvar e2e-rc--g 0)

(defun e2e-rc--wait-state (state timeout)
  (let ((deadline (+ (float-time) timeout)) (key (rdev-state-session-key e2e-host)))
    (while (and (not (eq state (rdev-state key))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (eq state (rdev-state key))))

(defun e2e-rc--wait-reconnected (gen timeout)
  "Wait until the connection is `connected' again with a generation above GEN.
Killing ssh is asynchronous: the state may still read `connected' for a
moment, so state alone cannot prove that the reconnect happened."
  (let ((deadline (+ (float-time) timeout)) (key (rdev-state-session-key e2e-host)))
    (while (and (< (float-time) deadline)
                (not (and (eq 'connected (rdev-state key))
                          (let ((c (gethash e2e-host rdev--conns)))
                            (and c (> (or (rdev-conn-gen c) 0) gen))))))
      (accept-process-output nil 0.05))
    (and (eq 'connected (rdev-state key))
         (> (or (rdev-conn-gen (rdev--conn e2e-host)) 0) gen))))

(defun e2e-rc--kill-ssh ()
  "kill -9 the local ssh process behind the connection."
  (let* ((c (rdev--conn e2e-host))
         (proc (jsonrpc--process (rdev-conn-rpc c))))
    (should (process-live-p proc))
    (signal-process (process-id proc) 'KILL)))

(ert-deftest e2e-reconnect-after-ssh-kill ()
  (let* ((trials (string-to-number (or (getenv "RDEV_RECONNECT_TRIALS") "5")))
         (key (progn (rdev--conn e2e-host) (rdev-state-session-key e2e-host)))
         (rdev-reconnect-base 0.5) (rdev-reconnect-cap 5.0)
         (times nil) (hook 0)
         (fn (lambda (_k) (cl-incf hook))))
    (add-hook 'rdev-reconnected-hook fn)
    (unwind-protect
        (dotimes (_ trials)
          (let ((gen (rdev-conn-gen (rdev--conn e2e-host))) (t0 (float-time)))
            (e2e-rc--kill-ssh)
            (should (e2e-rc--wait-reconnected gen 30))
            (push (- (float-time) t0) times)
            (should (> (rdev-conn-gen (rdev--conn e2e-host)) gen))
            ;; The new connection serves requests.
            (should (stringp (rdev-conn-home (rdev--conn e2e-host))))))
      (remove-hook 'rdev-reconnected-hook fn))
    (message "reconnect: %d trials, times %S" trials (reverse times))
    (should (= hook trials))
    (should (cl-every (lambda (x) (< x 30)) times))
    (should (eq 'connected (rdev-state key)))))

(ert-deftest e2e-reconnect-preserves-buffers-and-marks-processes ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "edit.txt"))
           (make-backup-files nil) ; backup-by-rename would hide the file from the version check
           (rdev-reconnect-base 0.5))
      (write-region "one\n" nil f nil 'silent)
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-max)) (insert "unsaved\n")
        (let ((buf (current-buffer))
              (pr (make-process :name "e2e-sleep" :buffer nil :noquery t
                                :command '("sleep" "300") :file-handler t
                                :connection-type 'pipe
                                :default-directory e2e--dir)))

          (let ((g (rdev-conn-gen (rdev--conn e2e-host))))
            (e2e-rc--kill-ssh)
            (should (e2e-rc--wait-reconnected g 30)))
          ;; Unsaved edits survived; the process is not carried over.
          (should (buffer-modified-p buf))
          (should (equal "one\nunsaved\n" (buffer-string)))
          (should-not (process-live-p pr))
          ;; Save works on the new connection when nothing changed remotely.
          (save-buffer)
          (should (equal "one\nunsaved\n"
                         (with-temp-buffer (insert-file-contents f) (buffer-string)))))
        (set-buffer-modified-p nil)
        (kill-buffer (current-buffer))))))

(ert-deftest e2e-reconnect-save-rechecks-version ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "ver.txt")) (make-backup-files nil) (rdev-reconnect-base 0.5))
      (write-region "base\n" nil f nil 'silent)
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-max)) (insert "mine\n")
        (let ((g (rdev-conn-gen (rdev--conn e2e-host))))
          (e2e-rc--kill-ssh)
          (should (e2e-rc--wait-reconnected g 30)))
        ;; Someone else changes the file while we were away.
        (let ((default-directory e2e--dir))
          (process-file "sh" nil nil nil "-c" "sleep 1; echo theirs > ver.txt"))
        (cl-letf (((symbol-function 'ask-user-about-supersession-threat) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (should-error (save-buffer)))
        (should (buffer-modified-p))
        (set-buffer-modified-p nil)
        (kill-buffer (current-buffer))))))

(ert-deftest e2e-reconnect-pending-request-fails ()
  (let ((rdev-reconnect-base 0.5))
    (rdev--conn e2e-host)
    (setq e2e-rc--g (rdev-conn-gen (rdev--conn e2e-host)))
    (run-at-time 0.5 nil #'e2e-rc--kill-ssh)
    (should-error (rdev--req e2e-host :exec/run `(:cmd ,(vector "sleep" "60")))
                  :type 'rdev-connection-lost)
    (should (e2e-rc--wait-reconnected e2e-rc--g 30))))
