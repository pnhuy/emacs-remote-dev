;;; workflow.el --- E2E "remote project feels ordinary" workflow (T095, SC-010)  -*- lexical-binding: t; -*-
;; connect -> project.el -> find file -> search -> edit -> save -> compile ->
;; next-error, using only stock Emacs commands.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'project)
(require 'compile)
(require 'rdev-search)

(defvar e2e-wf--hook-hits nil)

(defmacro e2e-wf-with-project (&rest body)
  "Run BODY with `proj' bound to a fresh remote project directory."
  (declare (indent 0))
  `(e2e-with-dir
     (let ((proj (concat e2e--dir "proj/")) (vc-handled-backends nil))
       (make-directory (concat proj "src") t)
       (write-region "" nil (concat proj ".project") nil 'silent)
       (write-region "print('hello')\nfoo = 1\n" nil (concat proj "src/main.py") nil 'silent)
       (write-region "plain notes\nneedle here\n" nil (concat proj "notes.txt") nil 'silent)
       (write-region "(setq x 1)\n" nil (concat proj "src/conf.el") nil 'silent)
       (rdev-project-clear-cache)
       ,@body)))

(ert-deftest e2e-workflow-project-and-find-file ()
  (e2e-wf-with-project
    (let* ((default-directory (concat proj "src/"))
           (pr (project-current)))
      (should pr)
      (should (equal (expand-file-name proj) (expand-file-name (project-root pr))))
      (let ((files (project-files pr)))
        (should (member (concat proj "src/main.py") files))
        (should (member (concat proj "notes.txt") files)))
      ;; Same project from a file buffer and after a reconnect cache reset.
      (with-current-buffer (find-file-noselect (concat proj "src/main.py"))
        (unwind-protect
            (should (equal (expand-file-name proj)
                           (expand-file-name (project-root (project-current)))))
          (kill-buffer))))))

(ert-deftest e2e-workflow-major-mode-and-hooks-run ()
  (e2e-wf-with-project
    (let ((e2e-wf--hook-hits nil)
          (th (lambda () (push 'text e2e-wf--hook-hits)))
          (eh (lambda () (push 'elisp e2e-wf--hook-hits)))
          (ffh (lambda () (push 'find-file e2e-wf--hook-hits))))
      (add-hook 'text-mode-hook th)
      (add-hook 'emacs-lisp-mode-hook eh)
      (add-hook 'find-file-hook ffh)
      (unwind-protect
          (progn
            (with-current-buffer (find-file-noselect (concat proj "notes.txt"))
              (should (derived-mode-p 'text-mode))
              (kill-buffer))
            (with-current-buffer (find-file-noselect (concat proj "src/conf.el"))
              (should (derived-mode-p 'emacs-lisp-mode))
              (should (file-remote-p default-directory))
              (kill-buffer))
            (should (memq 'text e2e-wf--hook-hits))
            (should (memq 'elisp e2e-wf--hook-hits))
            (should (= 2 (cl-count 'find-file e2e-wf--hook-hits))))
        (remove-hook 'text-mode-hook th)
        (remove-hook 'emacs-lisp-mode-hook eh)
        (remove-hook 'find-file-hook ffh)))))

(ert-deftest e2e-workflow-search-edit-save ()
  (e2e-wf-with-project
    (let* ((res (rdev-search proj "needle"))
           (m (car (plist-get res :matches))))
      (should (= 1 (plist-get res :count)))
      (should (equal "notes.txt" (plist-get m :path)))
      (should (= 2 (plist-get m :line)))
      (with-current-buffer (find-file-noselect (concat proj (plist-get m :path)))
        (goto-char (point-min)) (forward-line (1- (plist-get m :line)))
        (should (looking-at "needle"))
        (let ((make-backup-files nil))
          (replace-match "pin") (save-buffer))
        (should-not (buffer-modified-p))
        (kill-buffer))
      (should (equal "plain notes\npin here\n"
                     (with-temp-buffer (insert-file-contents (concat proj "notes.txt"))
                                       (buffer-string))))
      (should (= 0 (plist-get (rdev-search proj "needle") :count))))))

(ert-deftest e2e-workflow-compile-and-jump-to-error ()
  (e2e-wf-with-project
    (write-region "ok\nbroken\n" nil (concat proj "src/lines.txt") nil 'silent)
    (let* ((default-directory proj)
           (compilation-ask-about-save nil)
           (buf (compile "echo \"src/lines.txt:2:3: error: bad\"; exit 1")))
      (let ((deadline (+ (float-time) 30)))
        (while (and (get-buffer-process buf) (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (with-current-buffer buf
        (should (string-match-p "src/lines.txt:2:3" (buffer-string)))
        (should (string-match-p "exited abnormally with code 1" (buffer-string))))
      (with-current-buffer buf
        (goto-char (point-min))
        (let ((next-error-last-buffer buf))
          (save-window-excursion (next-error))))
      (let ((b (get-file-buffer (concat proj "src/lines.txt"))))
        (should b)
        (with-current-buffer b
          (should (= 2 (line-number-at-pos))))
        (kill-buffer b))
      (kill-buffer buf))))
