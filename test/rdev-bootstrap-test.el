;;; rdev-bootstrap-test.el --- agent bootstrap robustness (T049, SC-004)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'cl-lib)

(defun rdev-bs--remote-cmd ()
  "The remote shell command string rdev would pass to ssh."
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest a) (setq cmd (plist-get a :command)) (error "stubbed")))
              ((symbol-function 'rdev--wait-for) #'ignore))
      (ignore-errors (rdev--ssh-process "goodhost" nil)))
    (car (last cmd))))

(defun rdev-bs--run (remote home stdin-bytes &optional path)
  "Run REMOTE under sh with HOME, feeding STDIN-BYTES; return output string.
The script ends with `exec python -u agent --stdio'; stdin EOF ends it."
  (let ((process-environment (append (list (concat "HOME=" home)
                                           (concat "PATH=" (or path (getenv "PATH"))))
                                     process-environment))
        (default-directory temporary-file-directory)
        (coding-system-for-read 'binary) (coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert stdin-bytes)
      (let ((out (generate-new-buffer " *bs-out*")))
        (unwind-protect
            (progn (call-process-region (point-min) (point-max) "sh" nil out nil "-c" remote)
                   (with-current-buffer out (buffer-string)))
          (kill-buffer out))))))

(defun rdev-bs--installed (home)
  (file-expand-wildcards (concat home "/.cache/rdev/rdev-server-*.py")))

(defun rdev-bs--leftovers (home)
  (file-expand-wildcards (concat home "/.cache/rdev/*.tmp.*")))

(defmacro rdev-bs--with-home (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "rdev-bs-home" t)))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(ert-deftest rdev-bs-full-upload-installs-and-reports-ready ()
  (rdev-bs--with-home home
    (let* ((remote (rdev-bs--remote-cmd))
           (out (rdev-bs--run remote home (rdev--server-script))))
      (should (string-match-p "^RDEV-BOOT need$" out))
      (should (string-match-p "^RDEV-READY$" out))
      (should (= 1 (length (rdev-bs--installed home))))
      (should-not (rdev-bs--leftovers home))
      ;; second run: cached, no upload needed
      (let ((out2 (rdev-bs--run remote home "")))
        (should (string-match-p "^RDEV-BOOT ok$" out2))
        (should (string-match-p "^RDEV-READY$" out2))))))

(ert-deftest rdev-bs-interrupted-upload-never-installs-100-trials ()
  "SC-004: at every random prefix an interrupted upload leaves nothing installed and
the next full attempt succeeds; >= 99/100 trials must recover."
  (let* ((remote (rdev-bs--remote-cmd))
         (script (rdev--server-script))
         (n (length script)) (ok 0) (trials 100))
    (random "rdev-bootstrap-seed")
    (dotimes (_ trials)
      (rdev-bs--with-home home
        (let ((cut (random n)))
          (rdev-bs--run remote home (substring script 0 cut))
          (when (and (null (rdev-bs--installed home)) (null (rdev-bs--leftovers home)))
            (let ((out (rdev-bs--run remote home script)))
              (when (and (string-match-p "^RDEV-READY$" out)
                         (= 1 (length (rdev-bs--installed home))))
                (cl-incf ok)))))))
    (should (>= ok 99))))

(ert-deftest rdev-bs-corrupt-same-size-upload-rejected ()
  (rdev-bs--with-home home
    (let* ((remote (rdev-bs--remote-cmd))
           (script (rdev--server-script))
           (bad (concat (substring script 0 100) "X" (substring script 101)))
           (out (rdev-bs--run remote home bad)))
      (should (string-match-p "RDEV-ERR agent upload was truncated or corrupted" out))
      (should-not (rdev-bs--installed home))
      (should-not (rdev-bs--leftovers home)))))

(ert-deftest rdev-bs-corrupt-cached-agent-is-replaced ()
  (rdev-bs--with-home home
    (let* ((remote (rdev-bs--remote-cmd)) (script (rdev--server-script)))
      (rdev-bs--run remote home script)
      (let ((f (car (rdev-bs--installed home))))
        (with-temp-file f (insert "print('tampered')"))
        (let ((out (rdev-bs--run remote home script)))
          (should (string-match-p "^RDEV-BOOT need$" out))
          (should (string-match-p "^RDEV-READY$" out))
          (should (= (length script) (file-attribute-size (file-attributes f)))))))))

(ert-deftest rdev-bs-old-python-reports-error-before-upload ()
  (rdev-bs--with-home home
    (let* ((bin (make-temp-file "rdev-bs-bin" t)) (py (expand-file-name "python3" bin)))
      (unwind-protect
          (progn
            (with-temp-file py (insert "#!/bin/sh\nexit 1\n"))
            (set-file-modes py #o755)
            (let ((out (rdev-bs--run (rdev-bs--remote-cmd) home (rdev--server-script)
                                     (concat bin ":/usr/bin:/bin"))))
              (should (string-match-p "RDEV-ERR python3 >= 3.8" out))
              (should-not (rdev-bs--installed home))))
        (delete-directory bin t)))))

(ert-deftest rdev-bs-leftover-tmp-does-not-block ()
  (rdev-bs--with-home home
    (make-directory (concat home "/.cache/rdev") t)
    (with-temp-file (concat home "/.cache/rdev/rdev-server-x.py.tmp.123") (insert "junk"))
    (let ((out (rdev-bs--run (rdev-bs--remote-cmd) home (rdev--server-script))))
      (should (string-match-p "^RDEV-READY$" out))
      (should (= 1 (length (rdev-bs--installed home)))))))

(ert-deftest rdev-bs-install-permissions-are-private ()
  (rdev-bs--with-home home
    (rdev-bs--run (rdev-bs--remote-cmd) home (rdev--server-script))
    (should (= #o700 (file-modes (concat home "/.cache/rdev"))))
    (should (= #o700 (file-modes (car (rdev-bs--installed home)))))))

(defun rdev-bs--feed (proc chunks)
  (dolist (c chunks) (rdev--bootstrap-filter proc c)))

(ert-deftest rdev-bs-filter-noisy-banner-split-markers-and-residual ()
  (let ((proc (make-process :name "bs-filter" :command '("cat") :noquery t)))
    (unwind-protect
        (progn
          (process-put proc 'rdev-log "")
          (rdev-bs--feed proc '("Welcome to host\nLast login: now\n" "RDEV-BO" "OT ok\nRDEV-RE" "ADY\nContent-Len" "gth: 2\r\n\r\n{}"))
          (should (eq 'ready (process-get proc 'rdev-state)))
          (should (equal "Content-Length: 2\r\n\r\n{}" (process-get proc 'rdev-residual))))
      (delete-process proc))))

(ert-deftest rdev-bs-filter-banner-containing-marker-text-midline-is-ignored ()
  (let ((proc (make-process :name "bs-filter2" :command '("cat") :noquery t)))
    (unwind-protect
        (progn
          (process-put proc 'rdev-log "")
          (rdev-bs--feed proc '("note: see RDEV-READY docs\n"))
          (should-not (process-get proc 'rdev-state))
          (rdev-bs--feed proc '("RDEV-READY\n"))
          (should (eq 'ready (process-get proc 'rdev-state))))
      (delete-process proc))))

(ert-deftest rdev-bs-filter-err-marker-sets-error ()
  (let ((proc (make-process :name "bs-filter3" :command '("cat") :noquery t)))
    (unwind-protect
        (progn
          (process-put proc 'rdev-log "")
          (rdev-bs--feed proc '("RDEV-ERR python3 >= 3.8 not found on this host\n"))
          (should (eq 'error (process-get proc 'rdev-state)))
          (should (string-match-p "3.8" (process-get proc 'rdev-error))))
      (delete-process proc))))

(provide 'rdev-bootstrap-test)
