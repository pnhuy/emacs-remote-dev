;;; dired.el --- E2E Dired over real ssh (T118, FR-026)  -*- lexical-binding: t; -*-
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'dired)
(require 'dired-aux)
(require 'dired-x)

(defun e2e-dd--populate (dir)
  "Create the same small tree under DIR (local or remote)."
  (make-directory (expand-file-name "sub" dir) t)
  (write-region "aaa\n" nil (expand-file-name "a.txt" dir) nil 'silent)
  (write-region "bbbbbbbbbb\n" nil (expand-file-name "b.txt" dir) nil 'silent)
  (write-region "c\n" nil (expand-file-name "c.log" dir) nil 'silent)
  (write-region "nested\n" nil (expand-file-name "sub/n.txt" dir) nil 'silent))

(defun e2e-dd--names (buf)
  "File names (non-dot) listed in Dired BUF, in buffer order."
  (with-current-buffer buf
    (let (r)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((f (dired-get-filename 'no-dir t)))
            (unless (member f '("." "..")) (push f r)))
          (forward-line 1)))
      (nreverse r))))

(defun e2e-dd--goto (buf name)
  (with-current-buffer buf
    (goto-char (point-min))
    (unless (dired-goto-file (expand-file-name name default-directory))
      (error "no %s in dired" name))))

(defmacro e2e-dd--with (&rest body)
  `(e2e-with-dir
     (e2e-dd--populate e2e--dir)
     (let ((dired-listing-switches "-al") (dired-dwim-target nil)
           (dired-kill-when-opening-new-dired-buffer nil))
       (save-window-excursion ,@body))))

(ert-deftest e2e-dired-listing-matches-native ()
  (e2e-dd--with
    (let ((native (file-name-as-directory (make-temp-file "e2e-native" t))))
      (unwind-protect
          (progn
            (e2e-dd--populate native)
            (let ((r (dired-noselect e2e--dir)) (n (dired-noselect native)))
              (should (equal (e2e-dd--names r) (e2e-dd--names n)))
              (should (equal '("a.txt" "b.txt" "c.log" "sub") (e2e-dd--names r)))
              (kill-buffer r) (kill-buffer n)))
        (delete-directory native t)))))

(ert-deftest e2e-dired-sort-by-size-and-name ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir "-al")))
      (with-current-buffer buf
        (setq dired-actual-switches "-alS")
        (revert-buffer)
        (let ((names (e2e-dd--names buf)))
          ;; b.txt (11 bytes) is the biggest regular file; directories sort by their own size.
          (should (< (cl-position "b.txt" names :test #'equal)
                     (cl-position "a.txt" names :test #'equal)))))
      (with-current-buffer buf
        (setq dired-actual-switches "-al")
        (revert-buffer))
      (should (equal '("a.txt" "b.txt" "c.log" "sub") (e2e-dd--names buf)))
      (kill-buffer buf))))

(ert-deftest e2e-dired-mark-by-regexp-and-delete ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (with-current-buffer buf
        (dired-mark-files-regexp "\\.txt\\'")
        (should (= 2 (length (dired-get-marked-files))))
        (let ((dired-recursive-deletes 'always))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
            (dired-do-delete)))
        (should (equal '("c.log" "sub") (e2e-dd--names buf))))
      (should-not (file-exists-p (concat e2e--dir "a.txt")))
      (should (file-exists-p (concat e2e--dir "c.log")))
      (kill-buffer buf))))

(ert-deftest e2e-dired-copy-and-rename ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (e2e-dd--goto buf "a.txt")
      (with-current-buffer buf
        (dired-copy-file (concat e2e--dir "a.txt") (concat e2e--dir "a-copy.txt") nil)
        (revert-buffer))
      (should (equal "aaa\n" (with-temp-buffer
                                (insert-file-contents (concat e2e--dir "a-copy.txt"))
                                (buffer-string))))
      (with-current-buffer buf
        (dired-rename-file (concat e2e--dir "b.txt") (concat e2e--dir "sub/b2.txt") nil)
        (revert-buffer))
      (should-not (file-exists-p (concat e2e--dir "b.txt")))
      (should (file-exists-p (concat e2e--dir "sub/b2.txt")))
      (should (member "a-copy.txt" (e2e-dd--names buf)))
      (kill-buffer buf))))

(ert-deftest e2e-dired-copy-across-local-and-remote ()
  (e2e-dd--with
    (let ((local (make-temp-file "e2e-loc" t)))
      (unwind-protect
          (let ((buf (dired-noselect e2e--dir)))
            (dired-copy-file (concat e2e--dir "a.txt") (expand-file-name "got.txt" local) nil)
            (should (equal "aaa\n" (with-temp-buffer
                                     (insert-file-contents (expand-file-name "got.txt" local))
                                     (buffer-string))))
            (write-region "up\n" nil (expand-file-name "up.txt" local) nil 'silent)
            (dired-copy-file (expand-file-name "up.txt" local) (concat e2e--dir "up.txt") nil)
            (should (file-exists-p (concat e2e--dir "up.txt")))
            (kill-buffer buf))
        (delete-directory local t)))))

(ert-deftest e2e-dired-find-file-opens-remote-buffer ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (e2e-dd--goto buf "a.txt")
      (with-current-buffer buf
        (let ((fb (find-file-noselect (dired-get-file-for-visit))))
          (with-current-buffer fb
            (should (equal (buffer-file-name) (concat e2e--dir "a.txt")))
            (should (equal "aaa\n" (buffer-string))))
          (kill-buffer fb)))
      (e2e-dd--goto buf "sub")
      (with-current-buffer buf
        (let ((sub (dired-noselect (dired-get-file-for-visit))))
          (should (equal '("n.txt") (e2e-dd--names sub)))
          (kill-buffer sub)))
      (kill-buffer buf))))

(ert-deftest e2e-dired-do-shell-command-runs-remotely ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (e2e-dd--goto buf "b.txt")
      (with-current-buffer buf
        (let ((display-buffer-overriding-action '(display-buffer-no-window)))
          (dired-do-shell-command "wc -c" nil (list "b.txt")))
        (let ((out (get-buffer "*Shell Command Output*")))
          (should out)
          (should (string-match-p "11" (with-current-buffer out (buffer-string))))))
      (kill-buffer buf))))

(ert-deftest e2e-dired-revert-sees-external-change ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (should-not (member "new.txt" (e2e-dd--names buf)))
      (let ((default-directory e2e--dir))
        (process-file "sh" nil nil nil "-c" "echo hi > new.txt; rm c.log"))
      (with-current-buffer buf (revert-buffer))
      (let ((names (e2e-dd--names buf)))
        (should (member "new.txt" names))
        (should-not (member "c.log" names)))
      (kill-buffer buf))))

(ert-deftest e2e-dired-create-directory-and-symlink-display ()
  (e2e-dd--with
    (let ((buf (dired-noselect e2e--dir)))
      (with-current-buffer buf
        (dired-create-directory (concat e2e--dir "newdir"))
        (make-symbolic-link "a.txt" (concat e2e--dir "lnk") t)
        (revert-buffer))
      (should (member "newdir" (e2e-dd--names buf)))
      (with-current-buffer buf
        (goto-char (point-min))
        (should (re-search-forward "lnk -> a\\.txt" nil t)))
      (kill-buffer buf))))
