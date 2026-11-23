;;; keepalive.el --- real stalled agent: connected -> degraded -> connected  -*- lexical-binding: t; -*-
;; The remote agent is stopped with SIGSTOP (the ssh transport stays up, so this is a
;; slow/unresponsive peer, not a closed connection) and then resumed.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun e2e-keepalive--ssh (cmd)
  (with-temp-buffer
    (let ((code (apply #'call-process "ssh" nil t nil
                       (append (and (getenv "RDEV_TEST_SSH_CONFIG") (list "-F" (getenv "RDEV_TEST_SSH_CONFIG")))
                               (list e2e-host cmd)))))
      (cons code (string-trim (buffer-string))))))

(ert-deftest e2e-keepalive-stalled-agent-degrades-and-recovers ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (key (rdev-state-session-key e2e-host))
           (rdev-degraded-after 1)
           (pid (with-temp-buffer
                  (process-file "sh" nil t nil "-c" "echo $PPID")
                  (string-to-number (buffer-string)))))
      (should (> pid 1))
      (should (eq (rdev-state key) 'connected))
      (unwind-protect
          (progn
            (e2e-keepalive--ssh (format "kill -STOP %d" pid))
            (rdev--keepalive-tick)
            (let ((deadline (+ (float-time) 10)))
              (while (and (not (eq (rdev-state key) 'degraded)) (< (float-time) deadline))
                (accept-process-output nil 0.1)))
            (should (eq (rdev-state key) 'degraded))
            (e2e-keepalive--ssh (format "kill -CONT %d" pid))
            (let ((deadline (+ (float-time) 20)))
              (while (and (not (eq (rdev-state key) 'connected)) (< (float-time) deadline))
                (rdev--keepalive-tick)
                (accept-process-output nil 0.2)))
            (should (eq (rdev-state key) 'connected))
            ;; and the connection still serves requests
            (should (file-exists-p (concat (e2e--root) "/tmp"))))
        (e2e-keepalive--ssh (format "kill -CONT %d" pid))))))
