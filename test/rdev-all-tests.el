;;; rdev-all-tests.el --- load every RDEV ERT test file  -*- lexical-binding: t; -*-
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path dir)
  (dolist (f (directory-files dir t "\\`rdev-.*-test\\.el\\'"))
    (load f nil t)))
;;; rdev-all-tests.el ends here
