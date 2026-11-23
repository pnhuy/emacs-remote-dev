;;; stall.el --- E2E command-loop stall measurement at RTT <= 50 ms (T113, SC-006)  -*- lexical-binding: t; -*-
;; Needs an external host (RDEV_TEST_SSH_TARGET): latency is injected with bench/delay-proxy.py
;; (RDEV_STALL_RTT ms, default 50).  A 10 ms timer records the longest gap between ticks while
;; RDEV runs a search, a large transfer (read and write) and a process flood.  SC-006 requires
;; every gap <= 200 ms.  Per-call blocking time of synchronous handlers is printed as well.
;; Volumes: RDEV_STALL_MB (default 64) for transfer and flood.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(require (quote rdev-search))
(defconst e2e-stall-rtt (string-to-number (or (getenv "RDEV_STALL_RTT") "50")))
(defconst e2e-stall-mb (string-to-number (or (getenv "RDEV_STALL_MB") "64")))
(defconst e2e-stall-limit 0.2)
(defvar e2e-stall--host nil)
(defvar e2e-stall--cfg nil)

(defun e2e-stall--setup ()
  "Create an ssh config whose host `rdev-stall' reaches the test host through the delay proxy."
  (unless e2e-stall--host
    (let* ((g (with-temp-buffer
                (call-process "ssh" nil t nil "-G" "--" e2e-host)
                (buffer-string)))
           (field (lambda (k) (and (string-match (format "^%s \\(.*\\)$" k) g) (match-string 1 g))))
           (proxy (expand-file-name "bench/delay-proxy.py" (or (getenv "RDEV_ROOT") default-directory)))
           (cfg (make-temp-file "rdev-stall-cfg")))
      (with-temp-file cfg
        (insert (format "Include %s/.ssh/config\nHost rdev-stall\n  HostName %s\n  User %s\n  Port %s\n  ProxyCommand python3 %s --connect %%h:%%p --rtt-ms %d\n"
                        (getenv "HOME") (funcall field "hostname") (funcall field "user")
                        (funcall field "port") proxy e2e-stall-rtt)))
      (set-file-modes cfg #o600)
      (setq e2e-stall--cfg cfg
            e2e-stall--host "rdev-stall"
            rdev-ssh-args (append (list "-F" cfg) rdev-ssh-args)))))

(defmacro e2e-stall-measure (label &rest body)
  "Run BODY with a 10 ms timer; record and report the max tick gap under LABEL."
  (declare (indent 1))
  `(let* ((last (float-time)) (maxgap 0.0) (ticks 0)
          (timer (run-with-timer 0.01 0.01
                                 (lambda ()
                                   (let ((now (float-time)))
                                     (setq maxgap (max maxgap (- now last)) last now)
                                     (cl-incf ticks)))))
          (t0 (float-time)))
     (unwind-protect (progn ,@body) (cancel-timer timer))
     (message "STALL %-22s rtt=%dms max-gap=%6.1f ms  elapsed=%6.2f s  ticks=%d"
              ,label e2e-stall-rtt (* 1000 maxgap) (- (float-time) t0) ticks)
     maxgap))

(defmacro e2e-stall-with-dir (&rest body)
  (declare (indent 0))
  `(progn
     (e2e-stall--setup)
     (let* ((root (format "/rdev:%s:" e2e-stall--host))
            (dir (format "%s/tmp/rdev-stall-%d-%d/" root (emacs-pid) (random 1000000))))
       (make-directory dir t)
       (unwind-protect (progn ,@body) (ignore-errors (delete-directory dir t))))))

(ert-deftest e2e-stall-search ()
  (e2e-stall-with-dir
    (let ((default-directory dir))
      (process-file "sh" nil nil nil "-c"
                    "i=0; while [ $i -lt 40 ]; do mkdir -p d$i; j=0; while [ $j -lt 100 ]; do echo \"line needle $i $j\" > d$i/f$j.txt; j=$((j+1)); done; i=$((i+1)); done")
      (let ((gap (e2e-stall-measure "search (4000 files)"
                   (should (rdev-search dir "needle")))))
        (should (<= gap e2e-stall-limit))))))

(ert-deftest e2e-stall-large-transfer ()
  (e2e-stall-with-dir
    (let ((f (concat dir "big.bin")) (n (* e2e-stall-mb 1024 1024)) (gap 0.0))
      (let ((default-directory dir))
        (process-file "sh" nil nil nil "-c" (format "head -c %d /dev/urandom > big.bin" n)))
      (setq gap (max gap (e2e-stall-measure "read (insert-file)"
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally f)
                             (should (= (buffer-size) n))
                             (e2e-stall--keep (buffer-substring 1 (min 100 (1+ (buffer-size)))))))))
      (let ((g (concat dir "copy.bin")))
        (setq gap (max gap (e2e-stall-measure "write (write-region)"
                             (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally f)
                               (write-region nil nil g nil 'silent))))))
      (should (<= gap e2e-stall-limit)))))

(defun e2e-stall--keep (x) x)

(ert-deftest e2e-stall-process-flood ()
  (e2e-stall-with-dir
    (let* ((default-directory dir) (got 0) (done nil)
           (want (* e2e-stall-mb 1024 1024))
           (gap (e2e-stall-measure "process flood"
                  (let ((p (make-process
                            :name "stall-flood" :buffer nil :noquery t :connection-type 'pipe
                            :file-handler t
                            :command (list "sh" "-c" (format "head -c %d /dev/zero" want))
                            :filter (lambda (_p s) (cl-incf got (string-bytes s)))
                            :sentinel (lambda (_p _e) (setq done t)))))
                    (let ((deadline (+ (float-time) 300)))
                      (while (and (not done) (< (float-time) deadline))
                        (accept-process-output nil 0.05)))
                    (ignore p)))))
      (should done)
      (should (= got want))
      (should (<= gap e2e-stall-limit)))))

(ert-deftest e2e-stall-sync-handler-blocking-times ()
  "Report how long each synchronous handler keeps the caller waiting (no pass/fail limit)."
  (e2e-stall-with-dir
    (let ((f (concat dir "t.txt")) (n 5) rows)
      (write-region "x\n" nil f nil 'silent)
      (dolist (op `(("file-exists-p" . ,(lambda () (rdev-clear-cache) (file-exists-p f)))
                    ("file-attributes" . ,(lambda () (rdev-clear-cache) (file-attributes f)))
                    ("insert-file-contents"
                     . ,(lambda () (rdev-clear-cache)
                          (with-temp-buffer (insert-file-contents f))))
                    ("write-region" . ,(lambda () (write-region "y\n" nil f nil 'silent)))
                    ("directory-files" . ,(lambda () (rdev-clear-cache) (directory-files dir)))))
        (let (times)
          (dotimes (_ n)
            (let ((t0 (float-time))) (funcall (cdr op)) (push (* 1000 (- (float-time) t0)) times)))
          (setq times (sort times #'<))
          (push (format "%-22s median %6.1f ms  max %6.1f ms" (car op) (nth (/ n 2) times)
                        (car (last times)))
                rows)))
      (dolist (r (nreverse rows)) (message "BLOCK %s (rtt=%dms)" r e2e-stall-rtt))
      (should rows))))
