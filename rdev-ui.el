;;; rdev-ui.el --- Connection management UI for rdev  -*- lexical-binding: t; -*-

;;; Commentary:

;; Commands for connecting, reconnecting, restarting the agent, reading the
;; connection log and listing connections.  The protocol and transport stay
;; in rdev.el and rdev-state.el; this file only presents them (Article IX).

;;; Code:

(require 'rdev)
(require 'tabulated-list)

(defun rdev-ui--hosts ()
  "All hosts with a live connection or a recorded session."
  (delete-dups (append (hash-table-keys rdev--conns)
                       (hash-table-values rdev--key-hosts))))

(defun rdev-ui--read-host (prompt)
  "Read a host with PROMPT, offering known and configured hosts."
  (completing-read prompt (delete-dups (append (rdev-ui--hosts) (rdev--ssh-hosts))) nil nil))

;;;###autoload
(defun rdev-connect (host)
  "Connect to HOST now and return its connection."
  (interactive (list (rdev-ui--read-host "Connect to: ")))
  (prog1 (rdev--conn host) (message "rdev: %s is %s" host (rdev-state (rdev-state-session-key host)))))

(defun rdev-ui--live-procs (host)
  "Number of live remote processes on HOST."
  (let ((n 0))
    (maphash (lambda (_k ch)
               (when (and (equal (rdev-chan-host ch) host) (not (rdev-chan-exited ch)))
                 (cl-incf n)))
             rdev--chans)
    n))

;;;###autoload
(defun rdev-restart-server (host)
  "Restart the agent on HOST by dropping and re-establishing the connection.
Remote processes die with the old agent and are not restarted; you are
asked first when some are running."
  (interactive (list (rdev-ui--read-host "Restart server on: ")))
  (let ((n (rdev-ui--live-procs host)))
    (when (or (zerop n) (not (called-interactively-p 'any))
              (yes-or-no-p (format "%d remote process(es) on %s will end; restart? " n host)))
      (rdev-reconnect host))))

;;;###autoload
(defun rdev-show-logs (host)
  "Show the connection log of HOST (secrets are redacted)."
  (interactive (list (rdev-ui--read-host "Logs for: ")))
  (pop-to-buffer (rdev-state-log-buffer (rdev-state-session-key host))))

(defun rdev-ui--latency (host)
  "Round-trip time to HOST in milliseconds as a string, or \"-\"."
  (let ((c (gethash host rdev--conns)))
    (if (and c (jsonrpc-running-p (rdev-conn-rpc c)))
        (condition-case nil
            (let ((t0 (float-time)))
              (jsonrpc-request (rdev-conn-rpc c) :hello nil :timeout 2)
              (format "%.0f ms" (* 1000 (- (float-time) t0))))
          (error "-"))
      "-")))

(defun rdev-ui--row (host)
  "Tabulated-list entry for HOST."
  (let* ((c (gethash host rdev--conns))
         (st (rdev-state (rdev-state-session-key host)))
         (cs (and c (rdev-cache-stats host))))
    (list host
          (vector host (symbol-name st)
                  (rdev-ui--latency host)
                  (number-to-string (rdev-ui--live-procs host))
                  (if cs (format "%d/%d/%d" (plist-get cs :entries)
                                 (plist-get cs :hits) (plist-get cs :misses))
                    "-")
                  (or (and c (plist-get (rdev-conn-stats c) :agent)) "-")
                  (or (and c (rdev-conn-proto c)) "-")))))

(defun rdev-ui--entries ()
  "Entries for `tabulated-list-entries'."
  (mapcar #'rdev-ui--row (rdev-ui--hosts)))

(defun rdev-ui--host-at-point ()
  "Host of the current row or a user error."
  (or (tabulated-list-get-id) (user-error "No connection on this line")))

(defvar-keymap rdev-list-mode-map
  :parent tabulated-list-mode-map
  "c" #'rdev-ui-list-connect
  "r" #'rdev-ui-list-reconnect
  "k" #'rdev-ui-list-kill
  "R" #'rdev-ui-list-restart
  "l" #'rdev-ui-list-logs
  "g" #'revert-buffer)

(define-derived-mode rdev-list-mode tabulated-list-mode "rdev-connections"
  "Major mode listing rdev connections.
\\{rdev-list-mode-map}"
  (setq tabulated-list-format
        [("Host" 22 t) ("State" 14 t) ("Latency" 9 nil) ("Procs" 6 nil)
         ("Cache e/h/m" 14 nil) ("Agent" 10 t) ("Protocol" 9 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'rdev-ui--entries)
  (tabulated-list-init-header))

(defun rdev-ui-list-connect (host)
  "Connect to HOST (the one on this line, or ask)."
  (interactive (list (or (tabulated-list-get-id) (rdev-ui--read-host "Connect to: "))))
  (rdev-connect host) (revert-buffer))

(defun rdev-ui-list-reconnect ()
  "Reconnect the host on this line."
  (interactive) (rdev-reconnect (rdev-ui--host-at-point)) (revert-buffer))

(defun rdev-ui-list-kill ()
  "Disconnect the host on this line."
  (interactive) (rdev-disconnect (rdev-ui--host-at-point)) (revert-buffer))

(defun rdev-ui-list-restart ()
  "Restart the agent of the host on this line."
  (interactive) (rdev-restart-server (rdev-ui--host-at-point)) (revert-buffer))

(defun rdev-ui-list-logs ()
  "Show the log of the host on this line."
  (interactive) (rdev-show-logs (rdev-ui--host-at-point)))

;;;###autoload
(defun rdev-list-connections ()
  "List rdev connections: Host, State, Latency, Procs, Cache, Agent, Protocol.
Keys: c connect, r reconnect, k disconnect, R restart server, l logs, g refresh."
  (interactive)
  (let ((buf (get-buffer-create "*rdev-connections*")))
    (with-current-buffer buf
      (rdev-list-mode)
      (tabulated-list-print))
    (pop-to-buffer buf)))

;;;###autoload
(defun rdev-cache-inspect (&optional host)
  "Show cache statistics (entries, hits, misses, evictions) for HOST (FR-016)."
  (interactive (list (rdev-ui--read-host "Cache of: ")))
  (let ((s (rdev-cache-stats host)))
    (message "rdev cache %s: %d entries, %d hits, %d misses, %d evictions (ttl %ss, max %d)"
             host (plist-get s :entries) (plist-get s :hits) (plist-get s :misses)
             (plist-get s :evictions) rdev-cache-ttl rdev-cache-max-entries)
    s))

(provide 'rdev-ui)
;;; rdev-ui.el ends here
