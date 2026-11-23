;;; save-conflict.el --- E2E concurrent external modification: 100% reported (T036, SC-003)  -*- lexical-binding: t; -*-
;; RDEV_CONFLICT_TRIALS (default 100) trials, spread over five ways an outside process can
;; change a file while a buffer visiting it has unsaved edits.  In every trial the save must
;; signal `rdev-conflict', the remote file must keep the outside change (never overwritten),
;; and the local edit must remain in the (still modified) buffer.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defconst e2e-sc--modes
  '((append  . "printf 'extra\\n' >> %s")
    (replace . "printf 'replaced!!\\n' > %s")                 ; truncate + write
    (rename  . "printf 'new inode\\n' > %s.n && mv %s.n %s")  ; atomic replace: new inode
    (same-size . "printf 'ORIGINAL\\n' > %s")                 ; same length as the original
    (touch   . "touch -d '2031-01-02 03:04:05' %s")))         ; metadata only

(defun e2e-sc--external (mode file)
  (let* ((default-directory (file-name-directory file))
         (l (shell-quote-argument (file-local-name file)))
         (cmd (replace-regexp-in-string "%s" l (cdr (assq mode e2e-sc--modes)) t t)))
    ;; Let the mtime tick so that a same-second change is still a different version.
    (should (= 0 (process-file "sh" nil nil nil "-c" (concat "sleep 0.02; " cmd))))))

(defun e2e-sc--remote (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest e2e-save-conflict-always-reported ()
  (let* ((trials (string-to-number (or (getenv "RDEV_CONFLICT_TRIALS") "100")))
         (modes (mapcar #'car e2e-sc--modes))
         (reported 0) (missed nil) (overwritten nil) (lost nil))
    (e2e-with-dir
      (cl-letf (((symbol-function 'ask-user-about-supersession-threat) (lambda (_) nil))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (dotimes (i trials)
          (let* ((mode (nth (% i (length modes)) modes))
                 (f (format "%sc%03d.txt" e2e--dir i))
                 (make-backup-files nil) (rdev-conflict-functions nil)
                 (mine (format "my edit %d\n" i)))
            (write-region "ORIGINAL\n" nil f nil 'silent)
            (with-current-buffer (find-file-noselect f)
              (unwind-protect
                  (progn
                    (erase-buffer) (insert mine)
                    (e2e-sc--external mode f)
                    (let ((theirs (e2e-sc--remote f)))
                      (condition-case nil
                          (progn (save-buffer) (push (cons i mode) missed))
                        (rdev-conflict (cl-incf reported)))
                      ;; The outside change must survive, my edit must too.
                      (unless (equal theirs (e2e-sc--remote f)) (push (cons i mode) overwritten))
                      (unless (and (buffer-modified-p) (equal (buffer-string) mine))
                        (push (cons i mode) lost))))
                (set-buffer-modified-p nil) (kill-buffer)))))))
    (message "save-conflict: %d trials, %d reported, missed %S overwritten %S lost %S"
             trials reported missed overwritten lost)
    (should (= reported trials))
    (should-not missed)
    (should-not overwritten)
    (should-not lost)))
