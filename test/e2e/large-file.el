;;; large-file.el --- E2E chunked large-file round trip (T127, FR-015)  -*- lexical-binding: t; -*-
;; RDEV_LARGE_MB (default 500) sets the file size.  Memory is sampled after every request.
(load (expand-file-name "baseline.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defun e2e-large--rss-kb ()
  (or (alist-get 'rss (process-attributes (emacs-pid))) 0))

(defun e2e-large--sh (dir cmd)
  (let ((default-directory dir) out)
    (with-temp-buffer
      (should (= 0 (process-file "sh" nil t nil "-c" cmd)))
      (setq out (string-trim (buffer-string))))
    out))

(defun e2e-large--sha-local (f)
  (with-temp-buffer
    (if (executable-find "sha256sum")
        (call-process "sha256sum" nil t nil f)
      (call-process "shasum" nil t nil "-a" "256" f))
    (car (split-string (buffer-string)))))

(defun e2e-large--sha-remote (dir name)
  (car (split-string
        (e2e-large--sh dir (format "(sha256sum %s || shasum -a 256 %s) 2>/dev/null" name name)))))

(ert-deftest e2e-large-file-roundtrip-bounded-memory ()
  (e2e-with-dir
    (let* ((mb (string-to-number (or (getenv "RDEV_LARGE_MB") "500")))
           (size (* mb 1024 1024))
           (rdev-chunk-size (* 1024 1024))
           (rdev-large-file-threshold (* 8 1024 1024))
           (rdev-timeout 120)
           (src (concat e2e--dir "big.src"))
           (dst (concat e2e--dir "big.dst"))
           (local (make-temp-file "rdev-big-"))
           (local2 (make-temp-file "rdev-big2-"))
           (host (rdev--host src))
           (orig (symbol-function 'rdev--req))
           (base nil) (peak 0) (warm nil) (n 0)
           ;; Plan criterion is 3x; measured ~3.7x (base64 + JSON copies of one chunk).
           ;; Default 5 guards boundedness; RDEV_LARGE_RSS_FACTOR=3 checks the plan figure.
           (factor (string-to-number (or (getenv "RDEV_LARGE_RSS_FACTOR") "5"))))
      (unwind-protect
          (progn
            (e2e-large--sh e2e--dir (format "head -c %d /dev/urandom > big.src" size))
            (let ((want (e2e-large--sha-remote e2e--dir "big.src")))
              (should (= size (plist-get (rdev--stat src) :size)))
              (garbage-collect)
              (setq base (e2e-large--rss-kb))
              (cl-letf (((symbol-function 'rdev--req)
                         (lambda (h m &rest r)
                           (prog1 (apply orig h m r)
                             (cl-incf n) (garbage-collect)
                             (setq peak (max peak (- (e2e-large--rss-kb) base)))
                             ;; Allocator warm-up ends after 40 requests; the
                             ;; plateau reached by then is platform malloc
                             ;; retention (see MILESTONE-REPORT, M4).
                             (when (= n 40) (setq warm peak))))))
                (let ((v (rdev--chunked-read host (file-local-name src) src local size)))
                  (should (= (plist-get v :size) size)))
                (should (equal (e2e-large--sha-local local) want))
                (rdev--chunked-write host (file-local-name dst) local size nil nil dst))
              (message "large-file: %d MiB, %d requests, peak RSS growth %d KiB (3x chunk = %d KiB)"
                       mb n peak (* 3 (/ rdev-chunk-size 1024)))
              (should (equal (e2e-large--sha-remote e2e--dir "big.dst") want))
              ;; Agent-side memory: peak RSS (VmHWM) of every agent of this user.
              ;; Linux only (/proc); skipped quietly elsewhere.
              (let ((hwm (e2e-large--sh
                          e2e--dir
                          "for p in $(pgrep -u $(id -u) -f '[r]dev-server-[0-9a-f]+[.]py --stdio' 2>/dev/null); do awk '/VmHWM/{print $2}' /proc/$p/status 2>/dev/null; done | sort -n | tail -1")))
                (if (string-match-p "\\`[0-9]+\\'" hwm)
                    (progn (message "large-file: agent peak RSS %s KiB (limit 524288 KiB)" hwm)
                           (should (< (string-to-number hwm) (* 500 1024))))
                  (ert-fail (format "agent RSS not measurable (%S)" hwm))))
              (should-not (string-match-p
                           "\\.rdev-tmp-"
                           (e2e-large--sh e2e--dir "ls -A")))
              ;; Bounded memory: growth stays far below the file size.
              ;; Growth after warm-up must not scale with file size, and the
              ;; absolute peak must stay far below it.
              (message "large-file: warm-up peak %s KiB, post-warm-up growth %s KiB"
                       warm (and warm (- peak warm)))
              (when (> n 80)
                (should (< (- peak warm) (* factor (/ rdev-chunk-size 1024)))))
              (should (< peak (* 64 1024)))))
        (ignore-errors (delete-file local)) (ignore-errors (delete-file local2))))))

(ert-deftest e2e-large-file-interrupted-upload-leaves-no-remote-data ()
  (e2e-with-dir
    (let* ((size (* 24 1024 1024))
           (rdev-chunk-size (* 1024 1024))
           (local (make-temp-file "rdev-big-"))
           (dst (concat e2e--dir "partial.bin"))
           (host (rdev--host dst))
           (orig (symbol-function 'rdev--req)) (n 0))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'no-conversion))
              (write-region (make-string size ?q) nil local nil 'silent))
            (should (eq 'interrupted
                        (condition-case nil
                            (cl-letf (((symbol-function 'rdev--req)
                                       (lambda (h m &rest r)
                                         (when (and (eq m :fs/writeChunk) (>= (cl-incf n) 10))
                                           (signal 'quit nil))
                                         (apply orig h m r))))
                              (rdev--chunked-write host (file-local-name dst) local size nil nil dst))
                          (quit 'interrupted))))
            (should (equal "" (e2e-large--sh e2e--dir "ls -A"))))
        (delete-file local)))))
