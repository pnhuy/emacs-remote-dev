;;; rdev-process-test.el --- remote process integration (T026)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defvar rdev-test--twin-remote-dir nil)
(defun rdev-test--twin-remote () rdev-test--twin-remote-dir)

(defun rdev-test--wait (proc &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.1))
    (accept-process-output proc 0.2)))

(ert-deftest rdev-proc-process-file-output-and-exit ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (with-temp-buffer
        (should (= 0 (process-file "echo" nil t nil "hi" "there")))
        (should (equal (buffer-string) "hi there\n")))
      (with-temp-buffer
        (should (= 3 (process-file "sh" nil t nil "-c" "echo out; exit 3")))
        (should (equal (buffer-string) "out\n"))))))

(ert-deftest rdev-proc-process-file-cwd-and-args-literal ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory (concat remote "sub/")))
      (with-temp-buffer
        (process-file "pwd" nil t nil)
        (should (string-suffix-p "/sub\n" (buffer-string))))
      (with-temp-buffer
        ;; Arguments are passed as argv, never re-parsed by a shell.
        (process-file "echo" nil t nil "$HOME;ls" "a b")
        (should (equal (buffer-string) "$HOME;ls a b\n"))))))

(ert-deftest rdev-proc-process-file-stdin-and-stderr ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote) (in (make-temp-file "rdev-in")))
      (unwind-protect
          (progn
            (write-region "from-stdin" nil in nil 'silent)
            (with-temp-buffer
              (process-file "cat" in t nil)
              (should (equal (buffer-string) "from-stdin")))
            (let ((err (make-temp-file "rdev-err")))
              (unwind-protect
                  (with-temp-buffer
                    (process-file "sh" nil (list t err) nil "-c" "echo o; echo e >&2")
                    (should (equal (buffer-string) "o\n"))
                    (should (equal (with-temp-buffer (insert-file-contents err) (buffer-string))
                                   "e\n")))
                (delete-file err))))
        (delete-file in)))))

(ert-deftest rdev-proc-process-file-missing-program ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (with-temp-buffer
        (should-error (process-file "definitely-not-a-program-xyz" nil t nil))))))

(ert-deftest rdev-proc-shell-command ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (should (equal (string-trim (shell-command-to-string "echo sc")) "sc")))))

(ert-deftest rdev-proc-make-process-filter-sentinel ()
  (rdev-test-with-twin-dir (native remote)
    (let* ((default-directory remote) (out "") status
           (proc (make-process :name "rdev-t" :command '("sh" "-c" "echo hello; exit 2")
                               :connection-type 'pipe :noquery t
                               :filter (lambda (_p s) (setq out (concat out s)))
                               :sentinel (lambda (_p e) (setq status e)))))
      (rdev-test--wait proc)
      (should (string-match-p "hello" out))
      (should (string-match-p "exited abnormally with code 2" (or status ""))))))

(defun rdev-test--interactive-cat (pipe-p)
  "Run remote cat, send \"ping\", return the buffer text seen before EOF."
  (let* ((default-directory (rdev-test--twin-remote))
         (buf (generate-new-buffer " *rdev-cat*"))
         (proc (let ((process-connection-type (not pipe-p)))
                 (start-file-process "rdev-cat" buf "cat")))
         seen)
    (unwind-protect
        (progn
          (set-process-query-on-exit-flag proc nil)
          (process-send-string proc "ping\n")
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (with-current-buffer buf (string-match-p "ping" (buffer-string))))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)))
          (setq seen (with-current-buffer buf (buffer-string)))
          (process-send-eof proc)
          (rdev-test--wait proc)
          seen)
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer buf))))

(ert-deftest rdev-proc-start-file-process-pipe-stdin ()
  (rdev-test-with-twin-dir (native remote)
    (let ((rdev-test--twin-remote-dir remote))
      (should (string-match-p "ping" (rdev-test--interactive-cat t))))))

(ert-deftest rdev-proc-start-file-process-pty-stdin ()
  "With a pty (the Emacs default) remote cat echoes input.
Regression for the relay flushing early pty input (TCSAFLUSH -> TCSANOW)."
  (rdev-test-with-twin-dir (native remote)
    (let ((rdev-test--twin-remote-dir remote))
      (should (string-match-p "ping" (rdev-test--interactive-cat nil))))))

(ert-deftest rdev-proc-env-forwarded ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote)
          (process-environment (cons "RDEV_TEST_VAR=forwarded" process-environment)))
      (with-temp-buffer
        (process-file "sh" nil t nil "-c" "printf %s \"$RDEV_TEST_VAR\"")
        (should (equal (buffer-string) "forwarded"))))))

(provide 'rdev-process-test)
;;; rdev-process-test.el ends here
