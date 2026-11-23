;;; compile.el --- E2E compile/recompile on remote dirs (T083, FR-026)  -*- lexical-binding: t; -*-
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'compile)
(require 'ansi-color)

(defun e2e-cc--run (cmd dir &optional secs)
  "Run compile CMD in DIR, wait for it to finish, return the buffer."
  (let* ((default-directory dir)
         (display-buffer-overriding-action '(display-buffer-no-window))
         (buf (save-window-excursion (compile cmd)))
         (proc (get-buffer-process buf))
         (deadline (+ (float-time) (or secs 30))))
    (while (and proc (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.1))
    (accept-process-output nil 0.3)
    buf))

(defmacro e2e-cc--with (&rest body)
  `(e2e-with-dir
     (let ((compilation-ask-about-save nil) (compilation-save-buffers-predicate #'ignore)
           (compilation-scroll-output nil))
       ,@body)))

(ert-deftest e2e-compile-streams-output-and-reports-success ()
  (e2e-cc--with
    (let ((buf (e2e-cc--run "echo one; echo two" e2e--dir)))
      (with-current-buffer buf
        (should (string-match-p "one\ntwo\n" (buffer-string)))
        (should (string-match-p "finished" (buffer-string)))
        (should (equal default-directory e2e--dir))))))

(ert-deftest e2e-compile-runs-on-remote-host ()
  (e2e-cc--with
    (let ((buf (e2e-cc--run "pwd" e2e--dir)))
      (with-current-buffer buf
        (should (string-match-p (regexp-quote (file-local-name e2e--dir))
                                (buffer-string)))))))

(ert-deftest e2e-compile-reports-exit-status ()
  (e2e-cc--with
    (let ((buf (e2e-cc--run "echo bad; exit 3" e2e--dir)))
      (with-current-buffer buf
        (should (string-match-p "exited abnormally with code 3" (buffer-string)))))))

(ert-deftest e2e-compile-streams-incrementally ()
  (e2e-cc--with
    (let* ((default-directory e2e--dir)
           (display-buffer-overriding-action '(display-buffer-no-window))
           (buf (save-window-excursion (compile "echo A$((1+1)); sleep 3; echo B$((1+1))")))
           (proc (get-buffer-process buf))
           (deadline (+ (float-time) 2.5)))
      (while (and (< (float-time) deadline)
                  (not (with-current-buffer buf (string-match-p "A2" (buffer-string)))))
        (accept-process-output proc 0.1))
      ;; "A2" is visible while the command is still running.
      (should (process-live-p proc))
      (should (with-current-buffer buf (string-match-p "A2" (buffer-string))))
      (should-not (with-current-buffer buf (string-match-p "B2" (buffer-string))))
      (while (process-live-p proc) (accept-process-output proc 0.1)))))

(ert-deftest e2e-compile-next-error-visits-remote-file ()
  (e2e-cc--with
    (let ((f (concat e2e--dir "src.c")))
      (write-region "line1\nline2\nline3\n" nil f nil 'silent)
      (let ((buf (e2e-cc--run "echo 'src.c:2:5: error: boom'; exit 1" e2e--dir)))
        (with-current-buffer buf
          (goto-char (point-min))
          (let ((next-error-last-buffer buf))
            (save-window-excursion (next-error))
            (let ((b (get-file-buffer f)))
              (should b)
              (with-current-buffer b
                (should (equal (buffer-file-name) f))
                (should (= 2 (line-number-at-pos)))
                (should (= 4 (current-column))))
              (kill-buffer b))))))))

(ert-deftest e2e-recompile-reruns-in-same-remote-directory ()
  (e2e-cc--with
    (let ((buf (e2e-cc--run "echo run-$$" e2e--dir)))
      (let ((first (with-current-buffer buf (buffer-string))))
        (with-current-buffer buf
          (let ((default-directory temporary-file-directory)
                (display-buffer-overriding-action '(display-buffer-no-window)))
            (save-window-excursion (recompile))))
        (let ((proc (get-buffer-process buf)) (d (+ (float-time) 20)))
          (while (and proc (process-live-p proc) (< (float-time) d))
            (accept-process-output proc 0.1))
          (accept-process-output nil 0.3))
        (with-current-buffer buf
          (should (equal default-directory e2e--dir))
          (should (string-match-p "run-[0-9]+" (buffer-string)))
          (should-not (equal first "")))))))

(ert-deftest e2e-compile-kill-stops-remote-process ()
  (e2e-cc--with
    (let* ((marker (concat e2e--dir "marker"))
           (default-directory e2e--dir)
           (display-buffer-overriding-action '(display-buffer-no-window))
           (buf (save-window-excursion
                  (compile (format "echo started; sleep 31; touch %s" (file-local-name marker)))))
           (proc (get-buffer-process buf)))
      (while (not (with-current-buffer buf (string-match-p "started" (buffer-string))))
        (accept-process-output proc 0.1))
      (with-current-buffer buf (kill-compilation))
      (let ((d (+ (float-time) 10)))
        (while (and (process-live-p proc) (< (float-time) d))
          (accept-process-output proc 0.1)))
      (should-not (process-live-p proc))
      ;; The remote command is gone, not merely detached.
      (sleep-for 1)
      (should-not (file-exists-p marker))
      (let ((default-directory e2e--dir))
        (should (equal "0" (string-trim
                            (with-output-to-string
                              (with-current-buffer standard-output
                                (process-file "sh" nil t nil "-c"
                                              "pgrep -f '[s]leep 31' >/dev/null && echo 1 || echo 0"))))))))))

(ert-deftest e2e-compile-ansi-colors-are-interpreted ()
  (e2e-cc--with
    (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)
    (unwind-protect
        (let ((buf (e2e-cc--run "printf '\\033[31mred\\033[0m plain\\n'" e2e--dir)))
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "red plain" nil t))
            (should-not (string-match-p "\e\\[" (buffer-string)))
            ;; Depending on the Emacs version the colour is a text property or an overlay.
            (should (or (get-text-property (match-beginning 0) 'face)
                        (get-text-property (match-beginning 0) 'font-lock-face)
                        (cl-some (lambda (o) (overlay-get o 'face))
                                 (overlays-at (match-beginning 0)))))))
      (remove-hook 'compilation-filter-hook #'ansi-color-compilation-filter))))
