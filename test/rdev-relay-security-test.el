;;; rdev-relay-security-test.el --- T061/T065 relay socket hardening  -*- lexical-binding: t; -*-
(require 'ert)
(require 'rdev-test-helpers)

(defmacro rdev-relay-test--with-runtime-dir (&rest body)
  `(let* ((tmp (make-temp-file "rdev-xdg-" t))
          (process-environment (cons (concat "XDG_RUNTIME_DIR=" tmp) process-environment)))
     (unwind-protect (progn ,@body)
       (when (process-live-p rdev--relay-server) (delete-process rdev--relay-server))
       (setq rdev--relay-server nil)
       (delete-directory tmp t))))

(ert-deftest rdev-relay-dir-is-private ()
  (rdev-relay-test--with-runtime-dir
   (let ((dir (rdev--relay-dir)))
     (should (string-prefix-p tmp dir))
     (should (= (logand (file-modes dir) #o777) #o700)))))

(ert-deftest rdev-relay-dir-tightens-loose-mode ()
  (rdev-relay-test--with-runtime-dir
   (let ((dir (expand-file-name "rdev" tmp)))
     (make-directory dir)
     (set-file-modes dir #o755)
     (rdev--relay-dir)
     (should (= (logand (file-modes dir) #o777) #o700)))))

(ert-deftest rdev-relay-socket-is-0600 ()
  (rdev-relay-test--with-runtime-dir
   (rdev--ensure-relay-server)
   (let ((path (rdev--relay-socket)))
     (should (file-exists-p path))
     (should (= (logand (file-modes path) #o777) #o600)))))

;;; T065: per-session relay token (Emacs cannot read SO_PEERCRED on an accepted socket)

(defun rdev-relay-test--hello (payload)
  "Feed an H frame with PAYLOAD to a fake relay socket; return (SOCK-LIVE . SPAWNED)."
  (let* ((sock (make-process :name "rdev-tok-sock" :command '("cat")
                             :connection-type 'pipe :noquery t :coding 'binary))
         (chan (rdev--make-chan :id 4242 :host "tokhost" :cmd '("true")))
         spawned)
    (unwind-protect
        (cl-letf (((symbol-function 'rdev--chan-find-id) (lambda (_id) chan))
                  ((symbol-function 'rdev--spawn) (lambda (&rest _) (setq spawned t))))
          (rdev--relay-filter sock (concat "H" (rdev--u32 (length payload)) payload))
          (cons (and (process-live-p sock) t) spawned))
      (when (process-live-p sock) (delete-process sock)))))

(ert-deftest rdev-relay-token-is-random-hex-and-stable ()
  (let ((rdev--relay-token nil))
    (let ((a (rdev--relay-token)))
      (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" a))
      (should (equal a (rdev--relay-token)))
      (setq rdev--relay-token nil)
      (should-not (equal a (rdev--relay-token))))))

(ert-deftest rdev-relay-hello-without-token-is-refused ()
  "A peer that reaches the socket but lacks the token never gets a channel."
  (let ((rdev--relay-token "goodtoken"))
    (should (equal '(nil . nil) (rdev-relay-test--hello "4242 24 80")))))

(ert-deftest rdev-relay-hello-with-wrong-token-is-refused ()
  (let ((rdev--relay-token "goodtoken"))
    (should (equal '(nil . nil) (rdev-relay-test--hello "4242 24 80 badtoken")))))

(ert-deftest rdev-relay-hello-with-right-token-is-accepted ()
  (let ((rdev--relay-token "goodtoken"))
    (should (equal '(t . t) (rdev-relay-test--hello "4242 24 80 goodtoken")))))

(provide 'rdev-relay-security-test)
