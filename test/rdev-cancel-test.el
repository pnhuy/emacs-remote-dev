;;; rdev-cancel-test.el --- C-g cancels remote exec/run (T077)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(ert-deftest rdev-quit-cancels-remote-exec ()
  (rdev-test-with-twin-dir (native remote)
    (should (rdev-conn-has-cap (rdev--conn "test") "cancel"))
    (let ((t0 (float-time)) quit-seen)
      ;; Batch Emacs only polls `quit-flag' when accept-process-output returns,
      ;; so raise the quit from a timer instead (as C-g does interactively).
      (run-at-time 0.5 nil (lambda () (signal 'quit nil)))
      (condition-case nil
          (rdev--req "test" :exec/run
                     `(:cmd ,(vector "sleep" "31.17")))
        (quit (setq quit-seen t)))
      (setq quit-flag nil)
      (should quit-seen)
      (should (< (- (float-time) t0) 5))
      ;; The agent killed the process group: no sleep left behind.
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline)
                    (zerop (call-process "pgrep" nil nil nil "-f" "sleep 31.17")))
          (sleep-for 0.1)))
      (should-not (zerop (call-process "pgrep" nil nil nil "-f" "sleep 31.17")))
      ;; The connection is still usable.
      (should (equal 0 (plist-get (rdev--req "test" :exec/run
                                             `(:cmd ,(vector "true")))
                                  :code))))))
