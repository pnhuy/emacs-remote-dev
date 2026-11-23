;;; rdev-project-test.el --- project.el integration (T089, T093)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'rdev-project)

(defmacro rdev-project-test--with-tree (var &rest body)
  "Run BODY with VAR bound to a remote dir holding a small project."
  (declare (indent 1))
  `(rdev-test-with-twin-dir (_native ,var)
     (let ((l (file-local-name ,var)))
       (make-directory (expand-file-name "p/src" l) t)
       (with-temp-file (expand-file-name "p/pyproject.toml" l) (insert "[x]\n"))
       (with-temp-file (expand-file-name "p/src/a.py" l) (insert "a\n"))
       (with-temp-file (expand-file-name "p/b.txt" l) (insert "b\n")))
     (rdev-project-clear-cache)
     ,@body))

(ert-deftest rdev-project-find-returns-rdev-project-with-remote-root ()
  (rdev-project-test--with-tree d
    (let ((pr (project-current nil (concat d "p/src/"))))
      (should (eq 'rdev (car pr)))
      (should (equal (concat d "p/") (project-root pr))))))

(ert-deftest rdev-project-files-are-absolute-remote-names ()
  (rdev-project-test--with-tree d
    (let* ((pr (project-current nil (concat d "p/src/")))
           (files (project-files pr)))
      (should (equal (sort (copy-sequence files) #'string<)
                     (list (concat d "p/b.txt") (concat d "p/pyproject.toml")
                           (concat d "p/src/a.py"))))
      (should (equal (list (concat d "p/src/a.py"))
                     (project-files pr (list (concat d "p/src/"))))))))

(ert-deftest rdev-project-custom-markers ()
  (rdev-project-test--with-tree d
    (with-temp-file (expand-file-name "p/src/.mine" (file-local-name d)) (insert ""))
    (let ((rdev-project-markers '(".mine")))
      (rdev-project-clear-cache)
      (should (equal (concat d "p/src/")
                     (project-root (project-current nil (concat d "p/src/"))))))))

(ert-deftest rdev-project-ignores-local-directories ()
  (should-not (rdev-project-find "/tmp/")))

(ert-deftest rdev-project-falls-back-without-capability ()
  (rdev-project-test--with-tree d
    (let ((conn (rdev--conn "test")))
      (cl-letf (((symbol-function 'rdev-conn-has-cap)
                 (lambda (_c cap) (and (not (equal cap "project.root"))
                                       (member cap (rdev-conn-caps conn))))))
        (should-not (rdev-project-find (concat d "p/src/")))))))

(ert-deftest rdev-project-root-is-cached-then-cleared-on-reconnect ()
  (rdev-project-test--with-tree d
    (let ((calls 0))
      (cl-letf* ((orig (symbol-function 'rdev--req))
                 ((symbol-function 'rdev--req)
                  (lambda (h m &rest r)
                    (when (eq m :project/root) (cl-incf calls))
                    (apply orig h m r))))
        (rdev-project-find (concat d "p/src/"))
        (rdev-project-find (concat d "p/src/"))
        (should (= 1 calls))
        (run-hook-with-args 'rdev-reconnected-hook "k")
        (rdev-project-find (concat d "p/src/"))
        (should (= 2 calls))))))

(ert-deftest rdev-project-remember-feeds-switch-project-list ()
  (rdev-project-test--with-tree d
    (let ((project-list-file (make-temp-name
                              (expand-file-name "rdev-projects-" temporary-file-directory)))
          (project--list 'unset))
      (unwind-protect
          (progn
            (rdev-project-remember (concat d "p/src/"))
            (should (member (concat d "p/") (project-known-project-roots))))
        (ignore-errors (delete-file project-list-file))))))

(provide 'rdev-project-test)
;;; rdev-project-test.el ends here
