;;; rdev-handlers-attrs-test.el --- predicates/attributes vs native (T016)  -*- lexical-binding: t; -*-
(require 'rdev-test-helpers)

(defmacro rdev-test--same (fn &rest names)
  "Assert FN returns the same for each of NAMES under NATIVE and REMOTE."
  `(dolist (n ',names)
     (should (equal (,fn (concat native n)) (,fn (concat remote n))))))

(ert-deftest rdev-attrs-predicates-match-native ()
  (rdev-test-with-twin-dir (native remote)
    ;; Documented difference: `file-writable-p' on a dangling symlink is t
    ;; natively (the target could be created) but nil via rdev, because the
    ;; agent reports os.access() of the link target.  Pinned separately below.
    (dolist (n '("a.txt" "sub" "sub/" "link" "nonexistent" "empty" "sub/deeper"))
      (dolist (fn '(file-exists-p file-directory-p file-regular-p file-readable-p
                    file-writable-p file-accessible-directory-p))
        (should (equal (funcall fn (concat native n)) (funcall fn (concat remote n)))))
      (should (equal (and (file-symlink-p (concat native n)) t)
                     (and (file-symlink-p (concat remote n)) t))))))

(ert-deftest rdev-attrs-documented-difference-writable-dangling ()
  "Documented difference: dangling symlink is not writable via rdev."
  (rdev-test-with-twin-dir (native remote)
    (should (file-writable-p (concat native "dangling")))
    (should-not (file-writable-p (concat remote "dangling")))))

(ert-deftest rdev-attrs-symlink-target ()
  (rdev-test-with-twin-dir (native remote)
    (should (equal (file-symlink-p (concat native "link"))
                   (file-symlink-p (concat remote "link"))))
    (should (equal (file-symlink-p (concat remote "dangling")) "nonexistent"))))

(ert-deftest rdev-attrs-modes ()
  (rdev-test-with-twin-dir (native remote)
    (should (equal (file-modes (concat native "a.txt")) (file-modes (concat remote "a.txt"))))
    (should (equal (file-modes (concat native "link")) (file-modes (concat remote "link"))))
    (should-not (file-modes (concat remote "nonexistent")))))

(ert-deftest rdev-attrs-file-attributes-fields ()
  (rdev-test-with-twin-dir (native remote)
    (let ((n (file-attributes (concat native "a.txt")))
          (r (file-attributes (concat remote "a.txt"))))
      (should (equal (file-attribute-type n) (file-attribute-type r)))
      (should (equal (file-attribute-size n) (file-attribute-size r)))
      (should (equal (file-attribute-modes n) (file-attribute-modes r)))
      (should (equal (file-attribute-user-id n) (file-attribute-user-id r)))
      ;; Twin files are created at different instants: compare within 10 s.
      (should (< (abs (float-time (time-subtract (file-attribute-modification-time n)
                                                 (file-attribute-modification-time r))))
                 10)))
    (should (eq t (file-attribute-type (file-attributes (concat remote "sub")))))
    (should (equal "a.txt" (file-attribute-type (file-attributes (concat remote "link")))))
    (should-not (file-attributes (concat remote "nonexistent")))
    (should (stringp (file-attribute-user-id (file-attributes (concat remote "a.txt") 'string))))))

(ert-deftest rdev-attrs-truename ()
  (rdev-test-with-twin-dir (native remote)
    (should (equal (file-local-name (file-truename (concat remote "link")))
                   (concat (file-truename (file-local-name remote)) "a.txt")))
    (should (string-prefix-p "/rdev:test:" (file-truename (concat remote "link"))))))

(ert-deftest rdev-attrs-newer-than ()
  (rdev-test-with-twin-dir (native remote)
    (set-file-times (concat native "a.txt") (time-subtract (current-time) 100))
    (set-file-times (concat remote "a.txt") (time-subtract (current-time) 100))
    (should (equal (file-newer-than-file-p (concat native "sub/b.txt") (concat native "a.txt"))
                   (file-newer-than-file-p (concat remote "sub/b.txt") (concat remote "a.txt"))))
    (should (equal (file-newer-than-file-p (concat native "nonexistent") (concat native "a.txt"))
                   (file-newer-than-file-p (concat remote "nonexistent") (concat remote "a.txt"))))))

(ert-deftest rdev-attrs-access-file ()
  (rdev-test-with-twin-dir (native remote)
    (should-not (access-file (concat remote "a.txt") "x"))
    (should-error (access-file (concat remote "nonexistent") "x") :type 'file-missing)))

(provide 'rdev-handlers-attrs-test)
;;; rdev-handlers-attrs-test.el ends here
