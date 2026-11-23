;;; rdev-project.el --- project.el integration for RDEV  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Huy Pham

;;; Commentary:

;; Makes a remote directory behave like an ordinary `project.el' project.
;;
;; * `rdev-project-find' is added to `project-find-functions'; it asks the
;;   agent (`project/root') for the enclosing project and returns
;;   (rdev . ROOT), ROOT being a /rdev:HOST:/path directory name.
;; * `project-files' on such a project is answered by the agent
;;   (`project/files': git, then rg, then a plain walk), so a listing costs
;;   one round trip and transfers names only.
;; * Remote projects can be remembered for `project-switch-project' with
;;   `rdev-project-remember'.
;;
;; When the agent lacks the `project.root' capability the finder returns nil
;; and the next entry in `project-find-functions' (normally the VC backend)
;; decides, so nothing changes for old agents.  The root cache is dropped
;; when a connection is re-established (`rdev-reconnected-hook').

;;; Code:

(require 'rdev)
(require 'project)
(require 'cl-lib)

(defgroup rdev-project nil "Project.el integration for RDEV." :group 'rdev)

(defcustom rdev-project-markers nil
  "File names that mark a project root, or nil for the agent's defaults.
VCS directories (.git, .hg, .svn) always win over other markers."
  :type '(choice (const :tag "Agent defaults" nil)
                 (repeat string))
  :group 'rdev-project)

(defcustom rdev-project-cache-ttl 30
  "Seconds a discovered project root is reused before asking the agent again."
  :type 'number :group 'rdev-project)

(defvar rdev-project--cache (make-hash-table :test #'equal)
  "Directory name -> (EXPIRY-TIME . ROOT-OR-NIL).")

(defun rdev-project-clear-cache ()
  "Forget every cached project root."
  (interactive)
  (clrhash rdev-project--cache))

(defun rdev-project--lookup (dir)
  "Return the project root name for remote directory DIR, or nil."
  (let ((hit (gethash dir rdev-project--cache)))
    (if (and hit (< (float-time) (car hit)))
        (cdr hit)
      (let* ((host (rdev--host dir))
             (conn (rdev--conn host))
             (root
              (when (rdev-conn-has-cap conn "project.root")
                (let ((res (rdev--req
                            host :project/root
                            (append `(:path ,(file-local-name dir))
                                    (and rdev-project-markers
                                         `(:markers ,(vconcat rdev-project-markers))))
                            dir)))
                  (when (stringp (plist-get res :root))
                    (file-name-as-directory
                     (concat (rdev--prefix host) (plist-get res :root))))))))
        (puthash dir (cons (+ (float-time) rdev-project-cache-ttl) root)
                 rdev-project--cache)
        root))))

;;;###autoload
(defun rdev-project-find (dir)
  "`project-find-functions' entry: return (rdev . ROOT) for remote DIR, or nil.
Local and non-RDEV directories are left to the other finders."
  (when (and (stringp dir) (rdev--parse (expand-file-name dir)))
    (let ((root (condition-case nil
                    (rdev-project--lookup (file-name-as-directory
                                           (expand-file-name dir)))
                  (error nil))))
      (and root (cons 'rdev root)))))

(cl-defmethod project-root ((project (head rdev)))
  (cdr project))

(cl-defmethod project-files ((project (head rdev)) &optional dirs)
  "List PROJECT's files as absolute /rdev: names using the agent.
With DIRS, keep only files below one of those directories."
  (let* ((root (cdr project))
         (host (rdev--host root))
         (rel (rdev--req host :project/files `(:root ,(file-local-name root)) root))
         (all (mapcar (lambda (f) (concat root f)) (append rel nil))))
    (if (null dirs)
        all
      (let ((prefixes (mapcar (lambda (d) (file-name-as-directory (expand-file-name d)))
                              dirs)))
        (cl-remove-if-not
         (lambda (f) (cl-some (lambda (p) (string-prefix-p p f)) prefixes))
         all)))))

;;;###autoload
(defun rdev-project-remember (&optional dir)
  "Remember the remote project containing DIR for `project-switch-project'."
  (interactive)
  (let* ((dir (or dir default-directory))
         (pr (and (rdev--parse (expand-file-name dir))
                  (project-current nil dir))))
    (unless pr (user-error "No RDEV project at %s" dir))
    (project-remember-project pr)
    pr))

(defun rdev-project--on-reconnect (_key)
  "Drop cached roots so project context is re-derived on the new connection."
  (rdev-project-clear-cache))

(add-hook 'rdev-reconnected-hook #'rdev-project--on-reconnect)
;; Ahead of the VC finder, so a remote project is described by the agent.
(add-hook 'project-find-functions #'rdev-project-find)

(provide 'rdev-project)
;;; rdev-project.el ends here
