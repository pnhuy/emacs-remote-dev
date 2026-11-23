;;; rdev-error-classes-test.el --- distinct error classes (T131, FR-040)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defun rdev-ec--jsonrpc-err (code msg &optional errno)
  `(jsonrpc-error (jsonrpc-error-code . ,code) (jsonrpc-error-message . ,msg)
                  (jsonrpc-error-data . ,(when errno `(:errno ,errno)))))

(defun rdev-ec--signal-class (code &optional errno)
  (condition-case e (rdev--signal-error (rdev-ec--jsonrpc-err code "boom" errno) "/rdev:h:/f")
    (error (car e))))

(ert-deftest rdev-ec-all-classes-are-file-errors-and-distinct ()
  (let ((syms '(rdev-conflict rdev-connection-lost rdev-ssh-error rdev-transport-error
                rdev-agent-error rdev-filesystem-error rdev-process-error)))
    (dolist (s syms)
      (should (memq 'file-error (get s 'error-conditions)))
      (should (stringp (get s 'error-message))))
    (should (= (length syms) (length (delete-dups (mapcar (lambda (s) (get s 'error-message)) syms)))))))

(ert-deftest rdev-ec-protocol-codes-map-to-classes ()
  (should (eq 'rdev-conflict (rdev-ec--signal-class -32010)))
  (should (eq 'rdev-filesystem-error (rdev-ec--signal-class -32011)))
  (should (eq 'rdev-agent-error (rdev-ec--signal-class -32012)))
  (should (eq 'rdev-transport-error (rdev-ec--signal-class -32013)))
  (should (eq 'rdev-process-error (rdev-ec--signal-class -32800))))

(ert-deftest rdev-ec-errno-maps-to-standard-file-errors ()
  (should (eq 'file-missing (rdev-ec--signal-class -32003 "ENOENT")))
  (should (eq 'file-already-exists (rdev-ec--signal-class -32003 "EEXIST")))
  (should (eq 'permission-denied (rdev-ec--signal-class -32003 "EACCES")))
  (should (eq 'file-error (rdev-ec--signal-class -32003 "EIO"))))

(ert-deftest rdev-ec-ssh-failure-signals-ssh-error ()
  "A failing ssh (exit 255, no agent) signals `rdev-ssh-error', not a generic error."
  (let* ((dir (make-temp-file "rdev-ec-ssh" t))
         (ssh (expand-file-name "ssh" dir)))
    (unwind-protect
        (progn
          (with-temp-file ssh (insert "#!/bin/sh\necho 'ssh: Could not resolve hostname' >&2\nexit 255\n"))
          (set-file-modes ssh #o755)
          (let ((exec-path (cons dir exec-path))
                (process-environment (cons (concat "PATH=" dir ":" (getenv "PATH")) process-environment))
                (rdev-hosts nil) (rdev-timeout 5))
            (should-error (rdev--connect "nohost") :type 'rdev-ssh-error)))
      (delete-directory dir t))))

(ert-deftest rdev-ec-agent-error-class-for-unsupported ()
  "An agent -32012 (UNSUPPORTED) reply becomes `rdev-agent-error'.
The reply is injected: search/grep is now implemented, and no other real
request yields -32012 deterministically on every host (rg may or may not
be installed)."
  (rdev-test--connect)
  (unwind-protect
      (cl-letf (((symbol-function 'jsonrpc-request)
                 (lambda (&rest _)
                   (signal 'jsonrpc-error
                           '("request failed" (jsonrpc-error-code . -32012)
                             (jsonrpc-error-message . "unsupported"))))))
        (should-error (rdev--req "test" :fs/stat '(:path "/tmp") "/rdev:test:/tmp")
                      :type 'rdev-agent-error))
    (rdev-test--disconnect)))

(ert-deftest rdev-ec-filesystem-error-from-real-agent ()
  (rdev-test-with-twin-dir (native remote)
    (should-error (insert-file-contents (concat remote "does-not-exist")) :type 'file-missing)
    (should-error (rdev--req "test" :fs/read `(:path ,(concat (file-local-name remote) "a.txt") :limit -1) remote)
                  :type 'file-error)))

(ert-deftest rdev-ec-conflict-class-from-real-save ()
  (rdev-test-with-twin-dir (native remote)
    (let ((rdev-conflict-functions nil) (make-backup-files nil))
      (with-current-buffer (find-file-noselect (concat remote "a.txt"))
        (unwind-protect
            (progn (sleep-for 0.02)
                   (with-temp-file (concat (file-local-name remote) "a.txt") (insert "changed elsewhere"))
                   (erase-buffer) (insert "mine")
                   (should-error (save-buffer) :type 'rdev-conflict))
          (set-buffer-modified-p nil) (kill-buffer))))))

(ert-deftest rdev-ec-process-error-for-cancelled ()
  (should (eq 'rdev-process-error (rdev-ec--signal-class -32800))))

(provide 'rdev-error-classes-test)
