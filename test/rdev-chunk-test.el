;;; rdev-chunk-test.el --- chunked large-file transfer (T042)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)
(setq make-backup-files nil)

(defun rdev-chunk--slurp (f)
  (with-temp-buffer (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion)) (insert-file-contents-literally f))
    (buffer-string)))

(defmacro rdev-chunk--small (&rest body)
  "Run BODY with tiny thresholds so every file takes the chunked path."
  `(let ((rdev-large-file-threshold 100) (rdev-chunk-size 1000))
     ,@body))

(defun rdev-chunk--calls (&rest body-fn)
  "Return list of RPC methods issued while running BODY-FN."
  (let (seen (orig (symbol-function 'rdev--req)))
    (cl-letf (((symbol-function 'rdev--req)
               (lambda (host method &rest r) (push method seen) (apply orig host method r))))
      (funcall (car body-fn)))
    (nreverse seen)))

(ert-deftest rdev-chunk-read-large-file-is-chunked-and-exact ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-chunk--small
     (let* ((data (apply #'unibyte-string (mapcar (lambda (i) (% (* i 7) 256))
                                                  (number-sequence 0 9999))))
            (f (concat (file-local-name remote) "big.bin")))
       (let ((coding-system-for-write 'no-conversion)) (write-region data nil f nil 'silent))
       (let (got calls)
         (setq calls (rdev-chunk--calls
                      (lambda ()
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (let ((coding-system-for-read 'no-conversion))
                            (insert-file-contents (concat remote "big.bin")))
                          (setq got (buffer-string))))))
         (should (equal got data))
         (should (>= (cl-count :fs/readChunk calls) 10))
         (should-not (memq :fs/read calls)))))))

(ert-deftest rdev-chunk-small-file-stays-single-request ()
  (rdev-test-with-twin-dir (native remote)
    (let ((calls (rdev-chunk--calls
                  (lambda () (with-temp-buffer (insert-file-contents (concat remote "a.txt")))))))
      (should (memq :fs/read calls))
      (should-not (memq :fs/readChunk calls)))))

(ert-deftest rdev-chunk-save-roundtrip-and-no-temp-left ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-chunk--small
     (let ((text (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 1 800) "")))
       (with-current-buffer (find-file-noselect (concat remote "a.txt"))
         (unwind-protect
             (let (calls)
               (erase-buffer) (insert text)
               (setq calls (rdev-chunk--calls #'save-buffer))
               (should (memq :fs/beginWrite calls))
               (should (memq :fs/commitWrite calls))
               (should-not (memq :fs/writeAtomic calls))
               (should (equal (rdev-chunk--slurp (concat (file-local-name remote) "a.txt")) text))
               (should-not (cl-remove-if-not (lambda (n) (string-prefix-p ".rdev-tmp-" n))
                                             (directory-files (file-local-name remote))))
               (should rdev--version))
           (set-buffer-modified-p nil) (kill-buffer)))))))

(ert-deftest rdev-chunk-save-conflict-is-detected ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-chunk--small
     (with-current-buffer (find-file-noselect (concat remote "a.txt"))
       (unwind-protect
           (let ((f (concat (file-local-name remote) "a.txt"))
                 (rdev-conflict-functions nil))
             (sleep-for 0.02)
             (with-temp-file f (insert "external\n"))
             (erase-buffer) (insert (make-string 5000 ?x))
             (should-error (save-buffer) :type 'rdev-conflict)
             (should (equal (rdev-chunk--slurp f) "external\n"))
             (should (buffer-modified-p))
             (should-not (cl-remove-if-not (lambda (n) (string-prefix-p ".rdev-tmp-" n))
                                           (directory-files (file-local-name remote)))))
         (set-buffer-modified-p nil) (kill-buffer))))))

(ert-deftest rdev-chunk-quit-mid-upload-aborts-cleanly ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-chunk--small
     (let* ((f (concat (file-local-name remote) "a.txt"))
            (before (rdev-chunk--slurp f))
            (src (make-temp-file "rdev-src-"))
            (n 0) (orig (symbol-function 'rdev--req)))
       (unwind-protect
           (progn
             (let ((coding-system-for-write 'no-conversion))
               (write-region (make-string 5000 ?z) nil src nil 'silent))
             (cl-letf (((symbol-function 'rdev--req)
                        (lambda (host method &rest r)
                          (when (and (eq method :fs/writeChunk) (>= (cl-incf n) 3))
                            (signal 'quit nil))
                          (apply orig host method r))))
               (should (eq 'quit-seen
                           (condition-case nil
                               (rdev--chunked-write "test" f src 5000 nil nil remote)
                             (quit 'quit-seen)))))
             (should (equal (rdev-chunk--slurp f) before))
             (should-not (cl-remove-if-not (lambda (x) (string-prefix-p ".rdev-tmp-" x))
                                           (directory-files (file-local-name remote)))))
         (delete-file src))))))

(ert-deftest rdev-chunk-legacy-agent-falls-back ()
  (rdev-test-with-twin-dir (native remote)
    (rdev-chunk--small
     (let ((c (rdev--conn "test")))
       (let ((saved (rdev-conn-caps c)))
         (unwind-protect
             (progn
               (setf (rdev-conn-caps c) (remove "fs.chunk" saved))
               (let ((calls (rdev-chunk--calls
                             (lambda () (with-temp-buffer (insert-file-contents (concat remote "a.txt")))))))
                 (should (memq :fs/read calls))
                 (should-not (memq :fs/readChunk calls))))
           (setf (rdev-conn-caps c) saved)))))))

(provide 'rdev-chunk-test)
