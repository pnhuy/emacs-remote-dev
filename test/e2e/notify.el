;;; notify.el --- E2E file notification over real ssh (T048, FR-016/017)  -*- lexical-binding: t; -*-
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'autorevert)

(defun e2e-n--wait (pred timeout)
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun e2e-n--external (dir cmd)
  "Run shell CMD on the remote in DIR, outside rdev's file handlers."
  (let ((default-directory dir)) (process-file "sh" nil nil nil "-c" cmd)))

(ert-deftest e2e-notify-uses-native-backend ()
  (e2e-with-dir
    (let ((d (file-notify-add-watch e2e--dir '(change) #'ignore)))
      (should (file-notify-valid-p d))
      (should (string-match-p "inotify\\|kqueue"
                              (plist-get (rdev--req e2e-host :watch/add `(:path ,(file-local-name e2e--dir)))
                                         :backend)))
      (file-notify-rm-watch d))))

(ert-deftest e2e-notify-auto-revert-sees-external-change-within-2s ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "ar.txt")) (auto-revert-use-notify t)
           (auto-revert-interval 30)
           ;; Known limitation: vc-refresh-state after a revert issues several
           ;; synchronous requests; if auto-revert's lockout timer fires in
           ;; the middle, jsonrpc.el unwinds the nested wait (see KNOWN-FAILURES).
           (vc-handled-backends nil)
           (auto-revert-remote-files auto-revert-remote-files)
           (auto-revert-notify-exclude-dir-regexp auto-revert-notify-exclude-dir-regexp))
      (rdev-notify-enable-auto-revert)
      (write-region "one\n" nil f nil 'silent)
      (with-current-buffer (find-file-noselect f)
        (auto-revert-mode 1)
        (should auto-revert-notify-watch-descriptor)
        (let ((t0 (float-time)))
          (e2e-n--external e2e--dir "sleep 1; echo two >> ar.txt")
          (should (e2e-n--wait (lambda () (string-match-p "two" (buffer-string))) 5))
          ;; Elapsed time includes the 1 s sleep inside the command.
          (should (< (- (float-time) t0) 3.0)))
        (auto-revert-mode -1)
        (kill-buffer (current-buffer))))))

(ert-deftest e2e-notify-events-invalidate-cache ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "c.txt")) (got nil)
           (d (file-notify-add-watch e2e--dir '(change) (lambda (e) (push e got)))))
      (write-region "x" nil f nil 'silent)
      (should (= 1 (file-attribute-size (file-attributes f))))
      (e2e-n--external e2e--dir "sleep 1; echo yyy >> c.txt")
      (should (e2e-n--wait (lambda () (cl-find 'changed got :key (lambda (e) (nth 1 e))))  5))
      (should (= 5 (file-attribute-size (file-attributes f))))
      (file-notify-rm-watch d))))

(ert-deftest e2e-notify-watch-restored-after-ssh-kill ()
  (e2e-with-dir
    (let* ((got nil) (rdev-reconnect-base 0.5)
           (d (file-notify-add-watch e2e--dir '(change) (lambda (e) (push e got))))
           (g (rdev-conn-gen (rdev--conn e2e-host))))
      (signal-process (process-id (jsonrpc--process (rdev-conn-rpc (rdev--conn e2e-host)))) 'KILL)
      (should (e2e-n--wait (lambda () (let ((c (gethash e2e-host rdev--conns)))
                                         (and c (> (or (rdev-conn-gen c) 0) g)
                                              (eq 'connected (rdev-state (rdev-state-session-key e2e-host))))))
                           30))
      (should (e2e-n--wait (lambda () (file-notify-valid-p d)) 5))
      (e2e-n--external e2e--dir "echo hi > new.txt")
      (should (e2e-n--wait (lambda () (cl-find 'created got :key (lambda (e) (nth 1 e)))) 5))
      (file-notify-rm-watch d))))
