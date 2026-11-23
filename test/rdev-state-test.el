;;; rdev-state-test.el --- T050 connection state machine  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defmacro rdev-state-test--fresh (&rest body)
  `(let ((rdev-state--table (make-hash-table :test #'equal))
         (rdev-state--timers (make-hash-table :test #'equal))
         (rdev-state--attempts (make-hash-table :test #'equal))
         (rdev-state--keys (make-hash-table :test #'equal))
         (rdev-connection-state-hook nil) (rdev-reconnected-hook nil)
         (rdev-state-lost-functions nil)
         (rdev-state--strict nil))
     (unwind-protect (progn ,@body)
       (maphash (lambda (_k tm) (cancel-timer tm)) rdev-state--timers)
       (dolist (b (buffer-list))
         (when (string-prefix-p "*rdev-log k" (buffer-name b)) (kill-buffer b))))))

(defun rdev-state-test--walk (key &rest states)
  (dolist (s states) (should (rdev-state-transition key s))))

(ert-deftest rdev-state-every-documented-transition ()
  (rdev-state-test--fresh
   (let ((rdev-state--strict t))
     (rdev-state-test--walk "k1" 'connecting 'bootstrapping 'initializing 'connected
                            'degraded 'connected 'reconnecting 'initializing
                            'connected 'reconnecting 'failed 'connecting
                            'initializing 'failed 'connecting 'bootstrapping 'failed)
     (rdev-state-test--walk "k2" 'connecting 'initializing 'connected 'reconnecting
                            'failed)
     ;; reconnecting -> failed (attempts exhausted), disconnecting from any state
     (dolist (from '(connecting bootstrapping initializing connected degraded
                     reconnecting failed))
       (puthash "k3" from rdev-state--table)
       (should (rdev-state-transition "k3" 'disconnecting))
       (should (rdev-state-transition "k3" 'disconnected))))))

(ert-deftest rdev-state-illegal-transitions-ignored-and-logged ()
  (rdev-state-test--fresh
   (should-not (rdev-state-transition "k1" 'connected)) ; disconnected -> connected
   (should (eq 'disconnected (rdev-state "k1")))
   (should-not (rdev-state-transition "k1" 'disconnecting))
   (with-current-buffer (rdev-state-log-buffer "k1")
     (should (string-match-p "ignored illegal transition disconnected -> connected"
                             (buffer-string))))
   (let ((rdev-state--strict t))
     (should-error (rdev-state-transition "k1" 'degraded)))
   (should-error (rdev-state-transition "k1" 'bogus))))

(ert-deftest rdev-state-hook-runs-with-key-old-new ()
  (rdev-state-test--fresh
   (let (seen)
     (add-hook 'rdev-connection-state-hook (lambda (k o n) (push (list k o n) seen)))
     (rdev-state-transition "k1" 'connecting)
     (rdev-state-transition "k1" 'initializing)
     (should (equal (reverse seen) '(("k1" disconnected connecting)
                                     ("k1" connecting initializing)))))))

(ert-deftest rdev-state-single-inflight-attempt ()
  (rdev-state-test--fresh
   (should-not (rdev-state-attempt-in-flight-p "k1"))
   (rdev-state-transition "k1" 'connecting)
   (should (rdev-state-attempt-in-flight-p "k1"))
   (rdev-state-transition "k1" 'initializing)
   (rdev-state-transition "k1" 'connected)
   (should-not (rdev-state-attempt-in-flight-p "k1"))))

(ert-deftest rdev-state-session-key-shares-aliases ()
  (rdev-state-test--fresh
   (let ((rdev-state-ssh-g-function
          (lambda (h)
            (pcase h
              ((or "alias-a" "alias-b") "user alice\nhostname 10.0.0.5\nport 2222\n")
              ("other" "user alice\nhostname 10.0.0.6\nport 22\n")
              (_ nil)))))
     (should (equal "alice@10.0.0.5:2222" (rdev-state-session-key "alias-a")))
     (should (equal (rdev-state-session-key "alias-a") (rdev-state-session-key "alias-b")))
     (should-not (equal (rdev-state-session-key "alias-a") (rdev-state-session-key "other")))
     (should (equal "nossh" (rdev-state-session-key "nossh"))))))

(ert-deftest rdev-state-backoff-bounds ()
  (let ((rdev-reconnect-base 1.0) (rdev-reconnect-cap 10.0) (rdev-reconnect-jitter 0.2))
    (dotimes (_ 200)
      (let ((d1 (rdev-state-backoff-delay 1)) (d3 (rdev-state-backoff-delay 3))
            (d9 (rdev-state-backoff-delay 9)))
        (should (<= 0.8 d1 1.2))
        (should (<= 3.2 d3 4.8))
        (should (<= 8.0 d9 12.0))))))

(ert-deftest rdev-state-redaction ()
  (dolist (c '(("RDEV_TOKEN=abc123xyz" . "abc123xyz")
               ("--token s3cr3t-value" . "s3cr3t-value")
               ("password: hunter2" . "hunter2")
               ("{\"auth_token\": \"qq-zz\"}" . "qq-zz")
               ("MY_API_KEY='k-1 2'" . "k-1")))
    (let ((out (rdev-state-redact (car c))))
      (should-not (string-match-p (regexp-quote (cdr c)) out))
      (should (string-match-p "redacted" out))))
  (should (equal "connected to host" (rdev-state-redact "connected to host"))))

(ert-deftest rdev-state-log-buffer-trimmed-and-redacted ()
  (rdev-state-test--fresh
   (let ((rdev-log-max-lines 20))
     (dotimes (i 100) (rdev-state-log "k9" "line %d TOKEN=zzz%d" i i))
     (with-current-buffer (rdev-state-log-buffer "k9")
       (should (<= (count-lines (point-min) (point-max)) 20))
       (should (string-match-p "line 99" (buffer-string)))
       (should-not (string-match-p "zzz9" (buffer-string))))
     (kill-buffer (rdev-state-log-buffer "k9")))))

(ert-deftest rdev-state-reconnect-gives-up-after-max-attempts ()
  (rdev-state-test--fresh
   (let* ((rdev-reconnect-base 0.01) (rdev-reconnect-cap 0.02)
         (rdev-reconnect-max-attempts 3) (calls 0) (reconnected 0)
         (rdev-state-connect-function (lambda (_) (cl-incf calls) (error "down"))))
     (add-hook 'rdev-reconnected-hook (lambda (_) (cl-incf reconnected)))
     (rdev-state-test--walk "k1" 'connecting 'initializing 'connected)
     (rdev-state-connection-lost "k1")
     (should (eq 'reconnecting (rdev-state "k1")))
     (let ((deadline (+ (float-time) 3)))
       (while (and (not (eq 'failed (rdev-state "k1"))) (< (float-time) deadline))
         (sleep-for 0.02)))
     (should (eq 'failed (rdev-state "k1")))
     (should (= 3 calls))
     (should (= 0 reconnected)))))

(ert-deftest rdev-state-reconnect-success-runs-hook-once ()
  (rdev-state-test--fresh
   (let* ((rdev-reconnect-base 0.01) (calls 0) (reconnected nil) (lost nil)
         (rdev-state-connect-function
          (lambda (k) (cl-incf calls)
            (when (< calls 3) (error "still down"))
            (rdev-state-transition k 'initializing)
            (rdev-state-transition k 'connected))))
     (add-hook 'rdev-reconnected-hook (lambda (k) (push k reconnected)))
     (add-hook 'rdev-state-lost-functions (lambda (k) (push k lost)))
     (rdev-state-test--walk "k1" 'connecting 'initializing 'connected)
     (rdev-state-connection-lost "k1")
     (let ((deadline (+ (float-time) 5)))
       (while (and (null reconnected) (< (float-time) deadline))
         (sleep-for 0.02)))
     (sleep-for 0.1)
     (should (equal '("k1") reconnected))
     (should (equal '("k1") lost))
     (should (= 3 calls))
     (should (eq 'connected (rdev-state "k1"))))))

(ert-deftest rdev-state-user-disconnect-cancels-reconnect ()
  (rdev-state-test--fresh
   (let ((rdev-reconnect-base 5.0) (rdev-state-connect-function #'ignore))
     (rdev-state-test--walk "k1" 'connecting 'initializing 'connected)
     (rdev-state-connection-lost "k1")
     (should (gethash "k1" rdev-state--timers))
     (rdev-state-user-disconnect "k1")
     (should (eq 'disconnected (rdev-state "k1")))
     (should-not (gethash "k1" rdev-state--timers)))))

(ert-deftest rdev-state-reconnect-disabled-fails-fast ()
  (rdev-state-test--fresh
   (let ((rdev-reconnect nil))
     (rdev-state-test--walk "k1" 'connecting 'initializing 'connected)
     (rdev-state-connection-lost "k1")
     (should (eq 'failed (rdev-state "k1"))))))

;;; Integration with rdev.el using a stubbed ssh transport (a local agent).

(defvar rdev-state-test--procs nil)

(defun rdev-state-test--stub-ssh (_host _spec)
  (let* ((default-directory temporary-file-directory)
         (p (make-process :name "rdev-stub" :noquery t :connection-type 'pipe
                          :coding 'binary
                          :command (list (rdev-test--python) "-u" rdev-test-server-file "--stdio")
                          :stderr (get-buffer-create " *rdev-stub-stderr*"))))
    (push p rdev-state-test--procs)
    p))

(defmacro rdev-state-test--with-stub (&rest body)
  `(let ((rdev-state--table (make-hash-table :test #'equal))
         (rdev-state--timers (make-hash-table :test #'equal))
         (rdev-state--attempts (make-hash-table :test #'equal))
         (rdev-state--keys (make-hash-table :test #'equal))
         (rdev--conns (make-hash-table :test #'equal))
         (rdev--gens (make-hash-table :test #'equal))
         (rdev--key-hosts (make-hash-table :test #'equal))
         (rdev-state-ssh-g-function (lambda (_) nil))
         (rdev-reconnect-base 0.05) (rdev-reconnect-cap 0.1)
         (rdev-hosts nil) (rdev-state-test--procs nil)
         (rdev-reconnected-hook nil))
     (cl-letf (((symbol-function 'rdev--ssh-process) #'rdev-state-test--stub-ssh))
       (unwind-protect (progn ,@body)
         (maphash (lambda (_k tm) (cancel-timer tm)) rdev-state--timers)
         (let ((rdev-reconnect nil))
           (dolist (h (hash-table-keys rdev--conns))
             (ignore-errors (rdev-disconnect h))))
         (dolist (p rdev-state-test--procs) (when (process-live-p p) (delete-process p)))))))

(ert-deftest rdev-state-connect-walks-states-and-bumps-gen ()
  (rdev-state-test--with-stub
   (let (seen)
     (add-hook 'rdev-connection-state-hook (lambda (_k _o n) (push n seen)) nil)
     (unwind-protect
         (let ((c (rdev--conn "h1")))
           (should (eq 'connected (rdev-state "h1")))
           (should (= 1 (rdev-conn-gen c)))
           (should (equal '(connecting bootstrapping initializing connected)
                          (last (reverse seen) 4))))
       (remove-hook 'rdev-connection-state-hook (car rdev-connection-state-hook))))))

(ert-deftest rdev-state-alias-shares-one-connection ()
  (rdev-state-test--with-stub
   (let ((rdev-state-ssh-g-function (lambda (_) "user u\nhostname same\nport 22\n")))
     (let ((a (rdev--conn "alias-a")) (b (rdev--conn "alias-b")))
       (should (eq a b))
       (should (= 1 (length rdev-state-test--procs)))))))

(ert-deftest rdev-state-concurrent-connect-refused-not-duplicated ()
  (rdev-state-test--with-stub
   (let (inner)
     ;; A timer fires while the first connect waits on the agent.
     (run-at-time 0 nil (lambda ()
                          (setq inner (condition-case e (rdev--connect "h1")
                                        (rdev-connection-lost (car e))))))
     (cl-letf* ((orig (symbol-function 'rdev--ssh-process))
                ((symbol-function 'rdev--ssh-process)
                 (lambda (h s) (sleep-for 0.1) (funcall orig h s))))
       (rdev--conn "h1"))
     (should (eq 'rdev-connection-lost inner))
     (should (= 1 (length rdev-state-test--procs))))))

(ert-deftest rdev-state-loss-reconnects-and-interrupts-processes ()
  (rdev-state-test--with-stub
   (let* ((_c (rdev--conn "h1")) (reconnected 0)
          (chan (rdev--make-chan :id 7001 :host "h1" :cmd '("sleep" "1"))))
     (add-hook 'rdev-reconnected-hook (lambda (_) (cl-incf reconnected)))
     (rdev--chan-put chan)
     (let ((p (car (last rdev-state-test--procs))))
       (when (process-live-p p) (delete-process p)))
     (let ((deadline (+ (float-time) 5)))
       (while (and (zerop reconnected) (< (float-time) deadline))
         (accept-process-output nil 0.05)))
     (should (= 1 reconnected))
     (should (eq 'connected (rdev-state "h1")))
     (should (= 2 (rdev-conn-gen (rdev--conn "h1"))))
     (should (rdev-chan-interrupted chan))
     (should-not (rdev--chan-get "h1" 7001))
     (should (= 2 (length rdev-state-test--procs)))
     ;; The new connection works and has a fresh cache.
     (should (rdev-conn-has-cap (rdev--conn "h1") "fs.statMany")))))

(ert-deftest rdev-state-pending-request-fails-with-connection-lost ()
  (rdev-state-test--with-stub
   (let ((rdev-reconnect nil))
     (rdev--conn "h1")
     (run-at-time 0.2 nil (lambda () (delete-process (car (last rdev-state-test--procs)))))
     (should-error (rdev--req "h1" :exec/run `(:cmd ,(vector "sleep" "20")))
                   :type 'rdev-connection-lost)
     (should (eq 'failed (rdev-state "h1"))))))

(ert-deftest rdev-state-user-disconnect-does-not-reconnect ()
  (rdev-state-test--with-stub
   (rdev--conn "h1")
   (rdev-disconnect "h1")
   (accept-process-output nil 0.3)
   (should (eq 'disconnected (rdev-state "h1")))
   (should (= 1 (length rdev-state-test--procs)))))

(provide 'rdev-state-test)
