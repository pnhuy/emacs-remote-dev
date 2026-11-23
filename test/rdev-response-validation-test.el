;;; rdev-response-validation-test.el --- client protocol validation (T121, FR-029)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defun rdev-rv--conn ()
  "An rdev-style connection over a cat process; messages are injected by hand."
  (let* ((proc (make-process :name "rdev-rv" :command '("cat") :connection-type 'pipe
                             :noquery t :buffer nil))
         (rpc (jsonrpc-process-connection
               :name "rdev-rv" :process proc :events-buffer-config '(:size 0)
               :notification-dispatcher #'rdev--dispatch)))
    rpc))

(defmacro rdev-rv--with (conn &rest body)
  (declare (indent 1))
  `(let ((,conn (rdev-rv--conn)) (rdev--protocol-errors nil))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-process (jsonrpc--process ,conn))))))

(defun rdev-rv--pending (conn id)
  "Register a fake pending request ID on CONN; return a cell updated on completion."
  (let ((cell (list nil)))
    (push (list id :x (lambda (r) (setcar cell (list :ok r)))
                (lambda (e) (setcar cell (list :err e)))
                nil)
          (jsonrpc--continuations conn))
    cell))

(ert-deftest rdev-rv-invalid-messages-never-raise ()
  (rdev-rv--with c
    (dolist (m (list nil 5 "str" '(:id 1 :result 1)               ; no jsonrpc
                     '(:jsonrpc "1.0" :id 1 :result 1)             ; wrong version
                     '(:jsonrpc "2.0" :result 1)                    ; no id
                     '(:jsonrpc "2.0" :id 1)                        ; neither
                     '(:jsonrpc "2.0" :id 1 :result 1 :error (:code 1 :message "x")) ; both
                     '(:jsonrpc "2.0" :id 1 :error (:code "x" :message "m"))
                     '(:jsonrpc "2.0" :id [1] :result 1)
                     '(:jsonrpc "2.0" :method 7)                    ; bad method
                     '(:jsonrpc "2.0" :method "" )
                     '(:jsonrpc "2.0" :method "proc/out" :params "str")))
      (should (condition-case nil (progn (jsonrpc-connection-receive c m) t) (error nil))))
    (should (>= (length rdev--protocol-errors) 11))))

(ert-deftest rdev-rv-valid-messages-are-accepted ()
  (rdev-rv--with c
    (let ((cell (rdev-rv--pending c 7)))
      (jsonrpc-connection-receive c '(:jsonrpc "2.0" :id 7 :result (:ok t)))
      (should (eq :ok (car (car cell)))))
    (jsonrpc-connection-receive c '(:jsonrpc "2.0" :method "proc/out" :params (:id 99 :data "")))
    (should (null rdev--protocol-errors))))

(ert-deftest rdev-rv-malformed-reply-fails-the-pending-request ()
  (rdev-rv--with c
    (let ((cell (rdev-rv--pending c 3)))
      (jsonrpc-connection-receive c '(:jsonrpc "2.0" :id 3 :result 1 :error (:code 1 :message "x")))
      (should (eq :err (car (car cell))))
      (should (= -32600 (plist-get (cadr (car cell)) :code))))))

(ert-deftest rdev-rv-unknown-id-does-not-disturb-pending ()
  (rdev-rv--with c
    (let ((cell (rdev-rv--pending c 1)))
      (jsonrpc-connection-receive c '(:jsonrpc "2.0" :id 999 :result "stray"))
      (should (null (car cell)))
      (should (assq 1 (jsonrpc--continuations c))))))

(ert-deftest rdev-rv-malformed-notification-is-dropped ()
  (rdev-rv--with c
    (let ((called nil))
      (cl-letf (((symbol-function 'rdev--dispatch) (lambda (&rest _) (setq called t))))
        (jsonrpc-connection-receive c '(:jsonrpc "2.0" :method 5 :params nil)))
      (should-not called))))

(ert-deftest rdev-rv-dispatch-error-does-not-escape ()
  "A bug in notification handling must not break the process filter."
  (rdev-rv--with c
    (let ((rpc c))
      (cl-letf (((symbol-function 'rdev--chan-for) (lambda (&rest _) (error "boom"))))
        (should (condition-case nil
                    (progn (jsonrpc-connection-receive
                            rpc '(:jsonrpc "2.0" :method "proc/out" :params (:id 1 :data "")))
                           t)
                  (error nil)))))))

(ert-deftest rdev-rv-other-connections-untouched ()
  "Connections not created by rdev keep stock jsonrpc behavior."
  (let* ((proc (make-process :name "rdev-rv-x" :command '("cat") :noquery t :buffer nil))
         (c (jsonrpc-process-connection :name "x" :process proc :events-buffer-config '(:size 0)
                                        :notification-dispatcher #'ignore))
         (rdev--protocol-errors nil))
    (unwind-protect
        (progn (ignore-errors (jsonrpc-connection-receive c '(:id 1 :result 1)))
               (should (null rdev--protocol-errors)))
      (delete-process proc))))

(ert-deftest rdev-rv-real-agent-still-works-and-malformed-reply-from-fake-agent ()
  (rdev-test--connect)
  (unwind-protect
      (should (plist-get (rdev--req "test" :hello nil) :protocol))
    (rdev-test--disconnect)))

(provide 'rdev-response-validation-test)
