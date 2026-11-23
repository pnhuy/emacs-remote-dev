;;; rdev-security-tcp-test.el --- TCP transport security (T060, FR-034)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defun rdev-sectcp--free-port ()
  (let ((p (make-network-process :name "rdev-port" :server t :host "127.0.0.1" :service t)))
    (prog1 (process-contact p :service) (delete-process p))))

(defmacro rdev-sectcp--with-agent (port token &rest body)
  (declare (indent 2))
  `(let* ((,port (rdev-sectcp--free-port))
          (agent (make-process :name "rdev-tcp-agent" :noquery t
                               :command (list (rdev-test--python) "-u" rdev-test-server-file
                                              "--listen" (format "127.0.0.1:%d" ,port)
                                              "--token" ,token)
                               :buffer (generate-new-buffer " *rdev-tcp-agent*"))))
     (unwind-protect
         (progn (let ((n 0)) (while (and (< n 50) (not (ignore-errors
                                                          (delete-process (open-network-stream "p" nil "127.0.0.1" ,port)) t)))
                               (sleep-for 0.1) (cl-incf n)))
                ,@body)
       ;; A user disconnect, not a transport loss: no reconnect may start.
       (let ((rdev-reconnect nil)) (ignore-errors (rdev-disconnect "tcphost")))
       (remhash "tcphost" rdev--conns)
       (delete-process agent) (kill-buffer (process-buffer agent)))))

(ert-deftest rdev-sectcp-non-loopback-refused-without-opt-in ()
  (let ((rdev-allow-insecure-tcp nil) called
        (rdev-hosts '(("far" :transport tcp :address "203.0.113.9" :port 9 :token "t"))))
    (cl-letf (((symbol-function 'open-network-stream) (lambda (&rest _) (setq called t) (error "no"))))
      (should-error (rdev--connect "far") :type 'user-error)
      (should-not called))))

(ert-deftest rdev-sectcp-opt-in-warns-on-every-connect ()
  (let ((rdev-allow-insecure-tcp t) (warnings 0)
        (rdev-hosts '(("far" :transport tcp :address "203.0.113.9" :port 9 :token "t"))))
    (cl-letf (((symbol-function 'open-network-stream) (lambda (&rest _) (error "stop")))
              ((symbol-function 'display-warning) (lambda (&rest _) (cl-incf warnings))))
      (dotimes (_ 2) (ignore-errors (rdev--connect "far")))
      (should (= warnings 2)))))

(ert-deftest rdev-sectcp-loopback-connect-with-token-and-no-leak ()
  (rdev-sectcp--with-agent port "sekrit-token-123"
    (let ((rdev-hosts `(("tcphost" :transport tcp :address "127.0.0.1" :port ,port
                         :token "sekrit-token-123")))
          (msgs (get-buffer-create "*rdev-sectcp-msgs*")) leaked)
      (cl-letf (((symbol-function 'message)
                 (lambda (f &rest a) (with-current-buffer msgs (insert (apply #'format f a) "\n")))))
        (let ((c (rdev--connect "tcphost")))
          (should (rdev-conn-p c))
          (should (equal "1.1" (rdev-conn-proto c)))
          (setq leaked (with-current-buffer msgs (string-match-p "sekrit-token-123" (buffer-string))))
          (dolist (b (buffer-list))
            (when (and (string-match-p "rdev" (buffer-name b))
                       (not (eq b msgs)) (not (equal (buffer-name b) " *rdev-tcp-agent*")))
              (with-current-buffer b
                (when (save-excursion (goto-char (point-min)) (search-forward "sekrit-token-123" nil t))
                  (setq leaked t)))))
          (should-not leaked)))
      (kill-buffer msgs))))

(ert-deftest rdev-sectcp-token-from-env-and-wrong-token-rejected ()
  (rdev-sectcp--with-agent port "right"
    (let ((rdev-hosts `(("tcphost" :transport tcp :address "127.0.0.1" :port ,port :token "wrong"))))
      (should-error (rdev--connect "tcphost")))
    (let ((rdev-hosts `(("tcphost" :transport tcp :address "127.0.0.1" :port ,port)))
          (process-environment (cons "RDEV_TOKEN=right" process-environment)))
      (should (rdev-conn-p (rdev--connect "tcphost"))))))

(ert-deftest rdev-sectcp-status-does-not-show-token ()
  (rdev-sectcp--with-agent port "status-secret-9"
    (let ((rdev-hosts `(("tcphost" :transport tcp :address "127.0.0.1" :port ,port
                         :token "status-secret-9"))))
      (rdev--connect "tcphost")
      (should-not (string-match-p "status-secret-9" (prin1-to-string (rdev-conn-transport (gethash "tcphost" rdev--conns)))))
      (should-not (string-match-p "status-secret-9"
                                  (with-output-to-string (when (fboundp 'rdev-status) (rdev-status))))))))

(ert-deftest rdev-sectcp-log-buffer-never-holds-token-or-secret-env ()
  "Neither the token nor sensitive env values reach `*rdev-log HOST*' (FR-034)."
  (rdev-sectcp--with-agent port "log-token-777"
    (let* ((rdev-hosts `(("tcphost" :transport tcp :address "127.0.0.1" :port ,port
                          :token "log-token-777")))
           (key (rdev-state-session-key "tcphost")))
      (rdev--connect "tcphost")
      ;; Lines that agents/ssh might echo must be redacted on the way in.
      (rdev-state-log key "env dump: API_TOKEN=env-secret-42 PASSWORD=hunter2 --token log-token-777")
      (rdev-state-log key "{\"token\":\"log-token-777\",\"passphrase\":\"pp-99\"}")
      (let ((text (with-current-buffer (rdev-state-log-buffer key) (buffer-string))))
        (dolist (secret '("log-token-777" "env-secret-42" "hunter2" "pp-99"))
          (should-not (string-match-p (regexp-quote secret) text)))
        (should (string-match-p "<redacted>" text))))))

(ert-deftest rdev-sectcp-stderr-flush-redacts ()
  "Agent/ssh stderr copied into the log is redacted."
  (let* ((key "u@redact:22") (host "redact-host")
         (buf (get-buffer-create (format " *rdev-stderr %s*" host))))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "auth failed SECRET_KEY=stderr-secret-5\n"))
          (rdev--flush-stderr-to-log host key)
          (should-not (string-match-p "stderr-secret-5"
                                      (with-current-buffer (rdev-state-log-buffer key)
                                        (buffer-string)))))
      (kill-buffer buf) (kill-buffer (rdev-state-log-buffer key)))))

(provide 'rdev-security-tcp-test)
