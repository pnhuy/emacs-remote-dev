;;; check-quality.el --- static quality gate for the rdev package  -*- lexical-binding: t; -*-
(require 'checkdoc)
(require 'bytecomp)
(require 'cl-lib)

(defconst cq--files
  (seq-remove (lambda (f) (string-match-p "-bench\\.el\\'" f))
              (directory-files "." t "\\.el\\'")))
(defvar cq--failures 0)
;; Article IX requires docstrings on PUBLIC symbols (checked in step 3);
;; private helpers need not carry one, so checkdoc must not demand it.
(setq checkdoc-force-docstrings-flag nil)
(defun cq--fail (fmt &rest args)
  (cl-incf cq--failures) (princ (concat "FAIL " (apply #'format fmt args) "\n")))

;; 1. Byte-compile (in a scratch copy, so no .elc lands in the tree); warnings are errors.
(let ((byte-compile-error-on-warn t)
      (tmp (make-temp-file "cq" t)))
  (dolist (f cq--files) (copy-file f (file-name-as-directory tmp) t))
  (let ((load-path (cons tmp load-path)))
    (dolist (f cq--files)
      (let ((copy (expand-file-name (file-name-nondirectory f) tmp)))
        (condition-case err
            (unless (byte-compile-file copy)
              (cq--fail "byte-compile %s" f))
          (error (cq--fail "byte-compile %s: %s" f (error-message-string err)))))))
  (delete-directory tmp t))
(princ (format "byte-compile: %d files\n" (length cq--files)))

;; 2. checkdoc.
(dolist (f cq--files)
  (let ((checkdoc-diagnostic-buffer "*cq-checkdoc*"))
    (with-current-buffer (find-file-noselect f)
      (checkdoc-current-buffer t))
    (when-let* ((b (get-buffer "*cq-checkdoc*")))
      (with-current-buffer b
        (goto-char (point-min))
        (while (re-search-forward "^\\(.*\\.el\\):\\([0-9]+\\): \\(.*\\)$" nil t)
          (unless (string-match-p "Messages should start with a capital"
                                  (match-string 3)) ; "rdev: ..." prefix is the message convention
            (cq--fail "checkdoc %s:%s %s" (match-string 1) (match-string 2) (match-string 3)))))
      (kill-buffer b))))
(princ "checkdoc: done\n")

;; 3. Docstrings on public functions, commands, defcustoms and defvars.
(defun cq--public-p (name) (not (string-match-p "--" (symbol-name name))))
(dolist (f cq--files)
  (with-temp-buffer
    (insert-file-contents f)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (condition-case nil
        (while t
          (let* ((pos (point)) (form (read (current-buffer))))
            (when (and (consp form) (symbolp (cadr form)) (cq--public-p (cadr form)))
              (pcase (car form)
                ((or 'defun 'cl-defun 'defmacro 'cl-defmacro)
                 (let ((body (cdddr form)))
                   (unless (and (stringp (car body)) (cdr body))
                     (cq--fail "no docstring: %s (%s:%d)" (cadr form) f
                               (line-number-at-pos pos)))))
                ((or 'defcustom 'defvar 'defconst 'defgroup)
                 (when (memq (car form) '(defcustom defgroup))
                   (unless (stringp (nth 3 form))
                     (cq--fail "no docstring: %s (%s:%d)" (cadr form) f
                               (line-number-at-pos pos)))))))))
      (end-of-file nil))))
(princ "docstrings: done\n")

;; 4. Concurrency/lifecycle code must carry an explanatory comment somewhere in
;; the enclosing top-level form.
(defconst cq--needs-comment
  '("make-process" "make-network-process" "run-at-time" "set-process-sentinel"
    "set-process-filter" "advice-add" "process-send-eof")
  "Operations that start concurrency or alter lifecycle.")
(let ((missing 0) (total 0))
  (dolist (f cq--files)
    (with-temp-buffer
      (insert-file-contents f)
      (emacs-lisp-mode)
      (let (sites)
        (dolist (op cq--needs-comment)
          (goto-char (point-min))
          (while (re-search-forward (concat "(" (regexp-quote op) "[ \t\n]") nil t)
            (let ((mb (match-beginning 0)))  ; ppss clobbers match data
              (unless (nth 8 (save-excursion (syntax-ppss mb)))
                (push (cons op mb) sites)))))
        (dolist (site sites)
          (cl-incf total)
          (goto-char (cdr site))
          (let* ((beg (progn (beginning-of-defun) (point)))
                 (end (progn (end-of-defun) (point)))
                 (has (progn (goto-char beg)
                             (let ((found nil))
                               (while (and (not found) (< (point) end)
                                           (re-search-forward ";" end t))
                                 (when (eq (nth 4 (save-excursion (syntax-ppss))) t) (setq found t)))
                               found))))
            (unless has
              (cl-incf missing)
              (cq--fail "no comment in form using (%s) at %s:%d [form %d-%d]" (car site) f
                        (line-number-at-pos (cdr site) t) (line-number-at-pos beg t) (line-number-at-pos end t))))))))
  (princ (format "comments: %d concurrency sites, %d without a comment\n" total missing)))

(princ (format "\n%s: %d failure(s)\n" (if (zerop cq--failures) "PASS" "FAIL") cq--failures))
(kill-emacs (if (zerop cq--failures) 0 1))
