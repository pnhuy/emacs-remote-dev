;;; rdev-handlers-io-test.el --- reading and writing (T017)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defun rdev-test--bytes (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'no-conversion))
      (insert-file-contents-literally file))
    (buffer-string)))

(ert-deftest rdev-io-insert-file-contents-matches-native ()
  (rdev-test-with-twin-dir (native remote)
    (dolist (n '("a.txt" "unicode.txt" "empty"))
      (should (equal (with-temp-buffer (insert-file-contents (concat native n)) (buffer-string))
                     (with-temp-buffer (insert-file-contents (concat remote n)) (buffer-string)))))))

(ert-deftest rdev-io-binary-roundtrip ()
  (rdev-test-with-twin-dir (native remote)
    (should (equal (rdev-test--bytes (concat native "bin.dat"))
                   (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (let ((coding-system-for-read 'no-conversion))
                       (insert-file-contents (concat remote "bin.dat")))
                     (buffer-string))))))

(ert-deftest rdev-io-beg-end ()
  (rdev-test-with-twin-dir (native remote)
    (should (equal (with-temp-buffer (insert-file-contents (concat native "a.txt") nil 2 7)
                                     (buffer-string))
                   (with-temp-buffer (insert-file-contents (concat remote "a.txt") nil 2 7)
                                     (buffer-string))))))

(ert-deftest rdev-io-replace ()
  (rdev-test-with-twin-dir (native remote)
    (with-temp-buffer
      (insert "old")
      (insert-file-contents (concat remote "a.txt") nil nil nil t)
      (should (equal (buffer-string) "alpha\nbeta\n")))))

(ert-deftest rdev-io-visit-sets-buffer-state ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "a.txt"))
      (unwind-protect
          (progn
            (should (equal buffer-file-name (concat remote "a.txt")))
            (should-not (buffer-modified-p))
            (should (verify-visited-file-modtime))
            (should (equal (buffer-string) "alpha\nbeta\n"))
            (should (equal default-directory remote)))
        (kill-buffer)))))

(ert-deftest rdev-io-visit-missing-file-new-buffer ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "brand-new.txt"))
      (unwind-protect
          (progn (should (equal buffer-file-name (concat remote "brand-new.txt")))
                 (should (= (buffer-size) 0)))
        (kill-buffer)))))

(ert-deftest rdev-io-save-roundtrip-and-encoding ()
  (rdev-test-with-twin-dir (native remote)
    (with-current-buffer (find-file-noselect (concat remote "unicode.txt"))
      (unwind-protect
          (progn (goto-char (point-max)) (insert "ünï ✓\n") (save-buffer)
                 (should-not (buffer-modified-p)))
        (kill-buffer)))
    (should (equal (decode-coding-string
                    (rdev-test--bytes (concat (file-local-name remote) "unicode.txt")) 'utf-8)
                   "héllo wörld ✓\nünï ✓\n"))))

(ert-deftest rdev-io-write-region-variants ()
  (rdev-test-with-twin-dir (native remote)
    (let ((f (concat remote "w.txt")) (nf (concat native "w.txt")))
      (write-region "one" nil f nil 'silent)
      (write-region "two" nil f t 'silent)
      (write-region "one" nil nf nil 'silent)
      (write-region "two" nil nf t 'silent)
      (should (equal (rdev-test--bytes (file-local-name f)) (rdev-test--bytes nf)))
      (should-error (write-region "x" nil f nil 'silent nil 'excl)
                    :type 'file-already-exists)
      (write-region "partial-body" nil f nil 'silent)
      (with-temp-buffer (insert "0123456789")
                        (write-region 3 6 f nil 'silent))
      (should (equal (rdev-test--bytes (file-local-name f)) "234")))))

(ert-deftest rdev-io-file-local-copy ()
  (rdev-test-with-twin-dir (native remote)
    (let ((tmp (file-local-copy (concat remote "bin.dat"))))
      (unwind-protect
          (should (equal (rdev-test--bytes tmp) (rdev-test--bytes (concat native "bin.dat"))))
        (delete-file tmp)))))

(ert-deftest rdev-io-missing-file-signals ()
  (rdev-test-with-twin-dir (native remote)
    (should-error (insert-file-contents (concat remote "nonexistent")) :type 'file-missing)
    (should-error (file-local-copy (concat remote "nonexistent")) :type 'file-missing)))

(provide 'rdev-handlers-io-test)
;;; rdev-handlers-io-test.el ends here
