;;; rdev-errors-test.el --- error mapping (T022)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(ert-deftest rdev-err-missing-maps-to-file-missing ()
  (rdev-test-with-twin-dir (native remote)
    (should-error (insert-file-contents (concat remote "nope")) :type 'file-missing)
    (should-error (directory-files (concat remote "nope")) :type 'file-missing)
    (should-error (copy-file (concat remote "nope") (concat remote "x")) :type 'file-missing)))

(ert-deftest rdev-err-exists-maps-to-file-already-exists ()
  (rdev-test-with-twin-dir (native remote)
    (should-error (make-directory (concat remote "sub")) :type 'file-already-exists)))

(ert-deftest rdev-err-permission-maps-to-permission-denied ()
  (skip-unless (not (zerop (user-uid))))
  (rdev-test-with-twin-dir (native remote)
    (set-file-modes (concat (file-local-name remote) "sub") #o000)
    (unwind-protect
        (should-error (directory-files (concat remote "sub")) :type 'permission-denied)
      (set-file-modes (concat (file-local-name remote) "sub") #o755))))

(ert-deftest rdev-err-signal-error-unit ()
  (let ((mk (lambda (errno)
              `(jsonrpc-error (jsonrpc-error-message . "m")
                              (jsonrpc-error-data . (:errno ,errno))))))
    (should-error (rdev--signal-error (funcall mk "ENOENT") "f") :type 'file-missing)
    (should-error (rdev--signal-error (funcall mk "EEXIST") "f") :type 'file-already-exists)
    (should-error (rdev--signal-error (funcall mk "EACCES") "f") :type 'permission-denied)
    (should-error (rdev--signal-error (funcall mk "EPERM") "f") :type 'permission-denied)
    (should-error (rdev--signal-error (funcall mk "EIO") "f") :type 'file-error)
    (should-error (rdev--signal-error (funcall mk nil) "f") :type 'file-error)))

(provide 'rdev-errors-test)
;;; rdev-errors-test.el ends here
