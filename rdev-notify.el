;;; rdev-notify.el --- file-notify support for rdev  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: RDEV contributors
;; Keywords: files, remote
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Bridges the agent's `watch/add' / `watch/event' protocol to Emacs'
;; `file-notify-add-watch' API for /rdev:HOST:/path names, so that
;; `auto-revert-mode', Dired and friends see external changes without polling.
;;
;; A descriptor handed to Emacs is stable across reconnects: the agent-side
;; watch id changes, the descriptor does not.  Events invalidate the cached
;; attributes of the affected path and its parent before the user callback
;; runs (FR-016).  Watches are re-registered through `rdev-reconnected-hook'
;; and dropped (with a `stopped' event) when the connection ends for good.
;; Agents without the `watch' capability signal `file-notify-error', which
;; makes callers such as auto-revert fall back to polling.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'rdev)
(require 'rdev-state)

(cl-defstruct (rdev-notify--watch (:constructor rdev-notify--make))
  "One client-side watch.  DESC is the descriptor Emacs knows."
  desc host dir flags rid gen)

(defvar rdev-notify--watches (make-hash-table :test #'equal)
  "Descriptor -> `rdev-notify--watch'.")

(defvar rdev-notify--counter 0)

(defun rdev-notify--register (w)
  "Ask the agent to watch W's directory and record the agent-side id in W."
  (let* ((conn (rdev--conn (rdev-notify--watch-host w)))
         (res (rdev--req (rdev-notify--watch-host w) :watch/add
                         `(:path ,(rdev-notify--watch-dir w)))))
    (setf (rdev-notify--watch-rid w) (plist-get res :id)
          (rdev-notify--watch-gen w) (rdev-conn-gen conn))
    w))

(rdev-defop file-notify-add-watch (file flags callback)
  (ignore callback)
  (let* ((p (rdev--parse file))
         (host (car p))
         (conn (rdev--conn host)))
    (unless (rdev-conn-has-cap conn "watch")
      (signal 'file-notify-error
              (list "rdev: this agent does not support file watching" file)))
    (let ((w (rdev-notify--make
              :desc (list 'rdev-watch (cl-incf rdev-notify--counter))
              :host host :dir (directory-file-name (cdr p)) :flags flags)))
      (condition-case err
          (rdev-notify--register w)
        (error (signal 'file-notify-error
                       (list "rdev: cannot watch" file (error-message-string err)))))
      (puthash (rdev-notify--watch-desc w) w rdev-notify--watches)
      (rdev-notify--watch-desc w))))

(rdev-defop file-notify-rm-watch (descriptor)
  (when-let* ((w (gethash descriptor rdev-notify--watches)))
    (remhash descriptor rdev-notify--watches)
    (ignore-errors
      (when (and (rdev--conn (rdev-notify--watch-host w) t)
                 (rdev-notify--current-p w))
        (rdev--req (rdev-notify--watch-host w) :watch/remove
                   `(:id ,(rdev-notify--watch-rid w)))))))

(rdev-defop file-notify-valid-p (descriptor)
  (when-let* ((w (gethash descriptor rdev-notify--watches)))
    (rdev-notify--current-p w)))

(defun rdev-notify--current-p (w)
  "Non-nil if W is registered on the host's live connection."
  (when-let* ((c (rdev--conn (rdev-notify--watch-host w) t)))
    (and (rdev-notify--watch-rid w)
         (eql (rdev-notify--watch-gen w) (rdev-conn-gen c)))))

(defun rdev-notify--event (rpc params)
  "Handle a `watch/event' notification (PARAMS) from jsonrpc connection RPC."
  (let* ((hosts (rdev--conn-hosts-of rpc))   ; aliases share one connection
         (rid (plist-get params :id))
         (w (cl-loop for x being the hash-values of rdev-notify--watches
                     for conn = (gethash (rdev-notify--watch-host x) rdev--conns)
                     when (and conn (member (rdev-notify--watch-host x) hosts)
                               (eql (rdev-notify--watch-rid x) rid)
                               (eql (rdev-notify--watch-gen x) (rdev-conn-gen conn)))
                     return x)))
    (when w
      (dolist (ev (append (plist-get params :events) nil))
        (let* ((host (rdev-notify--watch-host w))
               (kind (intern (plist-get ev :kind)))
               (path (plist-get ev :path)))
          ;; Cache first: the callback may stat the file straight away.
          (if (eq kind 'changed)
              (rdev--invalidate host path)
            (rdev--invalidate-tree host path))
          ;; Deliver from a timer, not from the process filter: callbacks
          ;; (auto-revert, Dired) issue synchronous requests, which must not
          ;; nest inside the dispatch of this notification or inside the
          ;; synchronous request that happens to be waiting when it arrives.
          (rdev-notify--deliver (rdev-notify--watch-desc w) kind
                                (rdev-notify--event-name host path)))))))

(defun rdev-notify--event-name (host path)
  "File name for `file-notify-callback' for agent path PATH on HOST.
Emacs 31's filenotify.el prepends the watched directory's remote prefix to
the name a handler reports; Emacs 30 passes the name through unchanged, so
there the handler must supply the full remote name."
  (if (>= emacs-major-version 31) path (concat (rdev--prefix host) path)))

(defun rdev-notify--deliver (desc kind path)
  "Call `file-notify-callback' for DESC/KIND/PATH once it is safe to do so.
Callbacks (auto-revert, Dired) issue synchronous requests, which must not run
from the notification dispatch nor inside a synchronous request that happens
to be waiting when the event arrives (see `rdev--sync-depth'); retry later."
  (run-at-time
   (if (> rdev--sync-depth 0) 0.05 0) nil
   (lambda ()
     (if (> rdev--sync-depth 0)
         (rdev-notify--deliver desc kind path)
       (condition-case err
           ;; filenotify.el prepends the remote prefix itself, so pass the
           ;; agent's local name.
           (file-notify-callback (list desc (list kind) path))
         (error (message "rdev: file-notify callback failed: %s"
                         (error-message-string err))))))))

(setq rdev-watch-event-function #'rdev-notify--event)

;;;; Reconnect and disconnect

(defun rdev-notify--reregister (key)
  "Re-register every watch of session KEY after a reconnect."
  (maphash
   (lambda (_d w)
     (when (equal (rdev-state-session-key (rdev-notify--watch-host w)) key)
       (condition-case nil
           (progn (rdev--invalidate-tree (rdev-notify--watch-host w)
                                         (rdev-notify--watch-dir w))
                  (rdev-notify--register w))
         (error (rdev-notify--drop w)))))
   rdev-notify--watches))

(defun rdev-notify--drop (w)
  "Forget W and tell Emacs it was stopped."
  (remhash (rdev-notify--watch-desc w) rdev-notify--watches)
  (ignore-errors
    (file-notify-callback
     (list (rdev-notify--watch-desc w) '(stopped)
           (rdev-notify--watch-dir w)))))

(defun rdev-notify--state-change (key _old new)
  "Drop all watches of session KEY when NEW is disconnected or failed."
  (when (memq new '(disconnected failed))
    (let (doomed)
      (maphash (lambda (_d w)
                 (when (equal (rdev-state-session-key (rdev-notify--watch-host w)) key)
                   (push w doomed)))
               rdev-notify--watches)
      (mapc #'rdev-notify--drop doomed))))

(add-hook 'rdev-reconnected-hook #'rdev-notify--reregister)
(add-hook 'rdev-connection-state-hook #'rdev-notify--state-change)

(require 'autorevert)
(defconst rdev-notify--remote-exclude "\\|^/[^/:|][^/|]+:"
  "Tail of the default `auto-revert-notify-exclude-dir-regexp'.
It is the clause that skips remote names.")

;;;###autoload
(defun rdev-notify-enable-auto-revert ()
  "Let `auto-revert-mode' use RDEV's native file watching on remote buffers.
Emacs excludes every remote file name from notification-based reverting by
default.  This opt-in command sets `auto-revert-remote-files' and removes
that exclusion from
`auto-revert-notify-exclude-dir-regexp' (it affects other remote methods
too, such as TRAMP, which then use their own notification support)."
  (interactive)
  (setq auto-revert-remote-files t)
  (when (stringp auto-revert-notify-exclude-dir-regexp)
    (let ((i (string-search rdev-notify--remote-exclude auto-revert-notify-exclude-dir-regexp)))
      (when i
        (setq auto-revert-notify-exclude-dir-regexp
              (concat (substring auto-revert-notify-exclude-dir-regexp 0 i)
                      (substring auto-revert-notify-exclude-dir-regexp
                                 (+ i (length rdev-notify--remote-exclude)))))))))

(provide 'rdev-notify)
;;; rdev-notify.el ends here
