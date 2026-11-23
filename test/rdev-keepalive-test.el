;;; rdev-keepalive-test.el --- CONNECTED <-> DEGRADED via keepalive  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defun rdev-keepalive-test--wait (pred secs)
  (let ((deadline (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest rdev-keepalive-unanswered-probe-degrades-then-recovers ()
  "No reply within `rdev-degraded-after' -> degraded; a late reply -> connected."
  (rdev-test--connect)
  (let* ((key (rdev-state-session-key "test")) (rdev-degraded-after 0.3) late)
    (dolist (s '(connecting initializing connected)) (rdev-state-transition key s))
    (unwind-protect
        (cl-letf (((symbol-function 'jsonrpc-async-request)
                   (lambda (_rpc _m _p &rest args) (setq late (plist-get args :success-fn)))))
          (rdev--keepalive-tick)
          (should (gethash key rdev--keepalive-pending))
          (rdev--keepalive-tick)        ; a second tick must not pile up probes
          (should (rdev-keepalive-test--wait (lambda () (eq (rdev-state key) 'degraded)) 5))
          (funcall late nil)
          (should (eq (rdev-state key) 'connected))
          (should-not (gethash key rdev--keepalive-pending)))
      (rdev--keepalive-forget key)
      (rdev-test--disconnect)
      (rdev-state-user-disconnect key))))

(ert-deftest rdev-keepalive-send-failure-does-not-degrade ()
  (rdev-test--connect)
  (let* ((key (rdev-state-session-key "test")) (rdev-degraded-after 0.2))
    (dolist (s '(connecting initializing connected)) (rdev-state-transition key s))
    (unwind-protect
        (cl-letf (((symbol-function 'jsonrpc-async-request)
                   (lambda (&rest _) (error "Process not running"))))
          (rdev--keepalive-tick)
          (should-not (gethash key rdev--keepalive-pending))
          (sleep-for 0.4)
          (should (eq (rdev-state key) 'connected)))
      (rdev-test--disconnect)
      (rdev-state-user-disconnect key))))

(ert-deftest rdev-keepalive-healthy-agent-stays-connected ()
  (rdev-test--connect)
  (let* ((key (rdev-state-session-key "test")) (rdev-degraded-after 0.4))
    (dolist (s '(connecting initializing connected)) (rdev-state-transition key s))
    (unwind-protect
        (progn
          (rdev--keepalive-tick)
          (should (rdev-keepalive-test--wait
                   (lambda () (not (gethash key rdev--keepalive-pending))) 5))
          (sleep-for 0.6)
          (should (eq (rdev-state key) 'connected)))
      (rdev--keepalive-forget key)
      (rdev-test--disconnect)
      (rdev-state-user-disconnect key))))

(provide 'rdev-keepalive-test)
