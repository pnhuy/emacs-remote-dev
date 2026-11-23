;;; rdev-load-order-test.el --- T129: rdev-state.el must not require rdev  -*- lexical-binding: t; -*-
(require 'ert)

(ert-deftest rdev-state-loads-without-rdev ()
  "A fresh Emacs can load rdev-state alone and `rdev' stays unloaded."
  (let* ((dir (file-name-directory (locate-library "rdev")))
         (out (with-temp-buffer
                (call-process (expand-file-name invocation-name invocation-directory)
                              nil t nil "-Q" "--batch" "-L" dir
                              "--eval" "(progn (require 'rdev-state) (princ (if (featurep 'rdev) \"LOADED\" \"CLEAN\")))")
                (buffer-string))))
    (should (string-match-p "CLEAN\\'" out))))

(ert-deftest rdev-state-source-has-no-require-rdev ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "rdev-state.el"
                                            (file-name-directory (locate-library "rdev"))))
    (goto-char (point-min))
    (should-not (re-search-forward "(require 'rdev\\_>" nil t))))

(provide 'rdev-load-order-test)
