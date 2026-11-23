;;; save-fault.el --- E2E fault-injected saves: no corruption, no lost edits (T035, SC-002)  -*- lexical-binding: t; -*-
;; RDEV_FAULT_TRIALS (default 100) saves of a multi-chunk file, each with the ssh process
;; kill -9'd at a random moment between 0 and 1.4x the measured duration of an unfaulted
;; save of the same file, so kills land before, during and after the commit.
;; Invariants per trial:
;;  * the remote file is byte-for-byte the OLD or the NEW content (never partial/truncated);
;;  * no atomic-write temp file is left behind;
;;  * the local edit is never lost: a failed save leaves the buffer modified with the new
;;    text; a successful save means the remote has the new text.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun e2e-sf--wait-reconnected (gen timeout)
  (let ((deadline (+ (float-time) timeout)))
    (while (and (< (float-time) deadline)
                (not (let ((c (gethash e2e-host rdev--conns)))
                       (and c (eq 'connected (rdev-state (rdev-state-session-key e2e-host)))
                            (> (or (rdev-conn-gen c) 0) gen)))))
      (accept-process-output nil 0.05))
    (> (or (rdev-conn-gen (rdev--conn e2e-host)) 0) gen)))

(defun e2e-sf--kill-ssh ()
  (let* ((c (gethash e2e-host rdev--conns))
         (proc (and c (jsonrpc--process (rdev-conn-rpc c)))))
    (when (and proc (process-live-p proc)) (signal-process (process-id proc) 'KILL) t)))

(defun e2e-sf--read (file)
  "Contents of FILE, retrying while the connection is re-establishing."
  (let ((deadline (+ (float-time) 60)) out)
    (while (and (not out) (< (float-time) deadline))
      (condition-case nil
          (setq out (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))
        (rdev-connection-lost (accept-process-output nil 0.2))))
    out))

(ert-deftest e2e-save-fault-injection-never-corrupts ()
  (let* ((trials (string-to-number (or (getenv "RDEV_FAULT_TRIALS") "100")))
         (rdev-reconnect-base 0.3) (rdev-reconnect-cap 3.0)
         (make-backup-files nil)
         (body (lambda (tag) (mapconcat (lambda (i) (format "%s line %06d\n" tag i))
                                        (number-sequence 1 30000) "")))
         (old (funcall body "old")) (new (funcall body "NEW"))
         (max-ms 60) (ok 0) (failed 0) (corrupt nil) (litter nil) (lost nil) (committed-but-error 0))
    (random "rdev-save-fault")
    (rdev--conn e2e-host)
    (e2e-with-dir
      ;; Calibrate: median of three unfaulted saves.
      (setq max-ms
            (let ((f (concat e2e--dir "calib.txt")) ts)
              (write-region old nil f nil 'silent)
              (with-current-buffer (find-file-noselect f)
                (dotimes (_ 3)
                  (erase-buffer) (insert new)
                  (let ((t0 (float-time))) (save-buffer) (push (- (float-time) t0) ts))
                  (erase-buffer) (insert old) (save-buffer))
                (set-buffer-modified-p nil) (kill-buffer))
              (max 20 (round (* 1400 (nth 1 (sort ts #'<)))))))
      (dotimes (i trials)
        (let* ((f (format "%sf%03d.txt" e2e--dir i))
               (dir (file-name-directory f))
               (gen (rdev-conn-gen (rdev--conn e2e-host)))
               (fired nil) timer)
          (write-region old nil f nil 'silent)
          (with-current-buffer (find-file-noselect f)
            (unwind-protect
                (progn
                  (erase-buffer) (insert new)
                  (setq timer (run-at-time (/ (random (1+ max-ms)) 1000.0) nil
                                           (lambda () (setq fired (e2e-sf--kill-ssh)))))
                  (let* ((last-err nil)
                         (saved (condition-case err (progn (save-buffer) t)
                                  (error (setq last-err (error-message-string err)) nil))))
                    (cancel-timer timer)
                    (unless fired (e2e-sf--kill-ssh))   ; every trial sees exactly one kill
                    (e2e-sf--wait-reconnected gen 60)
                    (let ((remote (e2e-sf--read f)))
                      (cond ((equal remote new))
                            ((equal remote old))
                            (t (push (cons i (length remote)) corrupt)))
                      (if saved
                          (progn (cl-incf ok)
                                 (unless (equal remote new) (push (cons i 'saved-but-old) lost)))
                        (cl-incf failed)
                        (when (equal remote new) (cl-incf committed-but-error))
                        ;; Invariant (Art. III): after a failed save the new text is never only in a buffer
                        ;; that claims to be clean.  Either the buffer is still modified and holds the
                        ;; new text, or the commit had already happened (rename done, only a later
                        ;; stat failed), so the remote holds exactly the new text.
                        (unless (or (and (buffer-modified-p) (equal (buffer-string) new))
                                    (and (equal (buffer-string) new) (equal remote new)))
                          ;; Keep the evidence: which half of the invariant broke, and what
                          ;; the remote holds.
                          (push (list i 'local-edit-lost
                                      :modified (buffer-modified-p)
                                      :text (cond ((equal (buffer-string) new) 'new)
                                                  ((equal (buffer-string) old) 'old)
                                                  (t (length (buffer-string))))
                                      :remote (cond ((equal remote new) 'new)
                                                    ((equal remote old) 'old)
                                                    (t 'other))
                                      :err last-err)
                                lost))))
                    (let ((names (directory-files dir nil "\\`[^.]")))
                      (dolist (n names)
                        (unless (equal n (file-name-nondirectory f))
                          (unless (string-match-p (format "\\`f%03d\\.txt\\'" i) n)
                            (when (string-match-p (format "\\`f%03d" i) n) (push n litter))))))))
              (set-buffer-modified-p nil) (kill-buffer))))))
    (message "save-fault: kill window 0-%d ms; %d trials, %d saved, %d failed (%d of those had committed), corrupt %S, litter %S, lost %S"
             max-ms trials ok failed committed-but-error corrupt litter lost)
    (should (= trials (+ ok failed)))
    (should-not corrupt)
    (should-not litter)
    (should-not lost)))
