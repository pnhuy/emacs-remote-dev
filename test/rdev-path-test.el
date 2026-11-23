;;; rdev-path-test.el --- path parsing and handler dispatch (T015)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(ert-deftest rdev-path-parse ()
  (should (equal (rdev--parse "/rdev:host:/a/b") '("host" . "/a/b")))
  (should (equal (rdev--parse "/rdev:h:") '("h" . "")))
  (should (equal (rdev--parse "/rdev:h:~/x") '("h" . "~/x")))
  (should (equal (rdev--parse "/rdev:h:/a:b") '("h" . "/a:b")))
  (should (equal (rdev--parse "/rdev:h:/a\nb") '("h" . "/a\nb")))
  (should-not (rdev--parse "/ssh:h:/a"))
  (should-not (rdev--parse "/rdev::/a"))
  (should-not (rdev--parse "/rdev:a/b:/c"))
  (should-not (rdev--parse nil)))

(ert-deftest rdev-path-prefix ()
  (should (equal (rdev--prefix "h") "/rdev:h:")))

(ert-deftest rdev-path-file-remote-p ()
  (should (equal (file-remote-p "/rdev:h:/x") "/rdev:h:"))
  (should (equal (file-remote-p "/rdev:h:/x" 'method) "rdev"))
  (should (equal (file-remote-p "/rdev:h:/x" 'host) "h"))
  (should (equal (file-remote-p "/rdev:h:/x" 'localname) "/x"))
  (should-not (file-remote-p "/rdev:h:/x" nil t))   ; not connected
  (should-not (file-remote-p "/tmp/x")))

(ert-deftest rdev-path-expand-and-localname ()
  (rdev-test-with-server
    (let ((home (rdev--home "test")))
      (should (equal (expand-file-name "/rdev:test:/a/../b/./c") "/rdev:test:/b/c"))
      (should (equal (expand-file-name "x" "/rdev:test:/a") "/rdev:test:/a/x"))
      (should (equal (expand-file-name "/rdev:test:~/x") (concat "/rdev:test:" home "/x")))
      (should (equal (file-local-name "/rdev:test:/a/b") "/a/b"))
      (should (equal (file-name-directory "/rdev:test:/a/b") "/rdev:test:/a/"))
      (should (equal (file-name-nondirectory "/rdev:test:/a/b") "b")))))

(ert-deftest rdev-path-handler-dispatch-fallthrough ()
  "Unhandled operations fall through to the native implementation."
  (should (equal (file-name-as-directory "/rdev:h:/a") "/rdev:h:/a/"))
  (should (equal (directory-file-name "/rdev:h:/a/") "/rdev:h:/a"))
  (should (file-name-absolute-p "/rdev:h:/a"))
  (should-not (file-name-absolute-p "rdev:h:/a"))
  (should (eq (find-file-name-handler "/rdev:h:/a" 'file-exists-p) 'rdev-file-name-handler))
  (should-not (eq (find-file-name-handler "/tmp/a" 'file-exists-p) 'rdev-file-name-handler)))

(provide 'rdev-path-test)
;;; rdev-path-test.el ends here
