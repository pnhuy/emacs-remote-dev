;;; rdev-state.el --- Connection state machine, reconnect and logs for RDEV  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Huy Pham

;;; Commentary:

;; Transport-independent connection bookkeeping.  This file MUST NOT
;; `require' rdev: it exposes variables, hooks and callbacks that rdev.el
;; fills in (enforced by test/rdev-load-order-test.el).
;;
;; * One state per logical session key (`rdev-state-session-key'): two ssh
;;   aliases that resolve to the same user/host/port share one connection.
;; * All state changes go through `rdev-state-transition', which validates
;;   against `rdev-state--transitions', logs, and runs
;;   `rdev-connection-state-hook' with (KEY OLD NEW).
;; * `rdev-state-schedule-reconnect' retries with bounded exponential backoff
;;   plus jitter.  It never replays requests: callers learn about the loss
;;   through `rdev-state-lost-functions' and decide per operation.
;; * `*rdev-log HOST*' collects transitions and agent stderr, redacted.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup rdev-state nil "RDEV connection state and reconnect." :group 'rdev)

(defcustom rdev-reconnect t
  "When non-nil, reconnect automatically after an unexpected connection loss."
  :type 'boolean :group 'rdev-state)
(defcustom rdev-reconnect-base 1.0
  "Seconds before the first reconnect attempt; doubles on each failure."
  :type 'number :group 'rdev-state)
(defcustom rdev-reconnect-cap 10.0
  "Upper bound in seconds on the delay between reconnect attempts."
  :type 'number :group 'rdev-state)
(defcustom rdev-reconnect-max-attempts 30
  "Reconnect attempts before the connection is declared FAILED."
  :type 'integer :group 'rdev-state)
(defcustom rdev-reconnect-jitter 0.2
  "Fraction (0-1) of random +/- jitter applied to each backoff delay."
  :type 'number :group 'rdev-state)
(defcustom rdev-log-max-lines 2000
  "Maximum number of lines kept in each `*rdev-log HOST*' buffer."
  :type 'integer :group 'rdev-state)

(defvar rdev-connection-state-hook nil
  "Abnormal hook run after each state change with (KEY OLD NEW).")
(defvar rdev-reconnected-hook nil
  "Hook run once after a successful automatic reconnect.
Called with one argument, the session KEY.  Consumers (watchers, project
context) re-register themselves here.")
(defvar rdev-state-lost-functions nil
  "Abnormal hook run with (KEY) when a live connection is lost unexpectedly.
rdev.el uses it to fail pending requests and mark owned processes.")
(defvar rdev-state-connect-function nil
  "Function (KEY) that makes one connection attempt; signals on failure.")

(defconst rdev-state--states
  '(disconnected connecting bootstrapping initializing connected degraded
    reconnecting failed disconnecting))

(defconst rdev-state--transitions
  '((disconnected connecting)
    (connecting bootstrapping initializing failed)
    (bootstrapping initializing failed)
    (initializing connected failed)
    (connected degraded reconnecting)
    (degraded connected reconnecting)
    (reconnecting initializing failed)
    (failed connecting))
  "Allowed (FROM TO...) edges.
The state `disconnecting' is reachable from any state except
`disconnected' and leads only to `disconnected'.")

(defvar rdev-state--table (make-hash-table :test #'equal) "KEY -> state symbol.")
(defvar rdev-state--timers (make-hash-table :test #'equal) "KEY -> reconnect timer.")
(defvar rdev-state--attempts (make-hash-table :test #'equal) "KEY -> attempt count.")
(defvar rdev-state--strict nil
  "When non-nil (tests) an illegal transition signals instead of being ignored.")

(defun rdev-state (key)
  "Current state of session KEY (`disconnected' when unknown)."
  (gethash key rdev-state--table 'disconnected))

(defun rdev-state--legal-p (old new)
  (cond ((eq new 'disconnecting) (not (eq old 'disconnected)))
        ((eq old 'disconnecting) (eq new 'disconnected))
        (t (memq new (cdr (assq old rdev-state--transitions))))))

(defun rdev-state-transition (key new &optional reason)
  "Move session KEY to state NEW (optional REASON is logged).
Return t, or nil if the move is illegal.
An illegal move is logged and ignored (signals `error' if
`rdev-state--strict')."
  (let ((old (rdev-state key)))
    (cond
     ((eq old new) nil)
     ((not (memq new rdev-state--states)) (error "Unknown rdev state %S" new))
     ((rdev-state--legal-p old new)
      (puthash key new rdev-state--table)
      (rdev-state-log key "state %s -> %s%s" old new
                      (if reason (format " (%s)" reason) ""))
      (run-hook-with-args 'rdev-connection-state-hook key old new)
      t)
     (t (rdev-state-log key "ignored illegal transition %s -> %s" old new)
        (when rdev-state--strict
          (error "Illegal rdev transition %s -> %s for %s" old new key))
        nil))))

;;;; Session key

(defvar rdev-state-ssh-g-function #'rdev-state--ssh-g
  "Function (HOST) returning ssh -G output as a string, or nil.")
(defvar rdev-state--keys (make-hash-table :test #'equal))

(defun rdev-state--ssh-g (host)
  "Return `ssh -G' output for HOST, honoring a \"-F FILE\" in `rdev-ssh-args'."
  (let* ((args (and (boundp 'rdev-ssh-args) (symbol-value 'rdev-ssh-args)))
         (cfg (cadr (member "-F" args))))
    (with-temp-buffer
      (when (eq 0 (ignore-errors
                    (apply #'call-process "ssh" nil '(t nil) nil
                           (append (and cfg (list "-F" cfg))
                                   (list "-G" "--" host)))))
        (buffer-string)))))

(defun rdev-state-session-key (host)
  "Canonical \"user@hostname:port\" for ssh alias HOST (FR-008).
Falls back to HOST itself when `ssh -G' is unavailable."
  (or (gethash host rdev-state--keys)
      (let* ((out (ignore-errors (funcall rdev-state-ssh-g-function host)))
             (field (lambda (k)
                      (and out (string-match
                                (format "^%s \\(.+\\)$" k) out)
                           (match-string 1 out))))
             (key (let ((h (funcall field "hostname"))
                        (u (funcall field "user"))
                        (p (funcall field "port")))
                    (if (and h u p) (format "%s@%s:%s" u h p) host))))
        (puthash host key rdev-state--keys)
        key)))

(defun rdev-state-forget-keys ()
  "Drop cached ssh -G results (after editing ~/.ssh/config)."
  (interactive)
  (clrhash rdev-state--keys))

;;;; Single in-flight attempt

(defun rdev-state-attempt-in-flight-p (key)
  "Non-nil if a connection attempt for session KEY is currently running."
  (memq (rdev-state key) '(connecting bootstrapping initializing reconnecting)))

;;;; Backoff

(defun rdev-state-backoff-delay (attempt)
  "Seconds to wait before reconnect ATTEMPT (1-based), with jitter."
  (let* ((raw (min rdev-reconnect-cap
                   (* rdev-reconnect-base (expt 2 (max 0 (1- attempt))))))
         (j (* raw rdev-reconnect-jitter (- (* 2 (/ (random 10001) 10000.0)) 1))))
    (max 0.0 (+ raw j))))

(defun rdev-state-schedule-reconnect (key)
  "Start (or continue) the reconnect cycle for KEY."
  (let ((n (1+ (gethash key rdev-state--attempts 0))))
    (cond
     ((> n rdev-reconnect-max-attempts)
      (rdev-state-log key "giving up after %d attempts" (1- n))
      (remhash key rdev-state--attempts)
      (rdev-state-transition key 'failed "attempts exhausted"))
     (t
      (puthash key n rdev-state--attempts)
      (let ((delay (rdev-state-backoff-delay n)))
        (rdev-state-log key "reconnect attempt %d in %.1fs" n delay)
        ;; One timer per session, tracked in `rdev-state--timers' so a user
        ;; disconnect (or a new failure) can cancel the pending attempt and
        ;; two attempts never overlap.
        (puthash key (run-at-time delay nil #'rdev-state--attempt key)
                 rdev-state--timers))))))

(defun rdev-state--attempt (key)
  (remhash key rdev-state--timers)
  (when (eq (rdev-state key) 'reconnecting)
    (condition-case err
        (progn
          (unless rdev-state-connect-function
            (error "No rdev-state-connect-function"))
          (funcall rdev-state-connect-function key)
          (remhash key rdev-state--attempts)
          (rdev-state-log key "reconnected")
          (run-hook-with-args 'rdev-reconnected-hook key))
      (error
       (rdev-state-log key "attempt failed: %s" (error-message-string err))
       (when (eq (rdev-state key) 'reconnecting)
         (rdev-state-schedule-reconnect key))))))

(defun rdev-state-cancel-reconnect (key)
  "Stop any pending reconnect for KEY."
  (when-let* ((tm (gethash key rdev-state--timers)))
    (cancel-timer tm))
  (remhash key rdev-state--timers)
  (remhash key rdev-state--attempts))

(defun rdev-state-connection-lost (key)
  "Record an unexpected loss of KEY's transport and maybe start reconnecting."
  (when (memq (rdev-state key) '(connected degraded))
    (rdev-state-transition key 'reconnecting "transport closed")
    (run-hook-with-args 'rdev-state-lost-functions key)
    (if rdev-reconnect
        (rdev-state-schedule-reconnect key)
      (rdev-state-transition key 'failed "reconnect disabled"))))

(defun rdev-state-user-disconnect (key)
  "Record that the user closed KEY on purpose; cancel retries."
  (rdev-state-cancel-reconnect key)
  (when (rdev-state-transition key 'disconnecting "user request")
    (rdev-state-transition key 'disconnected)))

;;;; Log buffer with redaction

(defconst rdev-state--sensitive-name
  "\\(?:token\\|secret\\|passw\\(?:or\\)?d\\|passphrase\\|credential\\|api[_-]?key\\|private[_-]?key\\|auth\\)")

(defun rdev-state-redact (text)
  "Return TEXT with values of sensitive-looking settings masked."
  (let ((s text))
    ;; NAME=value / NAME: value / --token VALUE / "token":"value"
    (setq s (replace-regexp-in-string
             (concat "\\(\\(?:[A-Za-z0-9_-]*" rdev-state--sensitive-name
                     "[A-Za-z0-9_-]*\\)\\(?:=\\|:\\s-*\\|\\s-+\\)\\)"
                     "\\(\"[^\"]*\"\\|'[^']*'\\|[^[:space:],;}]+\\)")
             "\\1<redacted>" s t))
    (setq s (replace-regexp-in-string
             (concat "\\(\"[A-Za-z0-9_-]*" rdev-state--sensitive-name
                     "[A-Za-z0-9_-]*\"\\s-*:\\s-*\\)\"[^\"]*\"")
             "\\1\"<redacted>\"" s t))
    s))

(defun rdev-state-log-buffer (key)
  "Return the (redacted) log buffer for session KEY, creating it if needed."
  (get-buffer-create (format "*rdev-log %s*" key)))

(defun rdev-state-log (key fmt &rest args)
  "Append a redacted, timestamped line for KEY to its log buffer.
FMT and ARGS are as for `format'."
  (let ((line (rdev-state-redact (apply #'format fmt args))))
    (with-current-buffer (rdev-state-log-buffer key)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S ") line "\n")
          (when (> (count-lines (point-min) (point-max)) rdev-log-max-lines)
            (goto-char (point-min))
            (forward-line (- (count-lines (point-min) (point-max))
                             rdev-log-max-lines))
            (delete-region (point-min) (point))))))))

(provide 'rdev-state)
;;; rdev-state.el ends here
