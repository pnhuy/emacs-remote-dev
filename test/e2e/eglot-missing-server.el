;;; eglot-missing-server.el --- E2E missing language server on the remote host (T128, FR-025 edge case)  -*- lexical-binding: t; -*-
(load (expand-file-name "eglot-common.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'python)

(defconst e2e-ms--missing "rdev-no-such-language-server-xyz")

(ert-deftest e2e-eglot-missing-server-direct-contact-fails-fast-with-diagnostic ()
  "A directly configured, missing server: no hang, and the cause is findable.
Eglot starts remote servers as `sh -c \"stty raw; PROG\"', so the error is
\"Server died\" and the shell's `not found' message lands in the stderr buffer."
  (e2e-with-dir
    (let* ((proj (concat e2e--dir "mproj/")) (main (concat proj "main.py"))
           (vc-handled-backends nil) (t0 (float-time)) err)
      (make-directory proj t)
      (write-region "" nil (concat proj ".project") nil 'silent)
      (write-region "x = 1\n" nil main nil 'silent)
      (rdev-project-clear-cache)
      (should-not (e2e-eg--remote-has e2e-ms--missing))
      (unwind-protect
          (let* ((buf (find-file-noselect main))
                 (eglot-server-programs `((python-mode . (,e2e-ms--missing))))
                 (eglot-sync-connect t) (eglot-connect-timeout 20) (inhibit-message t))
            (with-current-buffer buf
              (setq err (condition-case e
                            (progn (apply (function eglot) (eglot--guess-contact)) nil)
                          (error e)))
              (should-not (eglot-current-server))))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p e2e--dir (buffer-file-name b)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b))))
      (should err)
      (should (< (- (float-time) t0) 20))
      (should (string-match-p "died\\|not found\\|No such" (error-message-string err)))
      ;; The shell's diagnostic naming the program is available to the user.
      (let ((stderr (cl-find-if (lambda (b) (string-match-p "mproj.*stderr" (buffer-name b))) (buffer-list))))
        (should stderr)
        (should (e2e-eg--wait (lambda () (string-match-p (regexp-quote e2e-ms--missing)
                                                          (with-current-buffer stderr (buffer-string))))
                              5)))
      (should (file-exists-p main)))))

(ert-deftest e2e-eglot-missing-server-alternatives-give-actionable-error ()
  "Eglot's own `eglot-alternatives' lookup runs on the remote host and names the candidates."
  (let* ((default-directory (concat (e2e--root) "/tmp/"))
         (contact (eglot-alternatives (list e2e-ms--missing "rdev-also-missing")))
         (err (condition-case e (funcall contact) (error e))))
    (should (consp err))
    (should (string-match-p (regexp-quote e2e-ms--missing) (error-message-string err)))
    (should (string-match-p "valid executables" (error-message-string err)))))

(ert-deftest e2e-eglot-missing-server-executable-find-is-remote ()
  "`executable-find' with REMOTE answers for the remote host, so Eglot's pre-check is meaningful."
  (let ((default-directory (concat (e2e--root) "/tmp/")))
    (should (executable-find "sh" t))
    (should-not (executable-find e2e-ms--missing t))))
