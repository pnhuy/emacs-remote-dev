;;; baseline.el --- E2E baseline over real ssh (T031)  -*- lexical-binding: t; -*-

;; Uses RDEV_TEST_HOST (+ optional RDEV_TEST_SSH_CONFIG) from test/e2e/run.sh.
;; Exercises the real path: ssh -> bootstrap -> agent -> JSON-RPC -> file handlers/processes.

(require 'rdev)

(defconst e2e-host (or (getenv "RDEV_TEST_HOST") (error "RDEV_TEST_HOST not set")))
(when-let* ((cfg (getenv "RDEV_TEST_SSH_CONFIG")))
  (setq rdev-ssh-args (append (list "-F" cfg) rdev-ssh-args)))
(setq rdev-ssh-args (append rdev-ssh-args '("-o" "BatchMode=yes" "-o" "ConnectTimeout=15")))

(defvar e2e--dir nil "Remote scratch directory as an /rdev: name (with trailing slash).")

(defun e2e--root () (format "/rdev:%s:" e2e-host))

(defmacro e2e-with-dir (&rest body)
  (declare (indent 0))
  `(let* ((e2e--dir (format "%s/tmp/rdev-e2e-%d-%d/" (e2e--root) (emacs-pid) (random 1000000))))
     (make-directory e2e--dir t)
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory e2e--dir t)))))

(ert-deftest e2e-connect-and-hello ()
  (let ((c (rdev--connect e2e-host)))
    (should (rdev-conn-p c))
    (should (stringp (rdev-conn-home c)))
    (should (file-directory-p (concat (e2e--root) (rdev-conn-home c))))))

(ert-deftest e2e-text-roundtrip-and-encoding ()
  (e2e-with-dir
    (let ((f (concat e2e--dir "t.txt")))
      (write-region "héllo ✓\nline2\n" nil f nil 'silent)
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                     "héllo ✓\nline2\n")))))

(ert-deftest e2e-binary-roundtrip ()
  (e2e-with-dir
    (let ((f (concat e2e--dir "b.bin"))
          (bytes (apply #'unibyte-string (number-sequence 0 255))))
      (let ((coding-system-for-write 'no-conversion))
        (write-region bytes nil f nil 'silent))
      (should (equal (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (let ((coding-system-for-read 'no-conversion))
                         (insert-file-contents-literally f))
                       (buffer-string))
                     bytes)))))

(ert-deftest e2e-large-file-roundtrip ()
  (e2e-with-dir
    (let ((f (concat e2e--dir "big.txt"))
          (text (mapconcat (lambda (i) (format "line %07d\n" i)) (number-sequence 1 200000) "")))
      (write-region text nil f nil 'silent)
      (should (= (file-attribute-size (file-attributes f)) (length text)))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-size)) (length text))))))

(ert-deftest e2e-directory-ops-and-attributes ()
  (e2e-with-dir
    (make-directory (concat e2e--dir "d/e") t)
    (write-region "x" nil (concat e2e--dir "d/a") nil 'silent)
    (should (equal (directory-files (concat e2e--dir "d") nil "\\`[^.]") '("a" "e")))
    (should (file-directory-p (concat e2e--dir "d/e")))
    (should (= 1 (file-attribute-size (file-attributes (concat e2e--dir "d/a")))))
    (rename-file (concat e2e--dir "d/a") (concat e2e--dir "d/b"))
    (should (file-exists-p (concat e2e--dir "d/b")))
    (make-symbolic-link "b" (concat e2e--dir "d/ln"))
    (should (equal (file-symlink-p (concat e2e--dir "d/ln")) "b"))))

(ert-deftest e2e-process-file-and-shell-command ()
  (e2e-with-dir
    (let ((default-directory e2e--dir))
      (with-temp-buffer
        (should (= 0 (process-file "pwd" nil t nil)))
        (should (string-match-p "rdev-e2e-" (buffer-string))))
      (with-temp-buffer
        (should (= 7 (process-file "sh" nil t nil "-c" "exit 7"))))
      (should (equal (string-trim (shell-command-to-string "echo ok")) "ok")))))

(ert-deftest e2e-make-process-streaming ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir) (out "") status
           (p (make-process :name "e2e" :connection-type 'pipe :noquery t :file-handler t
                            :command '("sh" "-c" "echo $(hostname); echo one; sleep 0.2; echo two; exit 3")
                            :filter (lambda (_p s) (setq out (concat out s)))
                            :sentinel (lambda (_p e) (setq status e)))))
      (let ((deadline (+ (float-time) 20)))
        ;; Wait for the sentinel itself: the process may be dead before it has run.
        ;; Wait on all processes, as the command loop does; waiting on P alone can leave the
        ;; sentinel of an already-exited process undelivered.
        (while (and (or (process-live-p p) (null status)) (< (float-time) deadline))
          (accept-process-output nil 0.1))
        (accept-process-output nil 0.3))
      (should (string-match-p "one\ntwo" out))
      ;; It really ran on the remote host, not locally.
      (unless (getenv "RDEV_TEST_SSH_CONFIG") ; the local sshd fixture is this very host
        (should-not (string-match-p (regexp-quote (system-name)) out)))
      (unless (string-match-p "code 3" (or status "")) (message "STREAM-DIAG status=%S out=%S live=%S exit=%S" status out (process-live-p p) (process-exit-status p)))
      (should (string-match-p "code 3" (or status ""))))))

(ert-deftest e2e-missing-file-error-class ()
  (e2e-with-dir
    (should-error (insert-file-contents (concat e2e--dir "nope")) :type 'file-missing)))

(provide 'e2e-baseline)
