;;; rdev-save-test.el --- versioned saves and conflicts (T034)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(setq make-backup-files nil)

(defun rdev-save--slurp (f)
  (with-temp-buffer (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion)) (insert-file-contents-literally f))
    (buffer-string)))

(defun rdev-save--external-edit (remote name text)
  "Change NAME in the served dir behind rdev's back."
  (let ((f (concat (file-local-name remote) name)))
    (sleep-for 0.02)
    (with-temp-file f (insert text))))

(ert-deftest rdev-save-version-recorded-at-visit ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (progn (should rdev--version)
                 (should (plist-get rdev--version :size))
                 (should (plist-get rdev--version :ino)))
        (set-buffer-modified-p nil) (kill-buffer)))))

(ert-deftest rdev-save-plain-save-uses-atomic-and-updates-version ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (let ((old rdev--version))
            (erase-buffer) (insert "saved once")
            (save-buffer)
            (should (equal (rdev-save--slurp (concat (file-local-name remote) "a.txt"))
                           "saved once\n"))
            (should-not (equal old rdev--version))
            (should (= (plist-get rdev--version :size) 11))
            ;; second save with the refreshed version must not conflict
            (insert "!") (save-buffer)
            (should (equal (rdev-save--slurp (concat (file-local-name remote) "a.txt"))
                           "saved once!\n")))
        (set-buffer-modified-p nil) (kill-buffer)))))

(ert-deftest rdev-save-conflict-refused-without-resolution ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (let ((rdev-conflict-functions nil))
            (rdev-save--external-edit remote "a.txt" "external, longer content")
            (erase-buffer) (insert "mine")
            (should-error (save-buffer) :type 'rdev-conflict)
            (should (buffer-modified-p))
            (should (equal (rdev-save--slurp (concat (file-local-name remote) "a.txt"))
                           "external, longer content")))
        (set-buffer-modified-p nil) (kill-buffer)))))

(ert-deftest rdev-save-conflict-abort-and-overwrite-decisions ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (progn
            (rdev-save--external-edit remote "a.txt" "external, longer content")
            (erase-buffer) (insert "mine")
            (let ((rdev-conflict-functions (list (lambda (_f) 'abort))))
              (should-error (save-buffer) :type 'rdev-conflict))
            (should (equal (rdev-save--slurp (concat (file-local-name remote) "a.txt"))
                           "external, longer content"))
            (let ((rdev-conflict-functions (list (lambda (_f) 'overwrite))))
              (save-buffer))
            (should (equal (rdev-save--slurp (concat (file-local-name remote) "a.txt")) "mine\n"))
            (should-not (buffer-modified-p)))
        (set-buffer-modified-p nil) (kill-buffer)))))

(ert-deftest rdev-save-conflict-when-deleted-externally ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (let ((rdev-conflict-functions nil))
            (delete-file (concat (file-local-name remote) "a.txt"))
            (erase-buffer) (insert "mine")
            (should-error (save-buffer) :type 'rdev-conflict)
            (should-not (file-exists-p (concat (file-local-name remote) "a.txt"))))
        (set-buffer-modified-p nil) (kill-buffer)))))

(ert-deftest rdev-save-first-save-with-rename-backup-is-not-a-conflict ()
  "Emacs's default backup renames the visited file away before writing.
That rename is this Emacs's own doing, so the save must not report the
remote file as changed (as plain `emacs -Q' would otherwise do)."
  (rdev-test-with-twin-dir (native remote)
    (let ((local (concat (file-local-name remote) "a.txt"))
          (before nil))
      (setq before (rdev-save--slurp local))
      (with-current-buffer (find-file-noselect (concat remote "a.txt"))
        (unwind-protect
            (let ((make-backup-files t) (backup-inhibited nil)
                  (backup-by-copying nil) (backup-by-copying-when-linked nil)
                  (backup-by-copying-when-mismatch nil)
                  (backup-directory-alist nil) (version-control nil)
                  (rdev-conflict-functions nil))
              (setq buffer-backed-up nil)
              (erase-buffer) (insert "after backup")
              (save-buffer)
              (should (equal (rdev-save--slurp local) "after backup\n"))
              (should (equal (rdev-save--slurp (concat local "~")) before))
              (should-not (buffer-modified-p))
              ;; the version was refreshed, so later saves still send it and
              ;; still detect external changes
              (should (equal (plist-get rdev--version :size) 13)))
          (set-buffer-modified-p nil) (kill-buffer))))))

(ert-deftest rdev-save-append-stays-non-atomic ()
  (rdev-test-with-twin-dir (native remote)
    (let (methods)
      (advice-add 'rdev--req :before (lambda (_h m &rest _) (push m methods))
                  '((name . rdev-save-spy)))
      (unwind-protect
          (with-temp-buffer
            (insert "tail")
            (write-region (point-min) (point-max) (concat remote "a.txt") t 'silent))
        (advice-remove 'rdev--req 'rdev-save-spy))
      (should (memq :fs/write methods))
      (should-not (memq :fs/writeAtomic methods)))))

(ert-deftest rdev-save-legacy-agent-falls-back-with-message ()
  (rdev-test-with-twin-dir (native remote)
    (let* ((host (rdev--host remote)) (c (rdev--conn host)) msgs)
      (let ((saved (rdev-conn-caps c)))
        (setf (rdev-conn-caps c) nil)
        (unwind-protect
            (cl-letf (((symbol-function 'message)
                       (lambda (f &rest a) (push (apply #'format f a) msgs))))
              (with-temp-buffer
                (insert "legacy")
                (write-region (point-min) (point-max) (concat remote "n.txt") nil 'silent))
              (should (equal (rdev-save--slurp (concat (file-local-name remote) "n.txt")) "legacy"))
              (should (cl-some (lambda (m) (string-match-p "lacks fs.writeAtomic" m)) msgs)))
          (setf (rdev-conn-caps c) saved))))))

(ert-deftest rdev-save-new-file-and-binary-bytes ()
  (rdev-test-with-twin-dir (native remote)
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert (apply #'unibyte-string (number-sequence 0 255)))
        (write-region (point-min) (point-max) (concat remote "new.bin") nil 'silent)))
    (should (= 256 (length (rdev-save--slurp (concat (file-local-name remote) "new.bin")))))))

(provide 'rdev-save-test)
;;; rdev-save-test.el ends here
