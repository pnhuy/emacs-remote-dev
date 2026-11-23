;;; rdev-tramp-test.el --- TRAMP coexistence (T027)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'tramp)

(ert-deftest rdev-tramp-handler-registered-first-for-rdev-names ()
  (let ((h (find-file-name-handler "/rdev:somehost:/etc/hostname" 'file-exists-p)))
    (should (eq h 'rdev-file-name-handler))))

(ert-deftest rdev-tramp-ignores-rdev-prefix ()
  (should (string-match-p tramp-ignored-file-name-regexp "/rdev:h:/x"))
  (should-not (tramp-tramp-file-p "/rdev:h:/x")))

(ert-deftest rdev-tramp-names-not-claimed-by-rdev ()
  (dolist (f '("/ssh:host:/etc/passwd" "/scp:host:/tmp/x" "/sudo::/etc/hosts" "/tmp/plain"))
    (should-not (eq (find-file-name-handler f 'file-exists-p) 'rdev-file-name-handler))))

(ert-deftest rdev-tramp-local-ops-unaffected ()
  (let ((f (make-temp-file "rdev-local")))
    (unwind-protect
        (progn (write-region "x" nil f nil 'silent)
               (should (file-exists-p f))
               (should-not (file-remote-p f)))
      (delete-file f))))

(ert-deftest rdev-tramp-file-remote-p-distinguishes ()
  (should (equal (file-remote-p "/rdev:h:/x") "/rdev:h:"))
  (should (file-remote-p "/ssh:h:/x")))

;; Art. II: the user's own value of the TRAMP ignore regexp must survive.
(ert-deftest rdev-tramp-ignore-preserves-user-regexp ()
  (let ((tramp-ignored-file-name-regexp "\\`/foo:"))
    (rdev--tramp-ignore-rdev)
    (should (string-match-p tramp-ignored-file-name-regexp "/foo:x:/y"))
    (should (string-match-p tramp-ignored-file-name-regexp "/rdev:h:/x"))
    (should-not (string-match-p tramp-ignored-file-name-regexp "/ssh:h:/x"))))

(ert-deftest rdev-tramp-ignore-is-idempotent-and-fills-nil ()
  (let ((tramp-ignored-file-name-regexp nil))
    (rdev--tramp-ignore-rdev)
    (should (string-match-p tramp-ignored-file-name-regexp "/rdev:h:/x"))
    (let ((once tramp-ignored-file-name-regexp))
      (rdev--tramp-ignore-rdev)
      (should (equal once tramp-ignored-file-name-regexp)))))

(provide 'rdev-tramp-test)
;;; rdev-tramp-test.el ends here
