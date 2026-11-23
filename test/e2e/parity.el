;;; parity.el --- output and exit-code parity across process APIs (T114, SC-007)  -*- lexical-binding: t; -*-
;; The same command is run through every Emacs process API on an /rdev: directory:
;;   process-file, shell-command, start-file-process, make-process (:file-handler t),
;;   compile, and an interactive rdev shell.
;; Expected output and exit code are fixed literals, so the result does not depend on the host.
;; Output is compared byte for byte (read as binary).  Two documented exceptions:
;;  * compile wraps the output in its own header/footer, so the body between them is compared;
;;  * the interactive shell runs on a pty, which turns "\n" into "\r\n"; CRLF is normalised
;;    back before comparing, and a BEGIN/END marker pair brackets the command output.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'compile)

(defconst e2e-parity-cases
  ;; (NAME COMMAND EXPECTED-STDOUT-BYTES EXPECTED-EXIT)
  `(("plain" "printf 'a\\nb\\n'" "a\nb\n" 0)
    ("no-trailing-newline" "printf 'abc'" "abc" 0)
    ("exit-code" "printf 'x\\n'; exit 3" "x\n" 3)
    ("exit-255" "exit 255" "" 255)
    ("binary-bytes" "printf '\\000\\001\\200\\377\\n'" ,(unibyte-string 0 1 128 255 10) 0)
    ("utf8" "printf 'h\\303\\251llo \\342\\234\\223\\n'" ,(unibyte-string ?h #xc3 #xa9 ?l ?l ?o ?\s #xe2 #x9c #x93 10) 0)
    ("empty-lines" "printf '\\n\\n\\nz\\n'" "\n\n\nz\n" 0)
    ("large-output" "head -c 300000 /dev/zero | tr '\\0' 'q'" ,(make-string 300000 ?q) 0)
    ("signal-term" "kill -TERM $$" "" 143)))

(defvar e2e-parity-failures nil)

(defun e2e-parity--check (api case got-out got-exit)
  (let ((want-out (nth 2 case)) (want-exit (nth 3 case)))
    (unless (and (equal got-out want-out) (eql got-exit want-exit))
      (push (format "%s/%s: exit %S (want %d), output %s" api (car case) got-exit want-exit
                    (if (equal got-out want-out) "equal"
                      (format "differs (%d vs %d bytes; got %S)" (length got-out) (length want-out)
                              (substring got-out 0 (min 40 (length got-out))))))
            e2e-parity-failures))))

(defun e2e-parity--bin (s) (encode-coding-string s 'no-conversion))

(defun e2e-parity--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05))
    (funcall pred)))

(defun e2e-parity--exit-of-status (n)
  "Normalise an exit status to a shell-style number.
A fatal signal is reported by Emacs as a string.  Native Emacs gives the platform's
`strsignal' text (\"Terminated\" on Linux, \"Terminated: 15\" on macOS); rdev gives
\"Signal N\" on every platform.  Both mean 128+N; that wording difference is accepted
(docs/blocking.md, \"Parity\")."
  (cond ((integerp n) n)
        ((and (stringp n) (string-match "\\`Signal \\([0-9]+\\)\\'" n))
         (+ 128 (string-to-number (match-string 1 n))))
        ((equal n "Terminated") 143)
        (t n)))

(defun e2e-parity-process-file (case)
  (let ((coding-system-for-read 'binary) (coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((code (process-file "sh" nil t nil "-c" (nth 1 case))))
        (e2e-parity--check "process-file" case (buffer-string) (e2e-parity--exit-of-status code))))))

(defun e2e-parity-shell-command (case)
  (let ((coding-system-for-read 'binary) (buf (generate-new-buffer " parity-sc")))
    (unwind-protect
        (let ((code (shell-command (nth 1 case) buf)))
          (with-current-buffer buf
            (e2e-parity--check "shell-command" case (e2e-parity--bin (buffer-string))
                               (e2e-parity--exit-of-status code))))
      (kill-buffer buf))))

(defun e2e-parity--async (api case starter)
  (let* ((out "") (done nil) (code nil)
         (p (funcall starter
                     (lambda (_p s) (setq out (concat out (e2e-parity--bin s))))
                     (lambda (pr _e) (unless (process-live-p pr)
                                       (setq done t code (process-exit-status pr)))))))
    (e2e-parity--wait (lambda () done) 60)
    (accept-process-output p 0.2)
    (e2e-parity--check api case out (e2e-parity--exit-of-status code))))

(defun e2e-parity-start-file-process (case)
  (let ((coding-system-for-read 'binary))
    (e2e-parity--async
     "start-file-process" case
     (lambda (filter sentinel)
       ;; Pipes, not a pty: a pty would turn "\n" into "\r\n" (natively as well).
       (let ((p (let ((process-connection-type nil))
                  (start-file-process "parity" nil "sh" "-c" (nth 1 case)))))
         (set-process-coding-system p 'binary 'binary)
         (set-process-query-on-exit-flag p nil)
         (set-process-filter p filter) (set-process-sentinel p sentinel) p)))))

(defun e2e-parity-make-process (case)
  (e2e-parity--async
   "make-process" case
   (lambda (filter sentinel)
     (make-process :name "parity" :buffer nil :noquery t :connection-type 'pipe
                   :file-handler t :coding 'binary
                   :command (list "sh" "-c" (nth 1 case)) :filter filter :sentinel sentinel))))

(defun e2e-parity-compile (case)
  (let* ((compilation-ask-about-save nil) (compilation-scroll-output nil)
         (buf (compile (nth 1 case)))
         (done nil))
    (with-current-buffer buf
      (add-hook 'compilation-finish-functions (lambda (_b _m) (setq done t)) nil t))
    (e2e-parity--wait (lambda () (or done (not (get-buffer-process buf)))) 60)
    (e2e-parity--wait (lambda () (with-current-buffer buf
                                   (save-excursion (goto-char (point-min))
                                                   (re-search-forward "^Compilation \\(finished\\|exited\\)" nil t))))
                      10)
    (with-current-buffer buf
      (let* ((text (e2e-parity--bin (buffer-string)))
             (code (cond ((string-match "Compilation finished\n?$\\|^Compilation finished" text) 0)
                         ((string-match "exited abnormally with code \\([0-9]+\\)" text)
                          (string-to-number (match-string 1 text)))
                         ((string-match "Compilation \\(exited\\|finished\\)" text) :other)))
             ;; body: after the header (3 lines) and before the footer
             ;; header, blank line, the echoed command line, then the output
             (start (and (string-match "\n\n[^\n]*\n" text) (match-end 0)))
             (end (and (string-match "\nCompilation \\(finished\\|exited\\)" text)
                       (match-beginning 0)))
             (body (and start end (substring text start end))))
        ;; compile's footer is preceded by a blank line when output ends with a newline.
        (when (and body (> (length body) 0) (string-suffix-p "\n" (nth 2 case)) (string-suffix-p "\n" body))
          nil)
        (e2e-parity--check "compile" case (or body "") code)
        (kill-buffer buf)))))

(defun e2e-parity-shell (case)
  "Run CASE in an interactive rdev shell: as a script file so `exit' and `$$' mean the same."
  (let* ((default-directory (file-name-as-directory (concat (e2e--root) "/tmp")))
         (buf (rdev-shell e2e-host))
         (proc (get-buffer-process buf))
         (b64 (base64-encode-string (encode-coding-string (nth 1 case) 'utf-8) t)))
    (unwind-protect
        (progn
          (e2e-parity--wait (lambda () (with-current-buffer buf (> (buffer-size) 0))) 20)
          (sleep-for 0.5)
          (with-current-buffer buf (erase-buffer))
          ;; The output goes through a file so that only the pty's own treatment of the
          ;; bytes is under test, not interleaving with the prompt.
          (process-send-string
           proc (format (concat "stty -echo; echo %s | base64 -d > /tmp/.rdev-parity.sh;"
                                " sh /tmp/.rdev-parity.sh > /tmp/.rdev-parity.out 2>&1; c=$?;"
                                " printf 'BEGIN\\n'; cat /tmp/.rdev-parity.out;"
                                " printf '\\nEND\\nCODE:%%d\\n' $c\n")
                        b64))
          (e2e-parity--wait (lambda () (with-current-buffer buf
                                         (save-excursion (goto-char (point-min))
                                                         (re-search-forward "CODE:[0-9]+" nil t))))
                            30)
          (let* ((text (with-current-buffer buf (e2e-parity--bin (buffer-string))))
                 (text (replace-regexp-in-string "\r\n" "\n" text))
                 (body (and (string-match "BEGIN\n" text)
                            (let ((st (match-end 0)))
                              (and (string-match "\nEND\n" text st)
                                   (substring text st (match-beginning 0))))))
                 (code (and (string-match "CODE:\\([0-9]+\\)" text)
                            (string-to-number (match-string 1 text)))))
            (e2e-parity--check "shell" case (or body "") code)))
      (when (process-live-p proc) (delete-process proc))
      (ignore-errors (kill-buffer buf)))))

(ert-deftest e2e-parity-matrix ()
  (e2e-with-dir
    (let ((default-directory e2e--dir) (e2e-parity-failures nil)
          (apis '(e2e-parity-process-file e2e-parity-shell-command e2e-parity-start-file-process
                  e2e-parity-make-process e2e-parity-compile)))
      (dolist (api apis)
        (dolist (case e2e-parity-cases)
          (let ((default-directory e2e--dir))
            (condition-case err (funcall api case)
              (error (push (format "%s/%s: signalled %S" api (car case) err) e2e-parity-failures))))))
      (when e2e-parity-failures
        (message "PARITY FAILURES:\n  %s" (mapconcat #'identity (reverse e2e-parity-failures) "\n  ")))
      (should-not e2e-parity-failures))))

(defconst e2e-parity-pty-exempt '("binary-bytes")
  "Cases a pty cannot carry byte for byte: it drops or reinterprets control bytes (NUL, ^A).")

(ert-deftest e2e-parity-interactive-shell ()
  "Output and exit code through an interactive rdev shell (pty), CRLF normalised."
  (e2e-with-dir
    (let ((e2e-parity-failures nil))
      (dolist (case e2e-parity-cases)
        (unless (member (car case) e2e-parity-pty-exempt)
          (condition-case err (e2e-parity-shell case)
            (error (push (format "shell/%s: signalled %S" (car case) err) e2e-parity-failures)))))
      (when e2e-parity-failures
        (message "PARITY FAILURES:\n  %s" (mapconcat #'identity (reverse e2e-parity-failures) "\n  ")))
      (should-not e2e-parity-failures))))
