;;; eglot-python.el --- E2E Eglot with a real pylsp on the remote host (T097, FR-025, SC-011)  -*- lexical-binding: t; -*-
;; Needs `pylsp' on the remote PATH (tests skip with a visible reason otherwise).  Diagnostics
;; and code actions additionally need pyflakes/rope on the remote: set RDEV_TEST_PYLSP_PYTHONPATH
;; to a remote directory that provides them (default /tmp/rdev-pylsp-extra when it exists).
(load (expand-file-name "eglot-common.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'python)

(defun e2e-ep--extra-path ()
  (let ((p (or (getenv "RDEV_TEST_PYLSP_PYTHONPATH") "/tmp/rdev-pylsp-extra")))
    (and (file-directory-p (concat (e2e--root) p)) p)))

(defmacro e2e-ep-with-server (&rest body)
  "Run BODY with `proj', `main', `lib' and `server' bound for a fresh remote Python project."
  (declare (indent 0))
  `(progn
     (unless (e2e-eg--remote-has "pylsp")
       (ert-skip "pylsp is not installed on the remote host"))
     (e2e-with-dir
       (let* ((proj (concat e2e--dir "proj/")) (vc-handled-backends nil)
              (main (concat proj "main.py")) (lib (concat proj "lib.py"))
              (extra (e2e-ep--extra-path))
              (process-environment
               (if extra (cons (concat "PYTHONPATH=" extra) process-environment)
                 process-environment))
              (eglot-workspace-configuration
               '(:pylsp (:plugins (:jedi_completion (:include_params :json-false))))) 
              server)
         (make-directory proj t)
         (write-region "" nil (concat proj ".project") nil 'silent)
         (write-region "def helper(x):\n    return x + 1\n" nil lib nil 'silent)
         (write-region "from lib import helper\n\nvalue = helper(1)\nother = helper(2)\nimport os\nos.pa\n"
                       nil main nil 'silent)
         (rdev-project-clear-cache)
         (unwind-protect
             (progn (setq server (e2e-eg--start main '("pylsp"))) ,@body)
           (e2e-eg--shutdown server)
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p e2e--dir (buffer-file-name b)))
               (with-current-buffer b (set-buffer-modified-p nil))
               (kill-buffer b))))))))

(ert-deftest e2e-eglot-python-server-runs-on-remote ()
  (e2e-ep-with-server
    (should (jsonrpc-running-p server))
    (should (string-prefix-p "/rdev:" (file-name-as-directory (project-root (eglot--project server)))))
    (should (member "completionProvider"
                    (mapcar (lambda (k) (substring (symbol-name k) 1))
                            (cl-loop for (k _) on (eglot--capabilities server) by #'cddr
                                     collect k))))))

(ert-deftest e2e-eglot-python-completion ()
  (e2e-ep-with-server
    (with-current-buffer (get-file-buffer main)
      (goto-char (point-max)) (skip-chars-backward "\n")
      (let* ((capf (eglot-completion-at-point))
             (cands (and capf (all-completions "pa" (nth 2 capf)))))
        (should capf)
        (should (cl-some (lambda (c) (string-prefix-p "path" c)) cands))))))

(ert-deftest e2e-eglot-python-definition ()
  (e2e-ep-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "helper(1)")
      (let* ((defs (xref-backend-definitions (xref-find-backend) "helper"))
             (loc (and defs (xref-item-location (car defs)))))
        (should defs)
        (should (equal lib (xref-location-group loc)))
        (should (= 1 (xref-location-line loc)))))))

(ert-deftest e2e-eglot-python-references ()
  (e2e-ep-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "helper(1)")
      (let ((refs (xref-backend-references (xref-find-backend) "helper")))
        (should (>= (length refs) 3))
        (should (cl-every (lambda (r) (string-prefix-p e2e--dir (xref-location-group (xref-item-location r))))
                          refs))))))

(ert-deftest e2e-eglot-python-rename ()
  (e2e-ep-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "helper(1)")
      (let ((inhibit-message t) (make-backup-files nil) (eglot-confirm-server-edits nil))
        (eglot-rename "assist")
        (save-some-buffers t)
        (let ((txt (lambda (f) (with-temp-buffer (insert-file-contents f) (buffer-string)))))
          (should (string-match-p "from lib import assist" (funcall txt main)))
          (should (string-match-p "def assist" (funcall txt lib)))
          (should-not (string-match-p "helper" (funcall txt main))))))))

(defun e2e-ep--dump-events ()
  (when (getenv "RDEV_TEST_DEBUG")
    (let ((b (jsonrpc-events-buffer (eglot-current-server))))
      (message "EVENTS: %s" (with-current-buffer b (buffer-substring (max (point-min) (- (point-max) 3000)) (point-max)))))))

(ert-deftest e2e-eglot-python-diagnostics ()
  (e2e-ep-with-server
    (unless (e2e-ep--extra-path) (ert-skip "pyflakes is not available to pylsp on the remote host"))
    (with-current-buffer (get-file-buffer main)
      (goto-char (point-max)) (insert "undefined_name_xyz\n")
      (eglot--signal-textDocument/didChange)
      (flymake-mode 1) (flymake-start)
      (let ((ok (e2e-eg--wait (lambda () (cl-some (lambda (d) (string-match-p "undefined_name_xyz" (flymake-diagnostic-text d)))
                                                  (flymake-diagnostics)))
                              30)))
        (unless ok (e2e-ep--dump-events))
        (should ok)))))

(ert-deftest e2e-eglot-python-code-actions-request ()
  "A code-action request round-trips; pylsp ships none without rope plugins, so only the call is asserted."
  (e2e-ep-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "helper(1)")
      (let ((acts (condition-case err (eglot-code-actions (point) (1+ (point)) nil nil)
                    (error (ert-fail (format "code action request failed: %S" err))))))
        (should (listp acts))))))

(ert-deftest e2e-eglot-python-server-kill-and-restart ()
  (e2e-ep-with-server
    (let ((default-directory proj) (inhibit-message t))
      ;; Kill the server process on the remote side.
      (process-file "sh" nil nil nil "-c" "pkill -f '[p]ylsp'")
      (should (e2e-eg--wait (lambda () (not (jsonrpc-running-p server))) 30))
      (with-current-buffer (get-file-buffer main)
        (should (e2e-eg--wait (lambda () (not (eglot-current-server))) 15))
        (setq server (e2e-eg--start main '("pylsp")))
        (should (jsonrpc-running-p server))
        (e2e-eg--goto "helper(1)")
        (should (xref-backend-definitions (xref-find-backend) "helper"))))))
