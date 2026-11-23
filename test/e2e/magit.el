;;; magit.el --- E2E Magit on a remote repository (T096, FR-027)  -*- lexical-binding: t; -*-
;; Skips (with a visible reason) when Magit is not installed.  State is verified with
;; independent remote `git' calls, not through Magit.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'package)
(unless (locate-library "magit")
  (ignore-errors (package-initialize)))
(defconst e2e-mg--have (require 'magit nil t))
(unless e2e-mg--have (message "SKIP: magit is not installed; Magit E2E tests are skipped"))

(defun e2e-mg--git (dir &rest args)
  "Run git ARGS in remote DIR independently of Magit; return trimmed stdout."
  (let ((default-directory dir))
    (with-temp-buffer
      (let ((rc (apply #'process-file "git" nil t nil args)))
        (unless (eq rc 0) (error "git %S failed (%s): %s" args rc (buffer-string))))
      (string-trim (buffer-string)))))

(defun e2e-mg--settle ()
  "Wait until Magit has no running git process (some commands finish asynchronously)."
  (let ((deadline (+ (float-time) 15)))
    (while (and (< (float-time) deadline)
                (cl-some (lambda (p) (and (process-live-p p)
                                          (process-buffer p)
                                          (string-prefix-p "magit-process"
                                                           (buffer-name (process-buffer p)))))
                         (process-list)))
      (accept-process-output nil 0.05))))

(defmacro e2e-mg-with-repo (&rest body)
  "Run BODY with `repo' a fresh remote git repository containing one commit."
  (declare (indent 0))
  `(progn
     (skip-unless e2e-mg--have)
     (e2e-with-dir
       (let* ((repo (concat e2e--dir "repo/")) (vc-handled-backends '(Git))
              (magit-refresh-status-buffer nil) (magit-save-repository-buffers nil))
         (make-directory repo t)
         (e2e-mg--git repo "init" "-q" "-b" "main")
         (e2e-mg--git repo "config" "user.name" "E2E")
         (e2e-mg--git repo "config" "user.email" "e2e@example.invalid")
         (write-region "one\n" nil (concat repo "a.txt") nil 'silent)
         (e2e-mg--git repo "add" "a.txt")
         (e2e-mg--git repo "commit" "-q" "-m" "first")
         (unwind-protect (progn ,@body)
           (dolist (b (buffer-list))
             (when (and (buffer-local-value 'default-directory b)
                        (string-prefix-p e2e--dir (buffer-local-value 'default-directory b))
                        (not (buffer-file-name b)))
               (when-let* ((pr (get-buffer-process b)))
                 (set-process-query-on-exit-flag pr nil)
                 (delete-process pr))
               (kill-buffer b))))))))

(ert-deftest e2e-magit-toplevel-and-status ()
  (e2e-mg-with-repo
    (let ((default-directory repo))
      (should (equal (expand-file-name repo) (file-name-as-directory (magit-toplevel))))
      (write-region "two\n" nil (concat repo "a.txt") nil 'silent)
      (write-region "new\n" nil (concat repo "b.txt") nil 'silent)
      (magit-status-setup-buffer repo)
      (with-current-buffer (magit-get-mode-buffer 'magit-status-mode)
        (let ((s (buffer-string)))
          (should (string-match-p "Unstaged changes" s))
          (should (string-match-p "modified +a.txt" s))
          (should (string-match-p "Untracked files" s))
          (should (string-match-p "Untracked files (1)" s))
          (should (string-match-p "main" s)))
        (should (file-remote-p default-directory))))))

(ert-deftest e2e-magit-diff-stage-commit-log ()
  (e2e-mg-with-repo
    (let ((default-directory repo))
      (write-region "one\ntwo\n" nil (concat repo "a.txt") nil 'silent)
      ;; diff
      (should (string-match-p "\\+two" (string-join (magit-git-lines "diff") "\n")))
      ;; stage
      (magit-stage-files (list "a.txt"))
      (should (equal "a.txt" (e2e-mg--git repo "diff" "--cached" "--name-only")))
      (should (equal "" (e2e-mg--git repo "diff" "--name-only")))
      ;; commit
      (magit-call-git "commit" "-m" "second")
      (should (equal "second" (e2e-mg--git repo "log" "-1" "--format=%s")))
      (should (equal "2" (e2e-mg--git repo "rev-list" "--count" "HEAD")))
      ;; log buffer
      (magit-log-setup-buffer (list "HEAD") nil nil)
      (with-current-buffer (magit-get-mode-buffer 'magit-log-mode)
        (should (string-match-p "second" (buffer-string)))
        (should (string-match-p "first" (buffer-string)))))))

(ert-deftest e2e-magit-unstage-and-discard ()
  (e2e-mg-with-repo
    (let ((default-directory repo))
      (write-region "changed\n" nil (concat repo "a.txt") nil 'silent)
      (magit-stage-files (list "a.txt"))
      (magit-unstage-files (list "a.txt"))
      (should (equal "" (e2e-mg--git repo "diff" "--cached" "--name-only")))
      (should (equal "a.txt" (e2e-mg--git repo "diff" "--name-only"))))))

(ert-deftest e2e-magit-branch-create-and-checkout ()
  (e2e-mg-with-repo
    (let ((default-directory repo))
      (magit-branch-create "feature" "HEAD") (e2e-mg--settle)
      (should (member "feature" (split-string (e2e-mg--git repo "branch" "--format=%(refname:short)"))))
      (magit-checkout "feature") (e2e-mg--settle)
      (should (equal "feature" (e2e-mg--git repo "rev-parse" "--abbrev-ref" "HEAD")))
      (should (equal "feature" (magit-get-current-branch)))
      (magit-checkout "main") (e2e-mg--settle)
      (should (equal "main" (e2e-mg--git repo "rev-parse" "--abbrev-ref" "HEAD"))))))
