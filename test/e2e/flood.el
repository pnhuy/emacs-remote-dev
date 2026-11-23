;;; flood.el --- E2E process output flood (T070, R7)  -*- lexical-binding: t; -*-
;; RDEV_FLOOD_MB (default 100): output volume.  Every byte must arrive before the
;; sentinel, Emacs must keep servicing timers, and RSS growth must stay bounded.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun e2e-flood--rss-kb ()
  (or (alist-get 'rss (process-attributes (emacs-pid))) 0))

(ert-deftest e2e-flood-output-complete-and-responsive ()
  (e2e-with-dir
    (let* ((mb (string-to-number (or (getenv "RDEV_FLOOD_MB") "100")))
           (want (* mb 1024 1024))
           (default-directory e2e--dir)
           (got 0) (done nil) (last (float-time)) (maxgap 0)
           (base (progn (garbage-collect) (e2e-flood--rss-kb)))
           (peak 0)
           (tick (run-with-timer 0.05 0.05
                                 (lambda ()
                                   (let ((now (float-time)))
                                     (setq maxgap (max maxgap (- now last)) last now)
                                     (setq peak (max peak (- (e2e-flood--rss-kb) base)))))))
           (proc (make-process
                  :name "flood" :buffer nil :noquery t :connection-type 'pipe :file-handler t
                  :command (list "sh" "-c"
                                 (format "head -c %d /dev/zero; exit 7" want))
                  :filter (lambda (_p s) (cl-incf got (string-bytes s)))
                  :sentinel (lambda (_p ev) (when (string-match-p "exited\\|finished" ev)
                                              (setq done ev))))))
      (unwind-protect
          (progn
            (with-timeout (300 (ert-fail "flood did not finish"))
              (while (not done) (accept-process-output nil 0.05)))
            (should (= got want))
            (should (= 7 (process-exit-status proc)))
            (message "flood: %d MiB, max timer gap %.2fs, peak RSS growth %d KiB"
                     mb maxgap peak)
            (should (< maxgap 3.0))
            (should (< peak (* 256 1024))))
        (cancel-timer tick)
        (when (process-live-p proc) (delete-process proc))))))

(ert-deftest e2e-flood-relay-send-is-not-recursive-and-queue-is-bounded ()
  "Regression: a burst of remote output must neither nest `rdev--relay-send'
(excessive-lisp-nesting) nor let Emacs buffer the output ahead of the relay
(no end-to-end backpressure).  Found by running the flood against a real remote."
  (e2e-with-dir
    (let* ((want (* 16 1024 1024)) (default-directory e2e--dir)
           (got 0) (done nil) (depth 0) (maxdepth 0) (maxq 0)
           (adv (lambda (f sock type payload)
                  (setq maxq (max maxq (length (process-get sock 'rdev-outq))))
                  (cl-incf depth) (setq maxdepth (max maxdepth depth))
                  (unwind-protect (funcall f sock type payload) (cl-decf depth)))))
      (advice-add 'rdev--relay-send :around adv)
      (unwind-protect
          (let ((proc (make-process
                       :name "flood-q" :buffer nil :noquery t :connection-type 'pipe
                       :file-handler t
                       :command (list "sh" "-c" (format "head -c %d /dev/zero" want))
                       :filter (lambda (_p s) (cl-incf got (string-bytes s)))
                       :sentinel (lambda (_p ev) (when (string-match-p "exited\\|finished" ev)
                                                   (setq done t))))))
            (with-timeout (120 (ert-fail "flood did not finish"))
              (while (not done) (accept-process-output nil 0.05)))
            (should (= got want))
            (message "relay-send max nesting %d, max queued frames %d" maxdepth maxq)
            (should (<= maxdepth 2))
            (should (< maxq 32))
            (when (process-live-p proc) (delete-process proc)))
        (advice-remove 'rdev--relay-send adv)))))
