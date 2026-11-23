;;; rdev-bench.el --- Benchmark driver for rdev and TRAMP  -*- lexical-binding: t; -*-

;;; Commentary:

;; Measures the same file/process operations through a root such as
;; /rdev:HOST: or /ssh:HOST: and prints CSV rows:
;;   date,shaper,profile,backend,op,n,median_ms,p95_ms,failures,ui_blocked_ms,emacs_rss_kb,note
;; ui_blocked_ms is the longest stretch during which an Emacs timer could not
;; run (a 10 ms ticker records the gaps), so synchronous file-handler calls
;; show their full latency while `proc-async' shows that process I/O leaves
;; the UI responsive.  Driven by bench/run.sh; see bench/README.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rdev)
(require 'rdev-search)
(require 'tramp)

(defvar rdev-bench-iterations 20 "Iterations per operation (connect uses a quarter).")

(defvar rdev-bench--ticks nil)
(defvar rdev-bench--timer nil)

(defun rdev-bench--tick () (push (float-time) rdev-bench--ticks))

(defun rdev-bench--measure (fn)
  "Run FN; return (MS OK UI-BLOCKED-MS)."
  (setq rdev-bench--ticks (list (float-time)))
  (setq rdev-bench--timer (run-at-time 0.01 0.01 #'rdev-bench--tick))
  (let* ((t0 (float-time))
         (ok (condition-case _ (progn (funcall fn) t) (error nil)))
         (t1 (float-time))
         (ticks (cons t1 (reverse (cons t0 rdev-bench--ticks)))))
    (cancel-timer rdev-bench--timer)
    (let ((gap 0.0) (prev nil))
      (dolist (x (sort (copy-sequence ticks) #'<))
        (when prev (setq gap (max gap (- x prev))))
        (setq prev x))
      (list (* 1000 (- t1 t0)) ok (max 0 (* 1000 (- gap 0.01)))))))

(defun rdev-bench--pct (sorted p)
  (if sorted (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted) 0))

(defun rdev-bench--rss ()
  (string-to-number
   (string-trim (shell-command-to-string (format "ps -o rss= -p %d" (emacs-pid))))))

(defun rdev-bench--row (shaper profile backend op results &optional note)
  "Format RESULTS (list of (MS OK UI)) as one CSV line."
  (let* ((oks (cl-remove-if-not #'cadr results))
         (ms (sort (mapcar #'car oks) #'<))
         (ui (apply #'max 0 (mapcar #'caddr results))))
    (format "%s,%s,%s,%s,%s,%d,%.2f,%.2f,%d,%.2f,%d,%s"
            (format-time-string "%Y-%m-%d") shaper profile backend op (length results)
            (rdev-bench-median ms) (rdev-bench--pct ms 0.95)
            (- (length results) (length oks)) ui (rdev-bench--rss) (or note ""))))

(defun rdev-bench-median (sorted)
  "Median of the already sorted list SORTED (0 when empty)."
  (cond ((null sorted) 0)
        ((cl-oddp (length sorted)) (nth (/ (length sorted) 2) sorted))
        (t (/ (+ (nth (1- (/ (length sorted) 2)) sorted) (nth (/ (length sorted) 2) sorted)) 2.0))))

(defun rdev-bench--flush (backend host dir)
  "Drop client-side caches for DIR (a remote name) so the next call goes to the wire."
  (let ((local (file-local-name dir)))
    (if (equal backend "rdev")
        (rdev--invalidate-tree host local)
      (tramp-flush-directory-properties (tramp-dissect-file-name dir) local))))

(defun rdev-bench--fixture (dir)
  "Create the benchmark tree under DIR (a remote or local directory name)."
  (make-directory (concat dir "many") t)
  (make-directory (concat dir "proj/src") t)
  (make-directory (concat dir "big") t)
  (let ((text (concat (make-string 4000 ?x) "\n"))
        (default-directory dir))
    (write-region text nil (concat dir "small.txt") nil 'silent)
    (write-region (concat "needle\n" text) nil (concat dir "proj/src/hit.txt") nil 'silent)
    ;; One shell call creates the many small files instead of 500 round trips.
    (process-file "sh" nil nil nil "-c"
                  "i=0; while [ $i -lt 200 ]; do echo f$i > many/f$i; echo l$i > proj/src/g$i.txt; i=$((i+1)); done; i=0; while [ $i -lt 1000 ]; do : > big/file$i.txt; i=$((i+1)); done")))

(defun rdev-bench--remote-has (dir prog)
  "Non-nil when PROG is on the PATH of the host DIR belongs to."
  (let ((default-directory dir))
    (eq 0 (process-file "sh" nil nil nil "-c" (format "command -v %s >/dev/null" prog)))))

(defun rdev-bench--eglot-startup (dir)
  "Start pylsp for a file under DIR, wait for the handshake, shut it down.
Signal an error when the server does not come up."
  (require 'eglot)
  (let* ((proj (concat dir "eglot-proj/")) (file (concat proj "main.py"))
         (vc-handled-backends nil) buf server)
    (make-directory proj t)
    (write-region "" nil (concat proj ".project") nil 'silent)
    (write-region "x = 1\n" nil file nil 'silent)
    (setq buf (find-file-noselect file))
    (unwind-protect
        (with-current-buffer buf
          (let ((eglot-server-programs `((,major-mode . ("pylsp"))))
                (eglot-sync-connect t) (eglot-connect-timeout 60)
                (eglot-autoreconnect nil) (inhibit-message t))
            (setq-local eglot-autoshutdown nil)
            (apply #'eglot (eglot--guess-contact))
            (setq server (eglot-current-server))
            (unless server (error "Eglot server did not start"))))
      (when (and server (jsonrpc-running-p server))
        (ignore-errors (let ((eglot-autoshutdown t)) (eglot-shutdown server nil 15 t))))
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))))

(defun rdev-bench-run (root backend shaper profile &optional with-rdev-ops)
  "Benchmark ROOT (e.g. \"/rdev:host:\"); return a list of CSV lines.
BACKEND labels the rows.  WITH-RDEV-OPS adds rdev-only operations."
  (let* ((n rdev-bench-iterations)
         (dir (format "%s/tmp/rdev-bench-%d/" root (emacs-pid)))
         (rows nil)
         (host (and (string-match "\\`/[a-z]+:\\([^:]+\\):" root) (match-string 1 root))))
    (cl-flet ((run (op count fn &optional note)
                (let ((res (cl-loop repeat count collect (rdev-bench--measure fn))))
                  (push (rdev-bench--row shaper profile backend op res note) rows))))
      (rdev-bench--fixture dir)
      (unwind-protect
          (progn
            (run "stat-cached" n (lambda () (file-attributes (concat dir "small.txt"))))
            (run "stat-cold" n
                 (lambda ()
                   (let ((f (concat dir "small.txt")))
                     (if (equal backend "rdev")
                         (rdev--invalidate host (file-local-name f))
                       (tramp-flush-file-properties (tramp-dissect-file-name f)
                                                    (file-local-name f)))
                     (file-attributes f))))
            (run "exists" n (lambda () (file-exists-p (concat dir "small.txt"))))
            (run "open" n (lambda () (with-temp-buffer (insert-file-contents (concat dir "small.txt")))))
            (let ((i 0))
              (run "save" n (lambda ()
                              (with-temp-buffer
                                (insert (format "%d %s\n" (cl-incf i) (make-string 4000 ?y)))
                                (let ((write-region-inhibit-fsync t) (inhibit-message t))
                                  (write-region nil nil (concat dir "save.txt") nil 'silent))))))
            (let ((many (concat dir "many")) (proj (concat dir "proj")))
              ;; Cold = client caches flushed first; warm = cache allowed.
              (run "readdir-cold" n (lambda () (rdev-bench--flush backend host many)
                                      (directory-files many nil nil t)))
              (run "readdir-warm" n (lambda () (directory-files many nil nil t)))
              (run "readdir-attrs-cold" n (lambda () (rdev-bench--flush backend host many)
                                            (directory-files-and-attributes many)))
              ;; T094: completion in a 1000-entry directory (budget 500 ms at 150 ms RTT).
              (run "completion-1000-cold" n
                   (lambda () (let ((big (concat dir "big/")))
                                (rdev-bench--flush backend host big)
                                (file-name-all-completions "file1" big))))
              (run "tree-walk-cold" (max 3 (/ n 4))
                   (lambda () (rdev-bench--flush backend host proj)
                     (directory-files-recursively proj ""))))
            (run "proc-start" n (lambda () (let ((default-directory dir)) (process-file "true"))))
            (run "shell-echo" n (lambda () (let ((default-directory dir))
                                             (with-temp-buffer (process-file "sh" nil t nil "-c" "echo hi")))))
            (run "proc-async" n
                 (lambda ()
                   (let* ((default-directory dir) (done nil)
                          (p (make-process :name "bench" :buffer nil :noquery t :file-handler t
                                           :command '("sh" "-c" "sleep 0.05; echo hi")
                                           :sentinel (lambda (_p _e) (setq done t)))))
                     (while (not done) (accept-process-output nil 0.01))
                     (ignore p))))
            (when with-rdev-ops
              (run "project-files" (max 3 (/ n 4))
                   (lambda () (rdev--req host :project/files `(:root ,(file-local-name (concat dir "proj"))))))
              (run "search" (max 3 (/ n 4))
                   (lambda () (rdev-search (concat dir "proj") "needle"))))
            (if (rdev-bench--remote-has dir "pylsp")
                (run "eglot-startup" (max 2 (/ n 4))
                     (lambda () (rdev-bench--eglot-startup dir))
                     "pylsp: find-file + initialize handshake")
              (push (rdev-bench--row shaper profile backend "eglot-startup" nil
                                     "skipped: pylsp not installed on the target")
                    rows))
            (run "connect" (max 3 (/ n 4))
                 (lambda ()
                   (if (equal backend "rdev")
                       (progn (let ((rdev-reconnect nil)) (rdev-disconnect host))
                              (rdev--connect host))
                     (tramp-cleanup-connection (tramp-dissect-file-name root) nil t)
                     (file-exists-p (concat root "/tmp"))))))
        (ignore-errors (delete-directory dir t))))
    (nreverse rows)))

(defconst rdev-bench-header
  "date,shaper,profile,backend,op,n,median_ms,p95_ms,failures,ui_blocked_ms,emacs_rss_kb,note")

(defun rdev-bench-main ()
  "Entry point for bench/run.sh; configured by RDEV_BENCH_* environment variables."
  (let* ((host (getenv "RDEV_BENCH_HOST"))
         (shaper (or (getenv "RDEV_BENCH_SHAPER") "none"))
         (profile (or (getenv "RDEV_BENCH_PROFILE") "rtt0"))
         (backends (split-string (or (getenv "RDEV_BENCH_BACKENDS") "rdev,tramp") ","))
         (out (getenv "RDEV_BENCH_OUT"))
         (rdev-bench-iterations (string-to-number (or (getenv "RDEV_BENCH_ITER") "20")))
         )
    (when-let* ((cfg (getenv "RDEV_BENCH_SSH_CONFIG")))
      (setq rdev-ssh-args (append (list "-F" cfg) rdev-ssh-args))
      (setq tramp-ssh-controlmaster-options
            (format "-F %s -o ControlMaster=auto -o ControlPath=tramp.%%%%C -o ControlPersist=no" cfg)))
    (setq rdev-ssh-args (append rdev-ssh-args '("-o" "BatchMode=yes" "-o" "ConnectTimeout=20")))
    ;; Each backend's rows are written as soon as it finishes, so a failure in
    ;; one backend (say TRAMP) does not lose the other's results.
    (cl-flet ((emit (lines)
                (let ((text (concat (mapconcat #'identity lines "\n") "\n")))
                  (if out
                      (with-temp-buffer (insert text) (write-region nil nil out t 'silent))
                    (princ text)))))
      (when (member "rdev" backends)
        (rdev--connect host)
        (emit (rdev-bench-run (format "/rdev:%s:" host) "rdev" shaper profile t)))
      (when (member "tramp" backends)
        (emit (rdev-bench-run (format "/ssh:%s:" host) "tramp" shaper profile))))))

(provide 'rdev-bench)
;;; rdev-bench.el ends here
