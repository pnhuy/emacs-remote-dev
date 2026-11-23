;;; eglot-reconnect.el --- E2E Eglot server vs rdev reconnect (T100, FR-025, SC-011)  -*- lexical-binding: t; -*-
;; The local ssh is killed while a real pylsp runs on the remote host.  The language-server
;; process dies with the connection (it is never replayed, Art. III), the buffer keeps its
;; unsaved edits, and a fresh server can be started on the reconnected session.
(load (expand-file-name "eglot-common.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'python)

(defun e2e-er--kill-ssh ()
  (let* ((c (rdev--conn e2e-host)) (proc (jsonrpc--process (rdev-conn-rpc c))))
    (should (process-live-p proc))
    (signal-process (process-id proc) 'KILL)))

(defun e2e-er--wait-reconnected (gen timeout)
  (e2e-eg--wait (lambda () (let ((c (gethash e2e-host rdev--conns)))
                             (and c (eq 'connected (rdev-state (rdev-state-session-key e2e-host)))
                                  (> (or (rdev-conn-gen c) 0) gen))))
                timeout))

(ert-deftest e2e-eglot-reconnect-server-restart-after-ssh-kill ()
  (unless (e2e-eg--remote-has "pylsp") (ert-skip "pylsp is not installed on the remote host"))
  (e2e-with-dir
    (let* ((proj (concat e2e--dir "rproj/")) (vc-handled-backends nil)
           (main (concat proj "main.py")) (lib (concat proj "lib.py"))
           (rdev-reconnect-base 0.5) (make-backup-files nil) server server2)
      (make-directory proj t)
      (write-region "" nil (concat proj ".project") nil 'silent)
      (write-region "def helper(x):\n    return x + 1\n" nil lib nil 'silent)
      (write-region "from lib import helper\n\nvalue = helper(1)\n" nil main nil 'silent)
      (rdev-project-clear-cache)
      (unwind-protect
          (progn
            (setq server (e2e-eg--start main '("pylsp")))
            (should (jsonrpc-running-p server))
            (with-current-buffer (get-file-buffer main)
              (goto-char (point-max)) (insert "# unsaved edit\n"))
            (let ((gen (rdev-conn-gen (rdev--conn e2e-host))))
              (e2e-er--kill-ssh)
              (should (e2e-er--wait-reconnected gen 40)))
            ;; The language server died with the old session and was not replayed.
            (should (e2e-eg--wait (lambda () (not (jsonrpc-running-p server))) 20))
            (with-current-buffer (get-file-buffer main)
              ;; Local editing state survived (Art. III / X).
              (should (buffer-modified-p))
              (should (string-suffix-p "# unsaved edit\n" (buffer-string)))
              (should (e2e-eg--wait (lambda () (not (eglot-current-server))) 20))
              ;; A new server starts on the reconnected session and answers requests.
              (setq server2 (e2e-eg--start main '("pylsp")))
              (should (jsonrpc-running-p server2))
              (should-not (eq server server2))
              (e2e-eg--goto "helper(1)")
              (let ((defs (xref-backend-definitions (xref-find-backend) "helper")))
                (should defs)
                (should (equal lib (xref-location-group (xref-item-location (car defs)))))))
            ;; Saving still works and writes the unsaved edit.
            (with-current-buffer (get-file-buffer main) (save-buffer))
            (should (string-suffix-p "# unsaved edit\n"
                                     (with-temp-buffer (insert-file-contents main) (buffer-string)))))
        (e2e-eg--shutdown server2)
        (e2e-eg--shutdown server)
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p e2e--dir (buffer-file-name b)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))))))
