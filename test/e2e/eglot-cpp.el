;;; eglot-cpp.el --- E2E Eglot with a real clangd on the remote host (T098, FR-025, SC-011)  -*- lexical-binding: t; -*-
;; Needs `clangd' on the remote PATH (tests skip with a visible reason otherwise).
(load (expand-file-name "eglot-common.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(require 'cc-mode)

(defmacro e2e-ec-with-server (&rest body)
  "Run BODY with `proj', `main', `hdr' and `server' bound for a fresh remote C++ project."
  (declare (indent 0))
  `(progn
     (unless (e2e-eg--remote-has "clangd") (ert-skip "clangd is not installed on the remote host"))
     (e2e-with-dir
       (let* ((proj (concat e2e--dir "cproj/")) (vc-handled-backends nil)
              (main (concat proj "main.cpp")) (hdr (concat proj "util.h"))
              (cc (concat proj "compile_commands.json"))
              server)
         (make-directory proj t)
         (write-region "" nil (concat proj ".project") nil 'silent)
         (write-region "#pragma once\nint add_numbers(int a, int b);\n" nil hdr nil 'silent)
         (write-region (concat "#include \"util.h\"\n\nint add_numbers(int a, int b) { return a + b; }\n\n"
                               "int main() {\n  int total = add_numbers(1, 2);\n  return total;\n}\n")
                       nil main nil 'silent)
         (write-region (format "[{\"directory\":%S,\"command\":\"c++ -std=c++17 -c main.cpp\",\"file\":%S}]\n"
                               (file-local-name (directory-file-name proj))
                               (file-local-name main))
                       nil cc nil 'silent)
         (rdev-project-clear-cache)
         (unwind-protect
             (progn (setq server (e2e-eg--start main '("clangd" "--log=error" "--background-index=false")))
                    ,@body)
           (e2e-eg--shutdown server)
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p e2e--dir (buffer-file-name b)))
               (with-current-buffer b (set-buffer-modified-p nil))
               (kill-buffer b))))))))

(ert-deftest e2e-eglot-cpp-server-runs-on-remote ()
  (e2e-ec-with-server
    (should (jsonrpc-running-p server))
    (should (string-prefix-p "/rdev:" (file-name-as-directory (project-root (eglot--project server)))))))

(ert-deftest e2e-eglot-cpp-definition ()
  (e2e-ec-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "add_numbers(1")
      (let* ((defs (xref-backend-definitions (xref-find-backend) "add_numbers"))
             (groups (mapcar (lambda (d) (xref-location-group (xref-item-location d))) defs)))
        (should defs)
        (should (cl-every (lambda (g) (string-prefix-p "/rdev:" g)) groups))
        (should (member main groups))))))

(ert-deftest e2e-eglot-cpp-references ()
  (e2e-ec-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "add_numbers(1")
      (let ((refs (xref-backend-references (xref-find-backend) "add_numbers")))
        (should (>= (length refs) 2))))))

(ert-deftest e2e-eglot-cpp-completion ()
  (e2e-ec-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "return total;")
      (goto-char (match-beginning 0))
      (insert "add_n")
      (eglot--signal-textDocument/didChange)
      (let* ((capf (eglot-completion-at-point))
             (cands (and capf (all-completions "add_n" (nth 2 capf)))))
        (should capf)
        (should (cl-some (lambda (c) (string-prefix-p "add_numbers" c)) cands))))))

(ert-deftest e2e-eglot-cpp-rename ()
  (e2e-ec-with-server
    (with-current-buffer (get-file-buffer main)
      (e2e-eg--goto "total = add")
      (let ((inhibit-message t) (make-backup-files nil) (eglot-confirm-server-edits nil))
        (re-search-forward "total") (backward-word)
        (eglot-rename "sum")
        (save-some-buffers t)
        (let ((txt (with-temp-buffer (insert-file-contents main) (buffer-string))))
          (should (string-match-p "int sum = add_numbers" txt))
          (should (string-match-p "return sum;" txt))
          (should-not (string-match-p "total" txt)))))))

(ert-deftest e2e-eglot-cpp-diagnostics-and-fixit ()
  "A real compile error shows up, and clangd offers a fix-it code action for it."
  (e2e-ec-with-server
    (with-current-buffer (get-file-buffer main)
      ;; Missing semicolon: clangd reports it and offers a fix-it.
      (e2e-eg--goto "return total;")
      (re-search-forward "total;") (delete-char -1)
      (eglot--signal-textDocument/didChange)
      (flymake-mode 1) (flymake-start)
      (should (e2e-eg--wait (lambda () (flymake-diagnostics)) 30))
      (let ((diag (car (flymake-diagnostics))))
        (should (string-match-p "expected\\|semicolon" (flymake-diagnostic-text diag)))
        (goto-char (flymake-diagnostic-beg diag))
        (let ((acts (e2e-eg--wait-value
                     (lambda () (eglot-code-actions (flymake-diagnostic-beg diag) (flymake-diagnostic-end diag) nil nil))
                     (lambda (a) (and a (listp a))) 20)))
          (should acts)
          (should (cl-some (lambda (a) (string-match-p "semicolon\\|;\\|insert" (or (plist-get a :title) ""))) acts)))))))
