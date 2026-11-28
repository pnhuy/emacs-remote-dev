;;; rdev-handlers-coverage-test.el --- every handled op is accounted for (T020)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defconst rdev-test--noop-stubs
  '(file-acl set-file-acl file-selinux-context set-file-selinux-context
    lock-file unlock-file file-locked-p)
  "Ops whose rdev handler is a documented no-op (no remote semantics).")

(defconst rdev-test--covered-ops
  '(access-file add-name-to-file copy-file delete-directory delete-file directory-files
    directory-files-and-attributes exec-path expand-file-name file-accessible-directory-p
    file-attributes file-directory-p file-executable-p file-exists-p file-local-copy file-modes
    file-name-all-completions file-name-case-insensitive-p file-name-completion
    file-name-directory
    file-newer-than-file-p file-notify-add-watch file-notify-rm-watch
    file-notify-valid-p file-ownership-preserved-p file-readable-p
    file-regular-p file-remote-p file-symlink-p file-system-info file-truename file-writable-p
    insert-directory insert-file-contents make-directory make-directory-internal make-process
    make-symbolic-link process-file rename-file set-file-modes set-file-times
    set-visited-file-modtime shell-command start-file-process temporary-file-directory
    unhandled-file-name-directory verify-visited-file-modtime write-region)
  "Ops exercised by a test in this suite (see the per-area test files).")

(ert-deftest rdev-coverage-op-table-matches-handlers ()
  (let (registered)
    (maphash (lambda (op _) (push op registered)) rdev--ops)
    (should (= 56 (length registered)))
    (should (= 7 (length rdev-test--noop-stubs)))
    (let ((accounted (append rdev-test--covered-ops rdev-test--noop-stubs)))
      (should-not (cl-set-difference registered accounted))
      (should-not (cl-set-difference accounted registered)))))

(ert-deftest rdev-coverage-noop-stubs-are-inert ()
  (rdev-test-with-twin-dir (native remote)
    (let ((f (concat remote "a.txt")))
      (should-not (file-acl f))
      (should-not (set-file-acl f "x"))
      (should-not (lock-file f))
      (should-not (unlock-file f))
      (should-not (file-locked-p f)))))

(provide 'rdev-handlers-coverage-test)
;;; rdev-handlers-coverage-test.el ends here
