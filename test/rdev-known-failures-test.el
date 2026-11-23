;;; rdev-known-failures-test.el --- confirmed client defects (T028, FR-006)  -*- lexical-binding: t; -*-

;; Each test here pins a confirmed defect (D-xx) fixed since; the expected-failure
;; tags were removed when the fixes landed (see test/KNOWN-FAILURES.md).

(require 'rdev-test-helpers)

(defun rdev-kf--capture-ssh (host)
  "Call `rdev--ssh-process' for HOST with `make-process' stubbed.
Return the captured :command list (nil if nothing was spawned)."
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest a) (setq cmd (plist-get a :command)) (error "stubbed")))
              ((symbol-function 'rdev--wait-for) #'ignore))
      (ignore-errors (rdev--ssh-process host nil)))
    cmd))

(ert-deftest rdev-kf-d01-leading-dash-host-rejected ()
  "D-01: a host starting with `-' must be rejected before ssh is spawned."
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest a) (setq cmd (plist-get a :command)) (error "stubbed")))
              ((symbol-function 'rdev--wait-for) #'ignore))
      (should-error (rdev--ssh-process "-oProxyCommand=id" nil) :type 'user-error))
    (should-not cmd)))

(ert-deftest rdev-kf-d01-double-dash-before-host ()
  "D-01: ssh argv must put `--' before the host."
  (let* ((cmd (rdev-kf--capture-ssh "goodhost"))
         (dd (cl-position "--" cmd :test #'equal))
         (hp (cl-position "goodhost" cmd :test #'equal)))
    (should dd) (should hp) (should (< dd hp))))

(ert-deftest rdev-kf-d02-truncated-stream-not-installed ()
  "D-02: a stream shorter than the script must not leave an installed agent."
  (let* ((cmd (rdev-kf--capture-ssh "goodhost"))
         (remote (car (last cmd)))
         (home (make-temp-file "rdev-home" t))
         (bin (make-temp-file "rdev-bin" t))
         (py (expand-file-name "python3" bin)))
    (unwind-protect
        (progn
          (with-temp-file py (insert "#!/bin/sh\nexit 0\n"))
          (set-file-modes py #o755)
          (let ((process-environment (append (list (concat "HOME=" home)
                                                   (concat "PATH=" bin ":/usr/bin:/bin"))
                                             process-environment))
                (default-directory temporary-file-directory))
            (with-temp-buffer
              (insert (make-string 40 ?x))   ; far fewer bytes than the script
              (call-process-region (point-min) (point-max) "sh" nil nil nil "-c" remote)))
          (should-not (file-expand-wildcards (concat home "/.cache/rdev/rdev-server-*.py"))))
      (delete-directory home t)
      (delete-directory bin t))))

(ert-deftest rdev-kf-d06-channel-ids-scoped-per-host ()
  "D-06: an exit notification from host B must not touch host A's channel."
  (rdev-test--connect "A")
  (rdev-test--connect "B")
  (unwind-protect
      (let ((chan (rdev--make-chan :id 4242 :host "A")))
        (rdev--chan-put chan)
        (condition-case nil
            (rdev--dispatch (rdev-conn-rpc (gethash "B" rdev--conns)) 'proc/exit
                            '(:id 4242 :code 0))
          (error nil))
        (should-not (rdev-chan-exited chan)))
    (clrhash rdev--chans)
    (dolist (h '("A" "B")) (rdev-test--disconnect h))))

(ert-deftest rdev-kf-d08-bytes-after-marker-reach-jsonrpc ()
  "D-08: a notification coalesced with the bootstrap marker must be delivered."
  (let* ((dir (make-temp-file "rdev-fakessh" t))
         (ssh (expand-file-name "ssh" dir))
         (body "{\"jsonrpc\":\"2.0\",\"method\":\"proc/exit\",\"params\":{\"id\":99,\"code\":0}}")
         seen)
    (unwind-protect
        (progn
          (with-temp-file ssh
            (insert (format "#!%s\nimport os,sys\nb=%S\nsys.stdout.buffer.write(b'RDEV-READY\\n'+('Content-Length: %%d\\r\\n\\r\\n'%%len(b)).encode()+b.encode())\nsys.stdout.buffer.flush()\nos.execv(sys.executable,[sys.executable,'-u',%S,'--stdio'])\n"
                            (executable-find (rdev-test--python)) body rdev-test-server-file)))
          (set-file-modes ssh #o755)
          (let ((exec-path (cons dir exec-path))
                (process-environment (cons (concat "PATH=" dir ":" (getenv "PATH")) process-environment))
                (rdev-hosts nil))
            (advice-add 'rdev--dispatch :before
                        (lambda (_c m p) (push (list m p) seen)) '((name . rdev-kf-d08)))
            (unwind-protect
                (progn (rdev--connect "fakehost") ; precondition: must connect (errors fail loudly)
                       (should (gethash "fakehost" rdev--conns))
                       (let ((deadline (+ (float-time) 3)))
                         (while (and (not seen) (< (float-time) deadline))
                           (accept-process-output nil 0.1)))
                       (should (assq 'proc/exit seen)))
              (advice-remove 'rdev--dispatch 'rdev-kf-d08)
              (ignore-errors (when-let* ((c (gethash "fakehost" rdev--conns)))
                               (jsonrpc-shutdown (rdev-conn-rpc c)))))))
      (delete-directory dir t))))

(defun rdev-kf--fake-sock ()
  (make-process :name "rdev-kf-sock" :command '("cat") :connection-type 'pipe :noquery t
                :coding 'binary))

(ert-deftest rdev-kf-d09-unknown-relay-frame-type-closes ()
  "D-09: an unknown relay frame type must terminate the channel, not be ignored."
  (let ((sock (rdev-kf--fake-sock)))
    (unwind-protect
        (progn (rdev--relay-filter sock (concat "Z" (rdev--u32 0)))
               (should-not (process-live-p sock)))
      (when (process-live-p sock) (delete-process sock)))))

(ert-deftest rdev-kf-d09-oversized-relay-length-closes ()
  "D-09: an oversized LEN must be rejected, not buffered."
  (let ((sock (rdev-kf--fake-sock)))
    (unwind-protect
        (progn (rdev--relay-filter sock (concat "O" (rdev--u32 #xFFFFFFF0) "x"))
               (should-not (process-live-p sock)))
      (when (process-live-p sock) (delete-process sock)))))

(ert-deftest rdev-kf-d11-plaintext-tcp-non-loopback-refused ()
  "D-11: plaintext TCP to a non-loopback address must be refused without opt-in."
  (let (called)
    (cl-letf (((symbol-function 'open-network-stream)
               (lambda (&rest _) (setq called t) (error "stubbed"))))
      (ignore-errors (rdev--tcp-process "far" '(:address "192.0.2.1" :port 7007))))
    (should-not called)))

(provide 'rdev-known-failures-test)
;;; rdev-known-failures-test.el ends here
