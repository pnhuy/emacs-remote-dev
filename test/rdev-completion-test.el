;;; rdev-completion-test.el --- Completion round trips (T094, FR-024)  -*- lexical-binding: t; -*-
(require 'ert)
(require 'rdev-test-helpers)

(defvar rdev-test--req-count 0)

(defmacro rdev-test--counting-requests (&rest body)
  "Run BODY and return the number of RPC requests it sent."
  `(let ((rdev-test--req-count 0)
         (adv (lambda (orig &rest args) (cl-incf rdev-test--req-count) (apply orig args))))
     (advice-add 'rdev--req :around adv)
     (unwind-protect (progn ,@body rdev-test--req-count)
       (advice-remove 'rdev--req adv))))

(defun rdev-test--make-big (dir)
  (make-directory dir t)
  (dotimes (i 1000) (write-region "" nil (format "%sfile%d.txt" dir i) nil 'silent))
  (make-directory (concat dir "fsub") t))

(ert-deftest rdev-completion-1000-entries-two-round-trips-at-most ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-test--make-big (concat native "big/"))
    (let ((big (concat remote "big/")) res)
      (rdev-test--make-big (file-local-name big)) ; the agent-side twin
      (rdev--invalidate-tree "test" (file-local-name big))
      (let ((n (rdev-test--counting-requests
                (setq res (file-name-all-completions "file1" big)))))
        (should (<= n 2))
        (should (equal (sort (copy-sequence res) #'string<)
                       (sort (file-name-all-completions "file1" (concat native "big/"))
                             #'string<))))
      ;; Typing another character costs nothing: the listing is cached.
      (should (= 0 (rdev-test--counting-requests
                    (file-name-all-completions "file12" big))))
      ;; A predicate (read-file-name directories-only) adds no round trip.
      (rdev--invalidate-tree "test" (file-local-name big))
      (should (<= (rdev-test--counting-requests
                   (file-name-completion "f" big #'file-directory-p))
                  2)))))

(ert-deftest rdev-completion-sees-new-file-after-create ()
  "The completion listing cache must not hide a file created through rdev."
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (should-not (member "newone" (file-name-all-completions "new" remote)))
      (write-region "x" nil (concat remote "newone") nil 'silent)
      (should (member "newone" (file-name-all-completions "new" remote)))
      (delete-file (concat remote "newone"))
      (should-not (member "newone" (file-name-all-completions "new" remote))))))

(ert-deftest rdev-completion-missing-or-file-dir-is-nil ()
  (rdev-test-with-twin-dir (native remote)
    (write-region "x" nil (concat remote "plain") nil 'silent)
    (should-not (file-name-all-completions "" (concat remote "nope/")))
    (should-not (file-name-all-completions "" (concat remote "plain/")))))

(provide 'rdev-completion-test)
