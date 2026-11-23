;;; rdev-chan-scope-test.el --- channel ids scoped per host (T068, D-06)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defmacro rdev-chan-scope--with-two-hosts (&rest body)
  `(progn
     (rdev-test--connect "A") (rdev-test--connect "B")
     (unwind-protect (progn ,@body)
       (clrhash rdev--chans)
       (dolist (h '("A" "B")) (rdev-test--disconnect h)))))

(defun rdev-chan-scope--rpc (h) (rdev-conn-rpc (gethash h rdev--conns)))

(ert-deftest rdev-chan-scope-same-id-two-hosts-coexist ()
  (rdev-chan-scope--with-two-hosts
   (let ((a (rdev--make-chan :id 7 :host "A"))
         (b (rdev--make-chan :id 7 :host "B")))
     (rdev--chan-put a) (rdev--chan-put b)
     (should (eq a (rdev--chan-get "A" 7)))
     (should (eq b (rdev--chan-get "B" 7)))
     (should (= 2 (hash-table-count rdev--chans))))))

(ert-deftest rdev-chan-scope-exit-routes-to-owning-host-only ()
  (rdev-chan-scope--with-two-hosts
   (let ((a (rdev--make-chan :id 7 :host "A"))
         (b (rdev--make-chan :id 7 :host "B")))
     (rdev--chan-put a) (rdev--chan-put b)
     (rdev--dispatch (rdev-chan-scope--rpc "B") 'proc/exit '(:id 7 :code 3))
     (should (rdev-chan-exited b))
     (should-not (rdev-chan-exited a))
     (should (rdev--chan-get "A" 7))
     (should-not (rdev--chan-get "B" 7)))))

(ert-deftest rdev-chan-scope-unknown-id-from-other-host-ignored ()
  (rdev-chan-scope--with-two-hosts
   (let ((a (rdev--make-chan :id 9 :host "A")))
     (rdev--chan-put a)
     (rdev--dispatch (rdev-chan-scope--rpc "B") 'proc/exit '(:id 9 :code 0))
     (rdev--dispatch (rdev-chan-scope--rpc "B") 'proc/out '(:id 9 :stream "out" :data "eA=="))
     (should-not (rdev-chan-exited a)))))

(ert-deftest rdev-chan-scope-disconnect-exits-only-that-hosts-channels ()
  (rdev-chan-scope--with-two-hosts
   (let ((a (rdev--make-chan :id 1 :host "A"))
         (b (rdev--make-chan :id 2 :host "B")))
     (rdev--chan-put a) (rdev--chan-put b)
     (cl-letf (((symbol-function 'message) #'ignore))
       (rdev--on-shutdown "A"))
     (should (rdev-chan-exited a))
     (should-not (rdev-chan-exited b)))))

;; Two ssh aliases for one machine share one connection (FR-008), so `rdev--conns' holds the
;; same connection object under both names.  A process started through either name must still
;; receive its output and exit notifications.
(ert-deftest rdev-chan-scope-aliases-sharing-a-connection-both-receive-output ()
  (rdev-chan-scope--with-two-hosts
   (puthash "B" (gethash "A" rdev--conns) rdev--conns)   ; B is an alias of A
   (let ((rpc (rdev-chan-scope--rpc "A")) (got nil))
     (dolist (host '("A" "B"))
       (let ((c (rdev--make-chan :id 3 :host host :sock 'fake)))
         (setq got nil)
         (rdev--chan-put c)
         (cl-letf (((symbol-function 'rdev--relay-send)
                    (lambda (_sock type payload) (push (cons type payload) got))))
           (rdev--dispatch rpc 'proc/out '(:id 3 :stream "out" :data "aGk="))   ; "hi"
           (should (equal got '(("O" . "hi"))))
           (rdev--dispatch rpc 'proc/exit '(:id 3 :code 4))
           (should (rdev-chan-exited c))
           (should (equal (car got) '("X" . "4")))))))))

(ert-deftest rdev-chan-scope-alias-hosts-listed-for-a-shared-connection ()
  (rdev-chan-scope--with-two-hosts
   (puthash "B" (gethash "A" rdev--conns) rdev--conns)
   (should (equal (sort (rdev--conn-hosts-of (rdev-chan-scope--rpc "A")) #'string<)
                  '("A" "B")))))

(provide 'rdev-chan-scope-test)
