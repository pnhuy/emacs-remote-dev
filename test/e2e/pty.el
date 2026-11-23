;;; pty.el --- E2E pty behavior of remote processes (T081, R-03)  -*- lexical-binding: t; -*-
;; Resize, SIGINT, EOF, process-group kill, through `make-process' with a pty.  Run it against
;; every platform that hosts an agent (Linux over ssh, the macOS sshd fixture) and record the
;; result in PLATFORMS.md.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun e2e-pty--run (cmd &optional type)
  "Start CMD (a shell string) remotely with TYPE (default pty); return (PROC . OUTPUT-CELL)."
  (let* ((cell (list ""))
         (p (make-process :name "e2e-pty" :connection-type (or type 'pty) :noquery t :file-handler t
                          :command (list "sh" "-c" cmd)
                          :filter (lambda (_p s) (setcar cell (concat (car cell) s)))
                          :sentinel #'ignore)))
    (cons p cell)))

(defun e2e-pty--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 20))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun e2e-pty--seen (cell re) (string-match-p re (car cell)))

(ert-deftest e2e-pty-has-a-tty-and-initial-size ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "tty; stty size"))
           (p (car r)))
      (should (e2e-pty--wait (lambda () (not (process-live-p p)))))
      (accept-process-output p 0.3)
      (should (e2e-pty--seen (cdr r) "/dev/[a-z0-9/]*"))
      (should (e2e-pty--seen (cdr r) "[0-9]+ [0-9]+")))))

(ert-deftest e2e-pty-resize-reaches-remote-tty ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "read x; stty size; read y; stty size; sleep 0.2"))
           (p (car r)))
      (should (e2e-pty--wait (lambda () (process-live-p p))))
      (set-process-window-size p 17 91)
      (process-send-string p "go\n")
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "17 91")) 15))
      (set-process-window-size p 33 120)
      (process-send-string p "go\n")
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "33 120")) 15))
      (delete-process p))))

(ert-deftest e2e-pty-sigint-interrupts-foreground-job ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "trap 'echo got-int; exit 7' INT; echo ready; while :; do sleep 0.1; done"))
           (p (car r)) status)
      (set-process-sentinel p (lambda (_p e) (setq status e)))
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "ready"))))
      (interrupt-process p)
      (should (e2e-pty--wait (lambda () (not (process-live-p p))) 15))
      (accept-process-output p 0.3)
      (should (e2e-pty--seen (cdr r) "got-int"))
      (should (string-match-p "code 7" (or status ""))))))

(ert-deftest e2e-pty-eof-ends-cat ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "cat; echo done-cat"))
           (p (car r)))
      (process-send-string p "hello\n")
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "hello"))))
      (process-send-eof p)
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "done-cat")) 15))
      (should (e2e-pty--wait (lambda () (not (process-live-p p))) 15)))))

(ert-deftest e2e-pty-pipe-eof-ends-cat ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "cat; echo done-cat" 'pipe))
           (p (car r)))
      (process-send-string p "hello\n")
      (process-send-eof p)
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "done-cat")) 15)))))

(defun e2e-pty--alive (pid)
  (eq 0 (process-file "sh" nil nil nil "-c" (format "kill -0 %s 2>/dev/null" pid))))

(ert-deftest e2e-pty-delete-process-kills-the-whole-group ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "sleep 300 & echo child=$!; wait"))
           (p (car r)) pid)
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "child=[0-9]+"))))
      (string-match "child=\\([0-9]+\\)" (car (cdr r)))
      (setq pid (match-string 1 (car (cdr r))))
      (should (e2e-pty--alive pid))
      (delete-process p)
      (should (e2e-pty--wait (lambda () (not (e2e-pty--alive pid))) 15)))))

(ert-deftest e2e-pty-delete-process-kills-the-group-with-pipe ()
  (e2e-with-dir
    (let* ((default-directory e2e--dir)
           (r (e2e-pty--run "sleep 300 & echo child=$!; wait" 'pipe))
           (p (car r)) pid)
      (should (e2e-pty--wait (lambda () (e2e-pty--seen (cdr r) "child=[0-9]+"))))
      (string-match "child=\\([0-9]+\\)" (car (cdr r)))
      (setq pid (match-string 1 (car (cdr r))))
      (delete-process p)
      (should (e2e-pty--wait (lambda () (not (e2e-pty--alive pid))) 15)))))
