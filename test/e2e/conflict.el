;;; conflict.el --- E2E versioned save over real ssh (T034 companion)  -*- lexical-binding: t; -*-
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

;; baseline.el's own tests are re-registered by the load above; run only ours.
(defun e2e-conflict--external-write (file text)
  (let ((default-directory (file-name-directory file)))
    (should (= 0 (process-file "sh" nil nil nil "-c"
                               (format "sleep 0.05; printf %%s %s > %s"
                                       (shell-quote-argument text)
                                       (shell-quote-argument (file-local-name file))))))))

(ert-deftest e2e-conflict-detected-and-overwrite-flow ()
  (e2e-with-dir
    ;; With a fresh attribute cache (T043) Emacs itself notices the changed mtime and
    ;; would prompt (supersession); answer "continue" so the agent-side version check
    ;; is what refuses (and later allows) the save.
    (cl-letf (((symbol-function 'ask-user-about-supersession-threat) (lambda (_) nil))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (let ((f (concat e2e--dir "c.txt")) (make-backup-files nil) (rdev-conflict-functions nil))
        (write-region "original\n" nil f nil 'silent)
        (with-current-buffer (find-file-noselect f)
          (unwind-protect
              (progn
                (should rdev--version)
                (e2e-conflict--external-write f "changed on the remote")
                (erase-buffer) (insert "my edit\n")
                (should-error (save-buffer) :type 'rdev-conflict)
                (should (buffer-modified-p))
                (should (equal "changed on the remote"
                               (with-temp-buffer (insert-file-contents f) (buffer-string))))
                (let ((rdev-conflict-functions (list (lambda (_) 'overwrite))))
                  (save-buffer))
                (should-not (buffer-modified-p))
                (should (equal "my edit\n" (with-temp-buffer (insert-file-contents f) (buffer-string)))))
            (set-buffer-modified-p nil) (kill-buffer)))))))

(ert-deftest e2e-atomic-save-preserves-mode ()
  (e2e-with-dir
    (let ((f (concat e2e--dir "m.sh")) (make-backup-files nil))
      (write-region "#!/bin/sh\n" nil f nil 'silent)
      (set-file-modes f #o750)
      (with-current-buffer (find-file-noselect f)
        (unwind-protect
            (progn (goto-char (point-max)) (insert "echo hi\n") (save-buffer)
                   (should (= #o750 (file-modes f))))
          (set-buffer-modified-p nil) (kill-buffer))))))
