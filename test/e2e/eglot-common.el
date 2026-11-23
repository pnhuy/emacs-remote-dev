;;; eglot-common.el --- shared helpers for the Eglot E2E scenarios  -*- lexical-binding: t; -*-
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'eglot)
(require 'project)
(require 'xref)
(require 'flymake)

;; A server we shut down on purpose must not be restarted by Eglot (reconnect tests rebind this).
(setq eglot-autoreconnect nil)

(defun e2e-eg--remote-has (prog)
  "Non-nil when PROG is on the remote PATH (checked on the agent side)."
  (let ((default-directory (concat (e2e--root) "/tmp/")))
    (eq 0 (process-file "sh" nil nil nil "-c" (format "command -v %s >/dev/null" prog)))))

(defun e2e-eg--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun e2e-eg--start (file contact)
  "Visit remote FILE and start an Eglot server for it using CONTACT; return the server."
  (let* ((buf (find-file-noselect file))
         (eglot-server-programs `((,(buffer-local-value 'major-mode buf) . ,contact))))
    (with-current-buffer buf
      (setq-local eglot-autoshutdown nil)
      (let ((eglot-sync-connect t) (eglot-connect-timeout 60)
            (inhibit-message t))
        (apply (function eglot) (eglot--guess-contact))))
    (with-current-buffer buf
      (e2e-eg--wait (lambda () (eglot-current-server)) 60)
      (should (eglot-current-server))
      (eglot-current-server))))

(defun e2e-eg--shutdown (server)
  (when (and server (jsonrpc-running-p server))
    (ignore-errors (let ((eglot-autoshutdown t)) (eglot-shutdown server nil 15 t)))))

(defun e2e-eg--goto (regexp)
  "Move point to the start of the next match of REGEXP from the beginning."
  (goto-char (point-min))
  (re-search-forward regexp)
  (goto-char (match-beginning 0)))

(defun e2e-eg--wait-value (thunk ok-p &optional secs)
  "Call THUNK until (funcall OK-P value) holds or SECS pass; return the last value."
  (let ((deadline (+ (float-time) (or secs 30))) v)
    (while (and (not (funcall ok-p (setq v (funcall thunk)))) (< (float-time) deadline))
      (accept-process-output nil 0.2))
    v))
