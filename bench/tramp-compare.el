;;; tramp-compare.el --- rdev vs TRAMP side by side (T106, SC-013)  -*- lexical-binding: t; -*-
;; Runs identical files/operations through /rdev:HOST: and /ssh:HOST: and prints
;; the median ratio.  Usage (host from env):
;;   RDEV_BENCH_HOST=devbox emacs -Q --batch -L . -l bench/tramp-compare.el
;; For shaped networks use bench/run.sh, which calls the same driver, then
;; `bench/compare.py --vs-tramp results.csv`.
(require 'rdev-bench)
(setenv "RDEV_BENCH_BACKENDS" "rdev,tramp")
(let ((out (make-temp-file "tramp-compare" nil ".csv")))
  (setenv "RDEV_BENCH_OUT" out)
  (setenv "RDEV_BENCH_ITER" (or (getenv "RDEV_BENCH_ITER") "10"))
  (rdev-bench-main)
  (let ((py (expand-file-name "compare.py" (file-name-directory load-file-name))))
    (with-temp-buffer
      (insert rdev-bench-header "\n")
      (insert-file-contents out)
      (let ((tmp (make-temp-file "tc" nil ".csv")))
        (write-region nil nil tmp nil 'silent)
        (call-process py nil standard-output nil "--vs-tramp" tmp)))))
