;;; ownership.el --- remote process ownership on failure paths (T119, FR-021)  -*- lexical-binding: t; -*-
;; The only implemented policy is: processes die with their session.  Every
;; way the session can end must take the remote process group with it within
;; grace_ms (default 2000) + 2 s.  Keep-alive is neither offered nor advertised.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defconst e2e-own--limit 4.5 "grace_ms (2 s) + 2 s, plus scheduling slack.")

(defun e2e-own--marker ()
  (format "%d.%d" (+ 1000 (random 8000)) (random 1000000)))

(defun e2e-own--ssh (cmd)
  "Run CMD on the host over a plain ssh, independent of the rdev connection."
  (with-temp-buffer
    (call-process "ssh" nil t nil "-o" "BatchMode=yes" e2e-host cmd)
    (buffer-string)))

(defun e2e-own--remote-count (marker)
  "Number of remote processes whose command line mentions MARKER."
  (string-to-number (e2e-own--ssh (format "pgrep -f '[s]leep %s' | wc -l" marker))))

(defun e2e-own--start (marker)
  "Start a long remote sleep through a relay process; return the local process."
  (let ((default-directory (concat (e2e--root) "/tmp/")))
    (prog1 (make-process :name "e2e-own" :buffer nil :noquery t
                         :command (list "sleep" marker) :file-handler t
                         :connection-type 'pipe)
      ;; Wait for the remote process to exist.
      (let ((deadline (+ (float-time) 10)))
        (while (and (zerop (e2e-own--remote-count marker)) (< (float-time) deadline))
          (sleep-for 0.1))))))

(defun e2e-own--wait-gone (marker)
  "Seconds until no remote process matches MARKER, or nil past the limit."
  (let ((t0 (float-time)))
    (while (and (> (e2e-own--remote-count marker) 0)
                (< (- (float-time) t0) (+ e2e-own--limit 2)))
      (sleep-for 0.2))
    (and (zerop (e2e-own--remote-count marker)) (- (float-time) t0))))

(defun e2e-own--cleanup (marker)
  (ignore-errors (e2e-own--ssh (format "pkill -f '[s]leep %s'" marker))))

(ert-deftest e2e-ownership-baseline-process-runs ()
  "Sanity: the helper really sees the remote process (guards against vacuous passes)."
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m)))
    (unwind-protect
        (progn (should (process-live-p pr))
               (should (= 1 (e2e-own--remote-count m))))
      (e2e-own--cleanup m))))

(ert-deftest e2e-ownership-killed-relay-terminates-remote ()
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m)))
    (unwind-protect
        (progn
          (should (= 1 (e2e-own--remote-count m)))
          (signal-process (process-id pr) 'KILL)
          (let ((dt (e2e-own--wait-gone m)))
            (should dt)
            (should (< dt e2e-own--limit))))
      (e2e-own--cleanup m))))

(ert-deftest e2e-ownership-killed-ssh-terminates-remote ()
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m))
         (ssh (jsonrpc--process (rdev-conn-rpc (rdev--conn e2e-host)))))
    (unwind-protect
        (progn
          (should (= 1 (e2e-own--remote-count-via-new m)))
          (signal-process (process-id ssh) 'KILL)
          (let ((dt (e2e-own--wait-gone m)))
            (should dt)
            (should (< dt e2e-own--limit)))
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p pr) (< (float-time) deadline))
              (accept-process-output nil 0.1)))
          (should-not (process-live-p pr)))
      (e2e-own--cleanup m))))

(defun e2e-own--remote-count-via-new (marker)
  (e2e-own--remote-count marker))

(ert-deftest e2e-ownership-session-shutdown-terminates-remote ()
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m)))
    (ignore pr)
    (unwind-protect
        (progn
          (should (= 1 (e2e-own--remote-count m)))
          (ignore-errors (rdev--req e2e-host :session/shutdown '(:grace_ms 500)))
          (let ((dt (e2e-own--wait-gone m)))
            (should dt)
            (should (< dt e2e-own--limit))))
      (e2e-own--cleanup m))))

(ert-deftest e2e-ownership-agent-sigterm-terminates-remote ()
  "The agent itself being terminated must not leave its processes behind."
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m)))
    (ignore pr)
    (unwind-protect
        (progn
          (should (= 1 (e2e-own--remote-count m)))
          (e2e-own--ssh "pkill -TERM -f '[r]dev-server.*--stdio'")
          (let ((dt (e2e-own--wait-gone m)))
            (should dt)
            (should (< dt e2e-own--limit))))
      (e2e-own--cleanup m))))

(ert-deftest e2e-ownership-client-signals-on-relay-eof-without-exit-frame ()
  "Relay EOF with no `X' frame makes the client send proc/signal for the process."
  (let* ((rdev-reconnect nil) (m (e2e-own--marker)) (pr (e2e-own--start m))
         (sent nil))
    (unwind-protect
        (progn
          (advice-add 'rdev--notify :before
                      (lambda (_h method params) (when (eq method :proc/signal) (push params sent)))
                      '((name . e2e-own-spy)))
          (signal-process (process-id pr) 'KILL)
          (let ((deadline (+ (float-time) 5)))
            (while (and (null sent) (< (float-time) deadline)) (accept-process-output nil 0.1)))
          (should sent)
          (should (= 9 (plist-get (car sent) :sig))))
      (advice-remove 'rdev--notify 'e2e-own-spy)
      (e2e-own--cleanup m))))
