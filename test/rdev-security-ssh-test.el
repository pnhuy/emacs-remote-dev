;;; rdev-security-ssh-test.el --- ssh transport security (T059, D-01, FR-033)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defmacro rdev-secssh--with-fake-ssh (record-file &rest body)
  "Run BODY with a fake `ssh' first on PATH that appends its argv (NUL-separated) to RECORD-FILE and exits 255."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "rdev-secssh" t))
          (ssh (expand-file-name "ssh" dir))
          (,record-file (expand-file-name "argv" dir)))
     (unwind-protect
         (progn
           (with-temp-file ssh
             (insert (format "#!/bin/sh\nfor a in \"$@\"; do printf '%%s\\n' \"$a\"; done >> %s\nprintf -- '---\\n' >> %s\nexit 255\n"
                             ,record-file ,record-file)))
           (set-file-modes ssh #o755)
           (let ((exec-path (cons dir exec-path))
                 (process-environment (cons (concat "PATH=" dir ":" (getenv "PATH")) process-environment))
                 (rdev-hosts nil) (rdev-timeout 5))
             ,@body))
       (delete-directory dir t))))

(defun rdev-secssh--argv (file)
  (and (file-exists-p file)
       (with-temp-buffer (insert-file-contents file) (split-string (buffer-string) "\n" t))))

(ert-deftest rdev-secssh-dash-host-rejected-and-never-spawned ()
  (rdev-secssh--with-fake-ssh rec
    (dolist (h '("-oProxyCommand=id" "-F/etc/passwd" "" "a b" "x;y" "a\nb" "$(id)" "`id`"))
      (should-error (rdev--connect h) :type 'user-error))
    (should-not (file-exists-p rec))))

(ert-deftest rdev-secssh-path-form-never-spawns ()
  (rdev-secssh--with-fake-ssh rec
    (should-error (insert-file-contents "/rdev:-oProxyCommand=id:/p") :type 'user-error)
    (should-not (file-exists-p rec))))

(ert-deftest rdev-secssh-double-dash-precedes-host ()
  (rdev-secssh--with-fake-ssh rec
    (ignore-errors (rdev--connect "goodhost"))
    (let* ((argv (rdev-secssh--argv rec))
           (dd (cl-position "--" argv :test #'equal))
           (h (cl-position "goodhost" argv :test #'equal)))
      (should dd) (should h) (should (= h (1+ dd)))
      (should (member "BatchMode=yes" argv)))))

(ert-deftest rdev-secssh-valid-hosts-accepted ()
  (dolist (h '("host" "user@host" "my-host.example.com" "10.0.0.1" "h_1" "[::1]x"))
    (if (string-match-p "\\[" h)
        (should-error (rdev--validate-host h) :type 'user-error)
      (should (equal h (rdev--validate-host h))))))

(ert-deftest rdev-secssh-no-password-or-key-material-handling ()
  "Static check (FR-033): rdev never reads, stores or persists passwords/passphrases/keys."
  (let ((src (with-temp-buffer (insert-file-contents (expand-file-name "rdev.el" rdev-test--root)) (buffer-string))))
    (dolist (re '("read-passwd" "auth-source" "password-cache" "ssh-add" "\\.ssh/id_"
                  "passphrase" "SSH_ASKPASS" "ssh-keygen" "-i[ \"]+[^ ]*id_"))
      (should-not (let ((case-fold-search t)) (string-match-p re src))))))

(provide 'rdev-security-ssh-test)
