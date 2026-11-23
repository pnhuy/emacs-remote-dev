;;; rdev-shell-test.el --- shell-command shim, shell and comint (T082)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'comint)
(require 'shell)

(defun rdev-shell-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest rdev-shell-command-sync-runs-in-remote-dir ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory (concat remote "sub/")))
      (with-temp-buffer
        (shell-command "pwd" (current-buffer))
        (should (string-suffix-p "/sub\n" (buffer-string))))
      (should (equal "a b\n"
                     (with-temp-buffer
                       (shell-command "echo 'a b'" (current-buffer))
                       (buffer-string))))
      (should (equal "x y\n" (shell-command-to-string "echo x y"))))))

(ert-deftest rdev-shell-command-sync-keeps-shell-semantics ()
  "Compound commands run through a shell on the agent side."
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (should (equal "7\n" (shell-command-to-string "sh -c 'exit 7'; echo $?"))))))

(ert-deftest rdev-shell-command-reports-exit-status ()
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory remote))
      (should (= 3 (shell-command "exit 3")))
      (should (= 0 (shell-command "true"))))))

(ert-deftest rdev-shell-async-shell-command-streams-output ()
  (rdev-test-with-twin-dir (native remote)
    (let* ((default-directory remote)
           (buf (generate-new-buffer " *rdev-async*"))
           (display-buffer-overriding-action '(display-buffer-no-window))
           (async-shell-command-display-buffer nil))
      (unwind-protect
          (progn
            (async-shell-command "echo one; echo two" buf)
            (let ((proc (get-buffer-process buf)))
              (should proc)
              (should (rdev-shell-test--wait (lambda () (not (process-live-p proc)))))
              (should (= 0 (process-exit-status proc)))
              (should (equal "one\ntwo\n" (with-current-buffer buf (buffer-string))))))
        (kill-buffer buf)))))

(ert-deftest rdev-shell-comint-session-keeps-state-and-cwd ()
  (rdev-test-with-twin-dir (native remote)
    (let* ((default-directory (concat remote "sub/"))
           (explicit-shell-file-name "/bin/sh")
           (buf (save-window-excursion (shell "*rdev-shell-test*")))
           (proc (get-buffer-process buf)))
      (unwind-protect
          (progn
            (should (process-live-p proc))
            (comint-send-string proc "FOO=bar; echo v=$FOO; pwd\n")
            (should (rdev-shell-test--wait
                     (lambda () (with-current-buffer buf
                                  (save-excursion
                                    (goto-char (point-min))
                                    (re-search-forward "v=bar$" nil t))))))
            (should (with-current-buffer buf
                      (save-excursion (goto-char (point-min))
                                      (re-search-forward "/sub$" nil t))))
            (comint-send-string proc "exit 5\n")
            (should (rdev-shell-test--wait (lambda () (not (process-live-p proc)))))
            (should (= 5 (process-exit-status proc))))
        (when (process-live-p proc) (delete-process proc))
        (kill-buffer buf)))))

(ert-deftest rdev-shell-process-file-and-shell-command-agree-with-native ()
  (rdev-test-with-twin-dir (native remote)
    (let ((cmd "ls | sort | tr '\\n' ' '"))
      (should (equal (let ((default-directory native)) (shell-command-to-string cmd))
                     (let ((default-directory remote)) (shell-command-to-string cmd)))))))

(ert-deftest rdev-shell-pty-input-sent-immediately-is-not-lost ()
  "Regression: the relay's setraw used TCSAFLUSH and dropped early input."
  (rdev-test-with-twin-dir (native remote)
    (let* ((default-directory remote)
           (buf (generate-new-buffer " *rdev-early*"))
           (p (make-process :name "early" :buffer buf :command '("sh")
                            :connection-type 'pty :file-handler t :noquery t)))
      (unwind-protect
          (progn
            (process-send-string p "echo early-input-ok\n")
            (should (rdev-shell-test--wait
                     (lambda () (with-current-buffer buf
                                  (string-match-p "early-input-ok" (buffer-string)))))))
        (when (process-live-p p) (delete-process p))
        (kill-buffer buf)))))

(ert-deftest rdev-shell-command-default-output-buffer-runs-remotely ()
  "Regression: with no OUTPUT-BUFFER (what `dired-do-shell-command' does),
shell-command went through `call-process-region' and ran on the local machine."
  (rdev-test-with-twin-dir (native remote)
    (let ((default-directory (concat remote "sub/"))
          (display-buffer-overriding-action '(display-buffer-no-window)))
      (when (get-buffer "*Shell Command Output*") (kill-buffer "*Shell Command Output*"))
      (shell-command "pwd")
      (let ((out (with-current-buffer "*Shell Command Output*" (buffer-string))))
        (should (string-suffix-p (file-local-name (expand-file-name "sub" remote))
                                 (string-trim out))))
      (shell-command "cat" nil)
      (kill-buffer "*Shell Command Output*"))))

(provide 'rdev-shell-test)
;;; rdev-shell-test.el ends here
