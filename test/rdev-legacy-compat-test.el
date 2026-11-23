;;; rdev-legacy-compat-test.el --- current client vs pinned legacy agent (T029)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defconst rdev-test--legacy-server
  (expand-file-name "fixtures/legacy-server.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest rdev-legacy-fixture-is-pinned ()
  (let* ((dir (file-name-directory rdev-test--legacy-server))
         (want (with-temp-buffer
                 (insert-file-contents (expand-file-name "legacy-server.sha256" dir))
                 (car (split-string (buffer-string)))))
         (got (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally rdev-test--legacy-server)
                (secure-hash 'sha256 (current-buffer)))))
    (should (equal want got))))

(defmacro rdev-test-with-legacy (&rest body)
  (declare (indent 0))
  `(let ((rdev-test-server-file rdev-test--legacy-server))
     (rdev-test-with-twin-dir (native remote) ,@body)))

(ert-deftest rdev-legacy-hello-without-params ()
  (rdev-test-with-legacy
    (let ((r (jsonrpc-request (rdev-conn-rpc (rdev--conn "test")) :hello nil :timeout 10)))
      (should (plist-get r :home)))))

(ert-deftest rdev-legacy-read-write-roundtrip ()
  (rdev-test-with-legacy
    (should (equal (with-temp-buffer (insert-file-contents (concat remote "a.txt")) (buffer-string))
                   "alpha\nbeta\n"))
    (write-region "new" nil (concat remote "w.txt") nil 'silent)
    (should (equal (with-temp-buffer (insert-file-contents (concat remote "w.txt")) (buffer-string))
                   "new"))))

(ert-deftest rdev-legacy-directory-and-attrs ()
  (rdev-test-with-legacy
    (should (member "a.txt" (directory-files remote)))
    (should (file-directory-p (concat remote "sub")))
    (should (= 11 (file-attribute-size (file-attributes (concat remote "a.txt")))))))

(ert-deftest rdev-legacy-process-file ()
  (rdev-test-with-legacy
    (let ((default-directory remote))
      (with-temp-buffer
        (should (= 0 (process-file "echo" nil t nil "legacy")))
        (should (equal (buffer-string) "legacy\n"))))))

(provide 'rdev-legacy-compat-test)
;;; rdev-legacy-compat-test.el ends here
