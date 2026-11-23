;;; edge-cases.el --- E2E edge cases (T123)  -*- lexical-binding: t; -*-
;; 1. two Emacs sessions editing one file: the second save conflicts
;; 2. one host via two ssh aliases shares a connection and cache identity
;; 3. non-UTF-8 / mixed-coding files round-trip byte-exact
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defconst e2e-ec--dir-of-tests
  (file-name-directory (or load-file-name buffer-file-name)))

(defun e2e-ec--bytes (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion)) (insert-file-contents-literally file))
    (buffer-string)))

(defun e2e-ec--write-bytes (file bytes)
  (with-temp-buffer
    (set-buffer-multibyte nil) (insert bytes)
    (let ((coding-system-for-write 'no-conversion)) (write-region nil nil file nil 'silent))))

;;;; 1. Two sessions

(defun e2e-ec--other-session (file text)
  "Run a second Emacs process that overwrites FILE with TEXT via rdev."
  (let* ((lib (file-name-directory (locate-library "rdev")))
         (tests e2e-ec--dir-of-tests)
         (ert-dir (expand-file-name ".." tests)))
    (with-temp-buffer
      (let ((st (call-process (concat invocation-directory invocation-name) nil t nil
                              "-Q" "--batch" "-L" lib "-L" ert-dir "-l" "ert"
                              "-l" (expand-file-name "baseline.el" tests)
                              "--eval" (format "(write-region %S nil %S nil 'silent)" text file))))
        (unless (eql st 0) (error "second session failed (%s): %s" st (buffer-string)))))))

(ert-deftest e2e-edge-two-sessions-second-save-conflicts ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "shared.txt")) (make-backup-files nil))
      (write-region "base\n" nil f nil 'silent)
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-max)) (insert "mine\n")
        (sleep-for 1.1)                 ; distinct mtime on coarse filesystems
        (e2e-ec--other-session f "theirs\n")
        (cl-letf (((symbol-function 'ask-user-about-supersession-threat) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (should-error (save-buffer)))
        ;; The other session's content was not overwritten; our edit is kept locally.
        (should (equal "theirs\n" (with-temp-buffer (insert-file-contents f) (buffer-string))))
        (should (buffer-modified-p))
        (should (equal "base\nmine\n" (buffer-string)))
        (set-buffer-modified-p nil)
        (kill-buffer (current-buffer))))))

;;;; 2. Two aliases, one connection

(defun e2e-ec--alias-config (alias)
  "Write an ssh config defining ALIAS as another name for `e2e-host'."
  (let* ((fixture (getenv "RDEV_TEST_SSH_CONFIG"))
         ;; The fixture host exists only in its own config file, so resolve it with -F.
         (g (with-temp-buffer (apply #'call-process "ssh" nil '(t nil) nil
                                     (append (and fixture (list "-F" fixture))
                                             (list "-G" "--" e2e-host)))
                              (buffer-string)))
         (field (lambda (k) (and (string-match (format "^%s \\(.+\\)$" k) g)
                                 (match-string 1 g))))
         (orig (or (getenv "RDEV_TEST_SSH_CONFIG") (expand-file-name "~/.ssh/config")))
         (file (make-temp-file "rdev-alias" nil ".conf")))
    (with-temp-file file
      ;; Includes go first: after a Host line they would be scoped to it.
      ;; -F makes ssh ignore the system-wide config, so include both.
      (dolist (c (list orig "/etc/ssh/ssh_config"))
        (when (file-readable-p c) (insert (format "Include %s\n" c))))
      (insert (format "\nHost %s\n  HostName %s\n  User %s\n  Port %s\n"
                      alias (funcall field "hostname") (funcall field "user")
                      (funcall field "port"))))
    (set-file-modes file #o600)
    file))

(ert-deftest e2e-edge-two-aliases-share-connection-and-cache ()
  (let* ((alias (format "%s-alias%d" e2e-host (random 100000)))
         (cfg (e2e-ec--alias-config alias))
         (rdev-ssh-args (append (list "-F" cfg)
                                (let ((a rdev-ssh-args) out)
                                  (while a (if (equal (car a) "-F") (setq a (cddr a))
                                             (push (pop a) out)))
                                  (nreverse out)))))
    (unwind-protect
        (progn
          (rdev-state-forget-keys)
          (should (equal (rdev-state-session-key e2e-host)
                         (rdev-state-session-key alias)))
          (let ((c1 (rdev--conn e2e-host)) (c2 (rdev--conn alias)))
            (should (rdev-conn-p c1))
            ;; One process behind both names.
            (should (eq (jsonrpc--process (rdev-conn-rpc c1))
                        (jsonrpc--process (rdev-conn-rpc c2)))))
          (e2e-with-dir
            (let* ((f (concat e2e--dir "alias.txt"))
                   (g (concat (format "/rdev:%s:" alias) (file-local-name f))))
              (write-region "via-main\n" nil f nil 'silent)
              (should (equal "via-main\n" (with-temp-buffer (insert-file-contents g) (buffer-string))))
              ;; A write through one name is visible through the other (shared cache identity).
              (write-region "via-alias\n" nil g nil 'silent)
              (should (equal "via-alias\n" (with-temp-buffer (insert-file-contents f) (buffer-string)))))))
      (delete-file cfg))))

;;;; 3. Encodings

(ert-deftest e2e-edge-latin1-roundtrip-byte-exact ()
  (e2e-with-dir
    (let* ((f (concat e2e--dir "latin1.txt")) (make-backup-files nil)
           (orig (encode-coding-string "café naïve\nsecond line\n" 'iso-latin-1)))
      (e2e-ec--write-bytes f orig)
      ;; Untouched visit+save is a byte-exact no-op.
      (with-current-buffer (find-file-noselect f)
        (set-buffer-modified-p t) (save-buffer) (kill-buffer))
      (should (equal orig (e2e-ec--bytes f)))
      ;; An edit changes only the edited text; the rest keeps its encoding.
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-min)) (insert "X")
        (save-buffer) (kill-buffer))
      (should (equal (concat "X" orig) (e2e-ec--bytes f))))))

(ert-deftest e2e-edge-mixed-coding-roundtrip-byte-exact ()
  "Valid UTF-8 text plus a stray Latin-1 byte and a NUL survive visit/edit/save."
  (e2e-with-dir
    (let* ((f (concat e2e--dir "mixed.txt")) (make-backup-files nil)
           (orig (concat (encode-coding-string "héllo ✓\n" 'utf-8)
                         (unibyte-string #xE9 #x20 #xFF 0 ?\n)
                         (encode-coding-string "endü\n" 'utf-8))))
      (e2e-ec--write-bytes f orig)
      (with-current-buffer (find-file-noselect f)
        (set-buffer-modified-p t) (save-buffer) (kill-buffer))
      (should (equal orig (e2e-ec--bytes f)))
      (with-current-buffer (find-file-noselect f)
        (goto-char (point-max)) (insert "tail\n")
        (save-buffer) (kill-buffer))
      (should (equal (concat orig "tail\n") (e2e-ec--bytes f))))))
