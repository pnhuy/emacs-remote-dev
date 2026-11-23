;;; rdev-search.el --- Remote project search for RDEV  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Huy Pham

;;; Commentary:

;; Client for the agent's `search/grep' method (ripgrep when installed on the
;; remote host, a Python fallback otherwise).  The search runs on the remote
;; host; only matches travel over the connection.  \\[keyboard-quit] cancels
;; the search on the agent (`$/cancel').
;;
;; Entry points:
;;   `rdev-search'      -- programmatic API, returns a plist.
;;   `rdev-grep'        -- interactive; results in a `grep-mode'-style buffer.
;;   `rdev-consult-grep' -- optional Consult front end; needs the `consult'
;;                      package, which is never loaded or required otherwise.
;;
;; Optional tools (rg) are never required: the agent falls back to Python and
;; reports which engine produced the result.

;;; Code:

(require 'rdev)
(require 'project)
(require 'cl-lib)
(require 'compile)

(defgroup rdev-search nil "Remote search." :group 'rdev)

(defcustom rdev-search-max-results 1000
  "Maximum number of matches `rdev-search' asks the agent for."
  :type 'integer :group 'rdev-search)

(defcustom rdev-search-context 0
  "Lines of context around each match (0-5)."
  :type 'integer :group 'rdev-search)

(defun rdev-search (dir pattern &rest opts)
  "Search PATTERN under remote directory DIR; return a result plist.
DIR is a `/rdev:HOST:/path' name.  OPTS may contain :regex :case
\(`smart', `sensitive' or `insensitive'), :globs (list), :ignore, :hidden,
:max-results, :context and :on-match, a function called with each batch (a
list of match plists) as it arrives.

The result is (:matches LIST :count N :truncated BOOL :engine STRING).  Each
match is (:path REL :line N :col N :text STR :submatches ((S E)...)
\[:context t])."
  (unless (rdev--parse dir)
    (user-error "rdev-search needs an /rdev: directory, got %s" dir))
  (let* ((host (rdev--host dir))
         (root (file-local-name (expand-file-name dir)))
         (conn (rdev--conn host))
         (acc nil)
         (on-match (plist-get opts :on-match))
         (rdev-search-result-function
          (lambda (params)
            (let ((batch (append (plist-get params :matches) nil)))
              (setq acc (nconc acc batch))
              (when on-match (funcall on-match batch)))))
         res)
    (unless (rdev-conn-has-cap conn "search.grep")
      (user-error "The agent on %s does not support search (update the agent)" host))
    (setq res (rdev--req
               host :search/grep
               (append
                `(:root ,root :pattern ,pattern :stream t
                  :regex ,(if (plist-get opts :regex) t :json-false)
                  :case ,(symbol-name (or (plist-get opts :case) 'smart))
                  :max_results ,(or (plist-get opts :max-results)
                                    rdev-search-max-results)
                  :context ,(or (plist-get opts :context) rdev-search-context)
                  :ignore ,(if (plist-member opts :ignore)
                               (or (plist-get opts :ignore) :json-false)
                             t)
                  :hidden ,(if (plist-get opts :hidden) t :json-false))
                (and (plist-get opts :globs)
                     `(:globs ,(vconcat (plist-get opts :globs)))))
               dir))
    (list :matches acc
          :count (plist-get res :count)
          :truncated (eq t (plist-get res :truncated))
          :engine (plist-get res :engine))))

;;;###autoload
(defun rdev-grep (pattern &optional regex)
  "Search for PATTERN in the current remote project or directory.
With a prefix argument REGEX, treat PATTERN as a regular expression."
  (interactive (list (read-string "Search: " (thing-at-point 'symbol t))
                     current-prefix-arg))
  (let* ((dir (rdev-search--default-dir))
         (res (rdev-search dir pattern :regex regex))
         (buf (get-buffer-create "*rdev-grep*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory dir)
        (insert (format "-*- mode: grep; default-directory: %S -*-\n" dir))
        (dolist (m (plist-get res :matches))
          (insert (format "%s:%d:%d:%s\n" (plist-get m :path) (plist-get m :line)
                          (plist-get m :col) (plist-get m :text))))
        (insert (format "\n%d match(es) [%s]%s\n" (plist-get res :count)
                        (plist-get res :engine)
                        (if (plist-get res :truncated) " (truncated)" "")))
        (grep-mode)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Optional Consult adapter

(declare-function consult--read "consult")
(declare-function consult--dynamic-collection "consult")

(defun rdev-search--default-dir (&optional dir)
  "DIR, else the current project root, else `default-directory'."
  (expand-file-name
   (or dir
       (and (fboundp 'project-current)
            (when-let* ((pr (project-current))) (project-root pr)))
       default-directory)))

(defun rdev-search--consult-candidates (dir input)
  "Candidate strings (REL:LINE:TEXT) for INPUT searched under remote DIR.
Each carries the property `rdev-match', a list (FILE LINE COLUMN) where FILE
is a full `/rdev:' name.  Returns nil for an empty INPUT."
  (when (and input (> (length input) 0))
    (mapcar (lambda (m)
              (let ((rel (plist-get m :path)) (line (plist-get m :line)))
                (propertize (format "%s:%d:%s" rel line (plist-get m :text))
                            'rdev-match (list (expand-file-name rel dir) line
                                              (plist-get m :col)))))
            (plist-get (rdev-search dir input) :matches))))

(defun rdev-search--visit (cand)
  "Visit the match described by candidate string CAND."
  (when-let* ((m (and cand (get-text-property 0 'rdev-match cand))))
    (pcase-let ((`(,file ,line ,col) m))
      (find-file file)
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column (max 0 (1- (or col 1)))))))

;;;###autoload
(defun rdev-consult-grep (&optional dir initial)
  "Search the remote project under DIR with Consult, running on the remote host.
INITIAL is the initial input.  Requires the optional `consult' package; the
search itself is `rdev-search', so ripgrep or the Python fallback runs on the
host and only matches travel over the connection."
  (interactive)
  (unless (require 'consult nil t)
    (user-error "rdev-consult-grep needs the `consult' package (use `rdev-grep' without it)"))
  (let* ((dir (rdev-search--default-dir dir)))
    (unless (rdev--parse dir)
      (user-error "rdev-consult-grep needs an /rdev: directory, got %s" dir))
    (rdev-search--visit
     (consult--read
      (consult--dynamic-collection
          (lambda (input) (rdev-search--consult-candidates dir input))
        :min-input 2 :throttle 0.3 :debounce 0.2)
      :prompt "Remote grep: " :initial initial :require-match t
      :category 'consult-grep :sort nil
      :lookup (lambda (selected candidates &rest _)
                (car (member selected candidates)))))))

(provide 'rdev-search)
;;; rdev-search.el ends here
