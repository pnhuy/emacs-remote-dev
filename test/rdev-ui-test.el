;;; rdev-ui-test.el --- connection UI (T084)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'rdev-ui)

(defun rdev-ui-test--mark-connected (host)
  "The stdio test harness bypasses the state machine; walk it by hand."
  (let ((k (rdev-state-session-key host)))
    (dolist (s '(connecting initializing connected)) (rdev-state-transition k s))))

(ert-deftest rdev-ui-list-shows-columns-and-rows ()
  (rdev-test--connect)
  (rdev-ui-test--mark-connected "test")
  (unwind-protect
      (progn
        (rdev-list-connections)
        (with-current-buffer "*rdev-connections*"
          (should (derived-mode-p 'rdev-list-mode))
          ;; The Target column sits between Host and State.
          (should (equal '("Host" "Target" "State" "Latency" "Procs" "Cache e/h/m" "Agent" "Protocol")
                         (mapcar #'car tabulated-list-format)))
          (let ((row (assoc "test" (funcall tabulated-list-entries))))
            (should row)
            (should (equal "connected" (aref (cadr row) 2)))
            (should (string-match-p "ms\\'" (aref (cadr row) 3)))
            (should (equal "-" (aref (cadr row) 1))) ; ssh/tcp targets show -
            (should (equal "1.1" (aref (cadr row) 7))))
          (dolist (k '("c" "r" "k" "R" "l" "g"))
            (should (commandp (lookup-key rdev-list-mode-map k))))))
    (kill-buffer "*rdev-connections*")
    (rdev-state-user-disconnect (rdev-state-session-key "test"))
    (rdev-test--disconnect)))

(ert-deftest rdev-ui-autoloads-and-commands-exist ()
  (dolist (f '(rdev-connect rdev-reconnect rdev-restart-server rdev-show-logs
               rdev-list-connections rdev-cache-inspect))
    (should (commandp f))))

(ert-deftest rdev-ui-show-logs-opens-redacted-log ()
  (let ((key (rdev-state-session-key "uihost")))
    (unwind-protect
        (progn (rdev-state-log key "token=zzz-secret hello")
               (save-window-excursion
                 (rdev-show-logs "uihost")
                 (should (string-match-p "rdev-log" (buffer-name)))
                 (should-not (string-match-p "zzz-secret" (buffer-string)))))
      (kill-buffer (rdev-state-log-buffer key)))))

(ert-deftest rdev-ui-restart-bumps-generation ()
  (rdev-test--connect)
  (unwind-protect
      (let ((g (rdev-conn-gen (rdev--conn "test"))))
        (cl-letf (((symbol-function 'rdev-reconnect)
                   (lambda (h) (should (equal h "test")) (setq g 'called))))
          (rdev-restart-server "test"))
        (should (eq g 'called)))
    (rdev-test--disconnect)))

(ert-deftest rdev-ui-mode-line-only-in-rdev-buffers ()
  (let ((default-directory "/tmp/")) (should-not (rdev-mode-line-indicator)))
  (rdev-test--connect)
  (unwind-protect
      (let ((default-directory "/rdev:test:/tmp/"))
        (should (string-match-p "rdev:\\(connected\\|disconnected\\)" (rdev-mode-line-indicator)))
        (let ((rdev-mode-line nil)) (should-not (rdev-mode-line-indicator))))
    (rdev-test--disconnect)))

(ert-deftest rdev-ui-status-includes-state ()
  (rdev-test--connect)
  (unwind-protect
      (progn (rdev-status)
             (with-current-buffer "*rdev*"
               (should (string-match-p "state=" (buffer-string)))
               (should (string-match-p "rdev connections" (buffer-string)))))
    (rdev-test--disconnect)))

(provide 'rdev-ui-test)
