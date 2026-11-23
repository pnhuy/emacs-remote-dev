;;; rdev-test-helpers.el --- shared helpers for RDEV ERT tests  -*- lexical-binding: t; -*-

;; Starts the real rdev-server.py --stdio as a local pipe
;; subprocess and registers it as the connection for host "test" (no ssh).

(require 'ert)
(require 'cl-lib)
(require 'jsonrpc)

(defconst rdev-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root.")

(defvar rdev-test-server-file
  (or (getenv "RDEV_TEST_SERVER")
      (expand-file-name "rdev-server.py" rdev-test--root))
  "Agent script used by the harness (override with RDEV_TEST_SERVER).")

(add-to-list 'load-path rdev-test--root)
(require 'rdev)

(defun rdev-test--python ()
  (or (getenv "PYTHON") "python3"))

(defun rdev-test--connect (&optional host)
  "Connect HOST (default \"test\") to a local stdio agent; return the conn."
  (let* ((host (or host "test"))
         (default-directory temporary-file-directory)
         (proc (make-process :name (format "rdev-%s" host)
                             :command (list (rdev-test--python) "-u"
                                            rdev-test-server-file "--stdio")
                             :connection-type 'pipe :coding 'binary
                             :noquery t
                             :stderr (get-buffer-create (format " *rdev-test-stderr %s*" host))))
         (rpc (jsonrpc-process-connection
               :name (format "rdev-%s" host) :process proc
               :events-buffer-config '(:size 0)
               :notification-dispatcher #'rdev--dispatch
               :on-shutdown (lambda (_) (remhash host rdev--conns))))
         (hello (jsonrpc-request rpc :hello nil :timeout 10))
         (conn (rdev--make-conn :host host :rpc rpc
                                :home (plist-get hello :home)
                                :path (append (plist-get hello :path) nil)
                                :state 'ready
                                :proto (plist-get hello :protocol)
                                :caps (append (plist-get hello :capabilities) nil))))
    (puthash host conn rdev--conns)
    conn))

(defun rdev-test--disconnect (&optional host)
  (let ((host (or host "test")))
    (when-let* ((c (gethash host rdev--conns)))
      (ignore-errors (jsonrpc-shutdown (rdev-conn-rpc c) t))
      (remhash host rdev--conns))))

(defmacro rdev-test-with-server (&rest body)
  "Run BODY with host \"test\" connected to a fresh local agent."
  (declare (indent 0))
  `(progn
     (rdev-test--connect)
     (unwind-protect (progn ,@body)
       (rdev-test--disconnect))))

(defun rdev-test--populate (dir)
  "Create a small deterministic tree under DIR."
  (make-directory (expand-file-name "sub/deeper" dir) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file (expand-file-name "a.txt" dir) (insert "alpha\nbeta\n"))
    (with-temp-file (expand-file-name "sub/b.txt" dir) (insert "bee\n"))
    (with-temp-file (expand-file-name "unicode.txt" dir) (insert "héllo wörld ✓\n"))
    (with-temp-file (expand-file-name "empty" dir)))
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-file (expand-file-name "bin.dat" dir)
      (set-buffer-multibyte nil)
      (insert (apply #'unibyte-string (number-sequence 0 255)))))
  (make-symbolic-link "a.txt" (expand-file-name "link" dir) t)
  (make-symbolic-link "nonexistent" (expand-file-name "dangling" dir) t)
  (set-file-modes (expand-file-name "a.txt" dir) #o640)
  dir)

(defmacro rdev-test-with-twin-dir (vars &rest body)
  "Bind (NATIVE REMOTE) in VARS to two identical trees and run BODY.
NATIVE is an ordinary local directory; REMOTE is the same tree named
through /rdev:test: so handler results can be compared with Emacs's own."
  (declare (indent 1))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory
                    (make-temp-file "rdev-twin-" t)))
            (,(nth 0 vars) (file-name-as-directory
                            (rdev-test--populate (expand-file-name "native" ,root))))
            (,(nth 1 vars) (progn
                             (rdev-test--populate (expand-file-name "served" ,root))
                             (concat "/rdev:test:" (expand-file-name "served/" ,root)))))
       (rdev-test-with-server
         (unwind-protect (progn ,@body)
           (delete-directory ,root t))))))

(provide 'rdev-test-helpers)
;;; rdev-test-helpers.el ends here
