;;; rdev-notify-test.el --- T048 file-notify bridge  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(require 'rdev-notify)

(defun rdev-notify-test--wait (pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 6))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defmacro rdev-notify-test--with-dir (&rest body)
  "Run BODY with `dir' a local temp dir, `rdir' its /rdev:test: name, host test."
  `(let* ((dir (file-name-as-directory (make-temp-file "rdev-notify" t)))
          (rdir (concat "/rdev:test:" dir))
          (events nil))
     (rdev-test-with-server
       (unwind-protect (progn ,@body)
         (clrhash rdev-notify--watches)
         (delete-directory dir t)))))

(defun rdev-notify-test--cb (cell)
  (lambda (ev)
    ;; Emacs 30 reports `stopped' to the callback on rm-watch; not an event.
    (unless (eq (nth 1 ev) 'stopped) (push ev (car cell)))))

(ert-deftest rdev-notify-events-reach-callback-with-remote-names ()
  (rdev-notify-test--with-dir
   (let* ((cell (list nil))
          (d (file-notify-add-watch rdir '(change) (rdev-notify-test--cb cell)))
          (f (concat dir "a.txt")))
     (should (file-notify-valid-p d))
     (write-region "1" nil f nil 'silent)
     (should (rdev-notify-test--wait
              (lambda () (cl-find-if (lambda (e) (and (eq (nth 1 e) 'created)
                                                      (equal (nth 2 e) (concat "/rdev:test:" f))))
                                     (car cell)))))
     (delete-file (concat rdir "a.txt"))
     (should (rdev-notify-test--wait
              (lambda () (cl-find 'deleted (car cell) :key (lambda (e) (nth 1 e))))))
     (file-notify-rm-watch d))))

(ert-deftest rdev-notify-event-invalidates-target-and-parent-cache ()
  (rdev-notify-test--with-dir
   (let* ((f (concat dir "c.txt")) (rf (concat rdir "c.txt")) (cell (list nil)))
     (write-region "x" nil f nil 'silent)
     (should (= 1 (file-attribute-size (file-attributes rf))))   ; primes the cache
     (let ((d (file-notify-add-watch rdir '(change) (rdev-notify-test--cb cell))))
       (sleep-for 1.1)
       (write-region "xxxx" nil f nil 'silent)
       (should (rdev-notify-test--wait (lambda () (car cell))))
       (should (= 4 (file-attribute-size (file-attributes rf))))
       (file-notify-rm-watch d)))))

(ert-deftest rdev-notify-rm-watch-stops-events ()
  (rdev-notify-test--with-dir
   (let* ((cell (list nil))
          (d (file-notify-add-watch rdir '(change) (rdev-notify-test--cb cell))))
     (file-notify-rm-watch d)
     (should-not (file-notify-valid-p d))
     (write-region "z" nil (concat dir "late") nil 'silent)
     (should-not (rdev-notify-test--wait (lambda () (car cell)) 1.5)))))

(ert-deftest rdev-notify-legacy-agent-signals-file-notify-error ()
  (rdev-notify-test--with-dir
   (let ((c (rdev--conn "test")))
     (setf (rdev-conn-caps c) (remove "watch" (rdev-conn-caps c)))
     (should-error (file-notify-add-watch rdir '(change) #'ignore)
                   :type 'file-notify-error))))

(ert-deftest rdev-notify-missing-directory-signals-file-notify-error ()
  (rdev-notify-test--with-dir
   (should-error (file-notify-add-watch (concat rdir "nope/") '(change) #'ignore)
                 :type 'file-notify-error)))

(ert-deftest rdev-notify-watch-survives-reconnect ()
  (rdev-notify-test--with-dir
   (let* ((cell (list nil))
          (d (file-notify-add-watch rdir '(change) (rdev-notify-test--cb cell))))
     ;; New connection = new generation and a fresh agent without our watch.
     (rdev-test--disconnect)
     (rdev-test--connect)
     (setf (rdev-conn-gen (rdev--conn "test")) 99)
     (should-not (file-notify-valid-p d))
     (cl-letf (((symbol-function 'rdev-state-session-key) (lambda (h) h)))
       (rdev-notify--reregister "test"))
     (should (file-notify-valid-p d))
     (write-region "q" nil (concat dir "after") nil 'silent)
     (should (rdev-notify-test--wait
              (lambda () (cl-find 'created (car cell) :key (lambda (e) (nth 1 e)))))))))

(ert-deftest rdev-notify-final-disconnect-drops-with-stopped ()
  (rdev-notify-test--with-dir
   (let* ((cell (list nil))
          (d (file-notify-add-watch rdir '(change) (rdev-notify-test--cb cell))))
     (cl-letf (((symbol-function 'rdev-state-session-key) (lambda (h) h)))
       (rdev-notify--state-change "test" 'reconnecting 'failed))
     (should-not (file-notify-valid-p d))
     (should-not (gethash d rdev-notify--watches)))))

(ert-deftest rdev-notify-callback-error-does-not-break-dispatch ()
  (rdev-notify-test--with-dir
   (let* ((d (file-notify-add-watch rdir '(change) (lambda (e) (unless (eq (nth 1 e) 'stopped) (error "boom"))))))
     (write-region "1" nil (concat dir "k") nil 'silent)
     (sleep-for 1)
     ;; The connection still works.
     (should (file-exists-p (concat rdir "k")))
     (file-notify-rm-watch d))))

(provide 'rdev-notify-test)
