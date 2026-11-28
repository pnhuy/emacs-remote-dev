;;; rdev-docker-test.el --- Docker transport, identity, discovery and root policy  -*- lexical-binding: t; -*-

;; Unit tests for the Docker transport.  The transport runs the
;; REAL agent through test/fixtures/fake-docker (which execs the bootstrap
;; locally), so the whole stack — session keys, bootstrap, root policy, file
;; handlers, relay, reconnect and replacement — is exercised without ssh or a
;; Docker daemon.  Real-daemon behavior is covered by test/e2e/docker.el.

(require 'rdev-test-helpers)
(require 'rdev-docker)
(require 'rdev-ui)

(defconst rdev-docker-test--fake
  (expand-file-name "test/fixtures/fake-docker" rdev-test--root))

(defconst rdev-docker-test--home (make-temp-file "rdev-docker-home-" t)
  "Temp HOME used as the \"container\" user's home for helper installs.")

(defun rdev-docker-test--fresh ()
  "Reset all connection/session bookkeeping for one test."
  (setq rdev--conns (make-hash-table :test #'equal)
        rdev--chans (make-hash-table :test #'equal)
        rdev--gens (make-hash-table :test #'equal)
        rdev--key-hosts (make-hash-table :test #'equal)
        rdev--host-keys (make-hash-table :test #'equal)
        rdev-state--table (make-hash-table :test #'equal)
        rdev-state--timers (make-hash-table :test #'equal)
        rdev-state--attempts (make-hash-table :test #'equal)
        rdev-state--keys (make-hash-table :test #'equal))
  (clrhash rdev-docker--info)
  (rdev-docker--reset-discovery))

(defun rdev-docker-test--env-apply (pairs)
  "Prepend PAIRS ((NAME . VALUE)...) to `process-environment'; return the old one."
  (let ((old process-environment))
    (setq process-environment
          (append (mapcar (lambda (p) (concat (car p) "=" (cdr p))) pairs)
                  process-environment))
    old))

(defmacro rdev-docker-test--with-env (pairs &rest body)
  "Run BODY with child-process environment additions PAIRS, then restore.
Scoping matters: FAKE_DOCKER_* variables must never leak into later tests
or into the reconnect timers of other sessions."
  (declare (indent 1))
  `(let ((saved (rdev-docker-test--env-apply ,pairs)))
     (unwind-protect (progn ,@body)
       (setq process-environment saved))))

(defmacro rdev-docker-test--with-spec (spec &rest body)
  "Run BODY with HOST \"dk\" configured as SPEC (a Docker target)."
  (declare (indent 1))
  `(let ((rdev-hosts (list (cons "dk" ,spec)))
         (rdev-docker-program rdev-docker-test--fake))
     ,@body))

(defun rdev-docker-test--transport (host)
  "The transport process behind HOST's jsonrpc connection, or nil."
  (when-let* ((c (gethash host rdev--conns)))
    (ignore-errors (jsonrpc--process (rdev-conn-rpc c)))))

(defun rdev-docker-test--chan-of (proc)
  "The `rdev-chan' whose local relay process is PROC."
  (catch 'found
    (maphash (lambda (_k c) (when (eq (rdev-chan-proc c) proc) (throw 'found c)))
             rdev--chans)
    nil))

(defun rdev-docker-test--wait (pred &optional timeout)
  "Accept process output until PRED is true or TIMEOUT (default 10) elapses."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun rdev-docker-test--log-contains (key regexp)
  "Non-nil when the log buffer of session KEY matches REGEXP."
  (when-let* ((b (get-buffer (format "*rdev-log %s*" key))))
    (with-current-buffer b (string-match-p regexp (buffer-string)))))

(defun rdev-docker-test--reason (err)
  "The `rdev-docker-error' reason carried by ERT's `should-error' value ERR.
The error data is (MESSAGE REASON), so the reason is the last element and
the human-readable message is the first."
  (car (last err)))

(defmacro rdev-docker-test--with-target (&rest body)
  "Run BODY with the fake Docker target \"dk\" and its environment bound.
The binding must cover the whole test, not just the connect: reconnect
timers, `rdev-disconnect' and cleanup all resolve the target again."
  (declare (indent 0))
  `(rdev-docker-test--with-spec '(:transport docker :container "fakec")
     (rdev-docker-test--with-env
         (list (cons "HOME" rdev-docker-test--home)
               (cons "FAKE_DOCKER_PS_COUNT_FILE" ""))
       ,@body)))

(defun rdev-docker-test--connect-dk ()
  "Connect host \"dk\" through the fake Docker transport; return the conn.
Call inside `rdev-docker-test--with-target' so the target stays configured
for reconnect timers and cleanup."
  (rdev-docker-test--fresh)
  (rdev--connect "dk"))

(defmacro rdev-docker-test--cleanup (&rest body)
  "Run BODY, always disconnecting \"dk\" and resetting state afterwards."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (ignore-errors (rdev-disconnect "dk"))
     (rdev-docker-test--fresh)))

;;;; Configuration and validation

(ert-deftest rdev-docker-configuration-defaults ()
  (should (equal rdev-docker-program "docker"))
  (should (= rdev-docker-discovery-ttl 5))
  (should (= rdev-docker-discovery-max 200))
  (should (= rdev-docker-probe-timeout 10)))

(ert-deftest rdev-docker-name-and-user-validation ()
  (should (equal (rdev-docker--validate-name "my.container_1") "my.container_1"))
  (should (equal (rdev-docker--validate-name "0123abcdef9876") "0123abcdef9876"))
  (should-error (rdev-docker--validate-name "-x"))
  (should-error (rdev-docker--validate-name "a b"))
  (should-error (rdev-docker--validate-name "a;rm"))
  (should (equal (rdev-docker--validate-user "dev") "dev"))
  (should (equal (rdev-docker--validate-user "1000") "1000"))
  (should (equal (rdev-docker--validate-user "dev:dev") "dev:dev"))
  (should-error (rdev-docker--validate-user "-u"))
  (should-error (rdev-docker--validate-user "d v")))

(ert-deftest rdev-docker-host-predicates ()
  (let ((rdev-hosts '(("dk" . (:transport docker :container "c1"))
                      ("ssh1" . nil))))
    (should (rdev--docker-p "dk"))
    (should-not (rdev--docker-p "ssh1"))
    (should-not (rdev--docker-p "unknown"))
    (should (rdev--any-docker-target-p)))
  (let ((rdev-hosts nil))
    (should-not (rdev--any-docker-target-p))))

;;;; Bootstrap script parameterization

(ert-deftest rdev-docker-bootstrap-parameterization ()
  (should (equal (rdev--bootstrap-script) rdev--bootstrap-template))
  (let ((plain rdev--bootstrap-template))
    (should (string-match-p "D=\"\\$HOME/\\.cache/rdev\"" plain))
    (should-not (string-match-p "/tmp/rdev-" plain))
    (should-not (string-match-p "allow-root" plain)))
  (let ((fallback (rdev--bootstrap-script t " --allow-root")))
    (should (string-match-p "B=\"/tmp/rdev-\\$(id -u)\"; D=\"\\$B/rdev\"" fallback))
    (should (string-match-p "\\[ -O \"\\$B\" \\]" fallback))
    (should (string-match-p "exec \"\\$P\" -u \"\\$F\" --stdio --allow-root" fallback))
    ;; The verification core (size + sha256) is identical in both variants.
    (should (string-match-p "v() {" fallback))))

;;;; Command construction and quoting

(ert-deftest rdev-docker-local-transport-argv ()
  (let ((argv (rdev-docker--transport-argv '(:transport docker) "fakec" "echo hi")))
    (should (equal argv '("docker" "exec" "-i" "fakec" "sh" "-c" "echo hi"))))
  (let ((argv (rdev-docker--transport-argv
               '(:transport docker :docker-user "dev") "fakec" "echo hi")))
    (should (equal argv '("docker" "exec" "-i" "--user" "dev" "fakec" "sh" "-c" "echo hi")))))

(ert-deftest rdev-docker-remote-command-quoting ()
  ;; The whole command is one remote-shell string.  Assert semantics, not a
  ;; particular quoting style: the remote shell must parse it back to the
  ;; exact argv, so spaces/quotes in the payload can never split or inject.
  (let ((cmd (rdev-docker--remote-command
              '(:transport docker)
              (rdev-docker--exec-args '(:transport docker) "fakec" "echo hi there"))))
    (should (equal (split-string-shell-command cmd)
                   '("docker" "exec" "-i" "fakec" "sh" "-c" "echo hi there"))))
  (let* ((payload "printf '%s' \"a b'c\"")
         (cmd (rdev-docker--remote-command
               '(:transport docker :docker-program "/opt/bin/docker")
               (rdev-docker--exec-args '(:transport docker :docker-user "dev")
                                       "fakec" payload))))
    (should (equal (split-string-shell-command cmd)
                   (list "/opt/bin/docker" "exec" "-i" "--user" "dev"
                         "fakec" "sh" "-c" payload))))
  (let ((argv (rdev-docker--transport-argv
               '(:transport docker :docker-host "devbox") "fakec" "echo hi")))
    (should (equal (seq-subseq argv 0 3) '("ssh" "-T" "-o")))
    (should (member "--" argv))
    (should (member "devbox" argv))
    (let ((remote (car (last argv))))
      (should (equal (split-string-shell-command remote)
                     '("docker" "exec" "-i" "fakec" "sh" "-c" "echo hi"))))))

(ert-deftest rdev-docker-invalid-names-rejected-in-commands ()
  (should-error (rdev-docker--exec-args '(:transport docker) "bad name" "x"))
  (should-error (rdev-docker--transport-argv '(:transport docker) "-c" "x"))
  (should-error (rdev-docker--transport-argv
                 '(:transport docker :docker-user "-bad") "c" "x")))

;;;; Inspect, ps and error mapping

(ert-deftest rdev-docker-inspect-parses-json ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (let ((info (rdev-docker--inspect (rdev--host-spec "dk") "fakec")))
      (should (equal (plist-get info :id) "fakeid0123456789abcdef"))
      (should (equal (plist-get info :name) "fakec"))
      (should (eq (plist-get info :running) t))
      (should-not (plist-get info :paused))
      (should (equal (plist-get info :status) "up 1 min")))))

(ert-deftest rdev-docker-inspect-not-running ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (rdev-docker-test--with-env '(("FAKE_DOCKER_RUNNING" . "false"))
      (let ((info (rdev-docker--inspect (rdev--host-spec "dk") "dk")))
        (should-not (plist-get info :running))))))

(ert-deftest rdev-docker-error-mapping ()
  ;; The three inspect failure modes map to distinct reasons.
  (dolist (pair '(("notfound" . not-found)
                  ("permission" . permission)
                  ("daemon" . engine-unreachable)))
    (rdev-docker-test--fresh)
    (rdev-docker-test--with-spec '(:transport docker)
      (rdev-docker-test--with-env
          (list (cons "FAKE_DOCKER_INSPECT_FAIL" (car pair)))
        (let ((err (should-error (rdev-docker--cached-info "dk" (rdev--host-spec "dk")))))
          (should (eq (car err) 'rdev-docker-error))
          (should (eq (rdev-docker-test--reason err) (cdr pair))))))))

(ert-deftest rdev-docker-exec-failures-classified ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (rdev-docker-test--with-env '(("FAKE_DOCKER_EXEC_FAIL" . "nosh"))
      (let ((err (should-error (rdev-docker--probe-uid (rdev--host-spec "dk") "dk"))))
        (should (eq (rdev-docker-test--reason err) 'unsupported)))))
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (rdev-docker-test--with-env '(("FAKE_DOCKER_EXEC_FAIL" . "daemon"))
      (let ((err (should-error (rdev-docker--probe-uid (rdev--host-spec "dk") "dk"))))
        (should (eq (rdev-docker-test--reason err) 'engine-unreachable))))))

(ert-deftest rdev-docker-cli-missing-is-engine-unreachable ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts '(("dk" . (:transport docker))))
        (rdev-docker-program "rdev-docker-certainly-not-on-path"))
    (let ((err (should-error (rdev-docker--cached-info "dk" (rdev--host-spec "dk")))))
      (should (eq (rdev-docker-test--reason err) 'engine-unreachable)))))

;;;; Discovery cache and bounds

(ert-deftest rdev-docker-discovery-parses-and-bounds ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (let* ((snap (rdev-docker--discovery-for-host "dk"))
           (entries (car snap)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :name) "fakec"))
      (should (equal (plist-get (nth 0 entries) :id) "fakeid0123456789abcdef"))
      (should (equal (plist-get (nth 1 entries) :name) "other"))
      (should-not (cdr snap))))
  ;; Bounded parsing: more lines than the cap truncates and reports.
  (let* ((rdev-docker-discovery-max 1)
         (snap (rdev-docker--parse-ps "a\ta\ti\ts\nb\tb\ti\ts\n")))
    (should (= (length (car snap)) 1))
    (should (equal (plist-get (caar snap) :name) "a"))
    (should (cdr snap))))

(ert-deftest rdev-docker-discovery-cached-with-ttl ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (let* ((count (make-temp-file "rdev-docker-ps-count"))
           (size (lambda ()
                   (with-temp-buffer (insert-file-contents count) (buffer-size)))))
      (unwind-protect
          (rdev-docker-test--with-env
              (list (cons "FAKE_DOCKER_PS_COUNT_FILE" count))
            (rdev-docker--discovery-for-host "dk")
            (rdev-docker--discovery-for-host "dk")
            ;; Two calls with a fresh cache: exactly one `docker ps' (2 bytes).
            (should (= (funcall size) 2))
            (let ((rdev-docker-discovery-ttl 0))
              (rdev-docker--discovery-for-host "dk")
              ;; ttl 0 forces a refresh (4 bytes = two queries).
              (should (= (funcall size) 4))))
        (ignore-errors (delete-file count))))))

(ert-deftest rdev-docker-discovery-keeps-snapshot-on-error ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    (should (= (length (car (rdev-docker--discovery-for-host "dk"))) 2))
    (let ((rdev-docker-discovery-ttl 0))
      (rdev-docker-test--with-env '(("FAKE_DOCKER_PS_FAIL" . "daemon"))
        ;; The previous snapshot survives; no error escapes.
        (should (= (length (car (rdev-docker--discovery-for-host "dk"))) 2))))
    ;; With no snapshot at all the error is surfaced.
    (rdev-docker-test--fresh)
    (rdev-docker-test--with-env '(("FAKE_DOCKER_PS_FAIL" . "daemon"))
      (let ((err (should-error (rdev-docker--discovery-for-host "dk"))))
        (should (eq (rdev-docker-test--reason err) 'engine-unreachable))))))

;;;; Session identity

(ert-deftest rdev-docker-session-key-format ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (let ((key (rdev-state-session-key "dk")))
      (should (equal key "docker:local:fakeid0123456789abcdef"))))
  ;; The container key is used when none is configured.
  (rdev-docker-test--fresh)
  (let ((rdev-hosts '(("mycontainer" . (:transport docker))))
        (rdev-docker-program rdev-docker-test--fake))
    (rdev-docker-test--with-env '(("FAKE_DOCKER_ID" . "aaaaaaaaaaaaaaaa"))
      (should (equal (rdev-state-session-key "mycontainer")
                     "docker:local:aaaaaaaaaaaaaaaa"))))
  ;; SSH keys are untouched by the Docker hook.
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-state-ssh-g-function (lambda (_) "user u\nhostname h\nport 22\n")))
    (should (equal (rdev-state-session-key "x") "u@h:22"))))

;;;; Root policy

(ert-deftest rdev-docker-root-policy-unit ()
  (rdev-docker-test--fresh)
  ;; Refusal: root without the opt-in signals root-refused with remedies.
  (let ((err (should-error (rdev-docker--apply-root-policy
                            "dk" '(:transport docker) "c" 0 "k"))))
    (should (eq (car err) 'rdev-docker-error))
    (should (eq (rdev-docker-test--reason err) 'root-refused))
    (should (string-match-p "use an unprivileged account" (cadr err))))
  ;; Opt-in: proceeds, warns and records the elevated privilege.
  (let ((rdev-hosts nil))
    (should-not (rdev-docker--apply-root-policy
                 "dk" '(:transport docker :allow-root t) "c" 0 "k"))
    (should (rdev-docker-test--log-contains
             "k" "helper runs with container-root privileges")))
  ;; Unprivileged UID: no warning, no log line (a fresh key: the opt-in
  ;; case above already logged its warning under "k").
  (let ((rdev-hosts nil))
    (should-not (rdev-docker--apply-root-policy
                 "dk" '(:transport docker) "c" 1000 "k-unprivileged"))
    (should-not (rdev-docker-test--log-contains
                 "k-unprivileged" "container-root privileges"))))

(ert-deftest rdev-docker-unknown-uid-is-unsupported ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker)
    ;; A non-positive uid is unusable, never guessed.
    (rdev-docker-test--with-env '(("FAKE_DOCKER_UID" . "-1"))
      (let ((err (should-error (rdev-docker--probe-uid (rdev--host-spec "dk") "dk"))))
        (should (eq (rdev-docker-test--reason err) 'unsupported))))))

;;;; Full stack through the fake transport (real agent, real bootstrap)

(ert-deftest rdev-docker-full-stack-connect-and-edit ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((conn (rdev-docker-test--connect-dk)))
        (should (rdev-conn-p conn))
        (should (eq (rdev-conn-transport conn) 'docker))
        (should (equal (rdev-conn-container conn) "fakeid0123456789abcdef"))
        (should (equal (rdev-conn-container-name conn) "fakec"))
        (should (equal (rdev-conn-engine conn) "local"))
        (should-not (rdev-conn-root-mode conn))
        (let ((key (rdev-state-session-key "dk")))
          (should (string-prefix-p "docker:local:" key))
          (should (eq (rdev-state key) 'connected)))
        ;; The helper was installed and verified in the (temp) home.
        (should (file-directory-p (expand-file-name ".cache/rdev" rdev-docker-test--home)))
        ;; Ordinary file operations work end to end.
        (should (file-exists-p "/rdev:dk:/etc/hostname"))
        (let ((f (format "/rdev:dk:%s/hello.txt" (directory-file-name rdev-docker-test--home))))
          (write-region "docker edit\n" nil f nil 'silent)
          (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                         "docker edit\n"))
          ;; Attributes come from the container, not the client.
          (let ((attrs (file-attributes f)))
            (should (= (file-attribute-size attrs) (length "docker edit\n")))
            (should (stringp (file-attribute-modes attrs))))
          (rename-file f (concat f ".moved"))
          (should (file-exists-p (concat f ".moved")))
          (delete-file (concat f ".moved"))
          (should-not (file-exists-p (concat f ".moved"))))))))

(ert-deftest rdev-docker-one-inspect-per-connect ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home)
              (cons "FAKE_DOCKER_INSPECT_COUNT_FILE" "/tmp/opencode/rdev-docker-insp-count"))
      (rdev-docker-test--cleanup
        (let ((count "/tmp/opencode/rdev-docker-insp-count"))
          (ignore-errors (delete-file count))
          (rdev-docker-test--fresh)
          (rdev--connect "dk")
          ;; Session key + process use ONE `docker inspect' (2 bytes logged).
          (should (= (with-temp-buffer (insert-file-contents count) (buffer-size)) 2))
          (ignore-errors (delete-file count)))))))

(ert-deftest rdev-docker-root-refusal-installs-nothing ()
  ;; A private HOME: the shared test home already has a verified helper from
  ;; earlier tests, so "installs nothing" must be observed on a clean one.
  (let ((home (make-temp-file "rdev-docker-refuse-" t)))
    (unwind-protect
        (rdev-docker-test--with-spec '(:transport docker :container "fakec")
          (rdev-docker-test--with-env
              (list (cons "HOME" home)
                    (cons "FAKE_DOCKER_UID" "0"))
            (rdev-docker-test--cleanup
              (let ((err (should-error (rdev--connect "dk"))))
                (should (eq (car err) 'rdev-docker-error))
                (should (eq (rdev-docker-test--reason err) 'root-refused))
                (should (string-match-p ":allow-root" (cadr err))))
              (should (eq 'failed (rdev-state (rdev-state-session-key "dk"))))
              ;; No helper, no transport process, no partial install.
              (should-not (file-directory-p (expand-file-name ".cache/rdev" home)))
              (should-not (rdev-docker-test--transport "dk")))))
      (delete-directory home t))))

(ert-deftest rdev-docker-root-opt-in-warns-and-logs ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec" :allow-root t)
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home)
              (cons "FAKE_DOCKER_UID" "0")
              (cons "FAKE_DOCKER_PS_COUNT_FILE" ""))
      (rdev-docker-test--cleanup
        (let ((conn (rdev-docker-test--connect-dk)))
          (should conn)
          (should (rdev-conn-root-mode conn))
          (should (rdev-docker-test--log-contains
                   (rdev-state-session-key "dk")
                   "helper runs with container-root privileges")))))))

(ert-deftest rdev-docker-root-policy-global-option ()
  (rdev-docker-test--fresh)
  ;; The global opt-in allows root and records it.
  (let ((rdev-docker-allow-root t)
        (rdev-hosts nil))
    (should-not (rdev-docker--apply-root-policy
                 "dk" '(:transport docker) "c" 0 "k-global"))
    (should (rdev-docker-test--log-contains
             "k-global" "container-root privileges")))
  ;; Global off, per-target on still works.
  (let ((rdev-docker-allow-root nil)
        (rdev-hosts nil))
    (should-not (rdev-docker--apply-root-policy
                 "dk" '(:transport docker :allow-root t) "c" 0 "k-target"))
    (should (rdev-docker-test--log-contains
             "k-target" "container-root privileges")))
  ;; Both off refuses.
  (let ((rdev-docker-allow-root nil)
        (rdev-hosts nil))
    (let ((err (should-error
                (rdev-docker--apply-root-policy
                 "dk" '(:transport docker) "c" 0 "k-refuse"))))
      (should (eq (rdev-docker-test--reason err) 'root-refused))))
  ;; An explicit per-target nil opts out even when the global default is on.
  (let ((rdev-docker-allow-root t)
        (rdev-hosts nil))
    (let ((err (should-error
                (rdev-docker--apply-root-policy
                 "dk" '(:transport docker :allow-root nil) "c" 0 "k-optout"))))
      (should (eq (rdev-docker-test--reason err) 'root-refused)))))

(ert-deftest rdev-docker-global-allow-root-connects ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home)
              (cons "FAKE_DOCKER_UID" "0")
              (cons "FAKE_DOCKER_PS_COUNT_FILE" ""))
      (let ((rdev-docker-allow-root t))
        (rdev-docker-test--cleanup
          (let ((conn (rdev-docker-test--connect-dk)))
            (should conn)
            (should (rdev-conn-root-mode conn))
            (should (rdev-docker-test--log-contains
                     (rdev-state-session-key "dk")
                     "container-root privileges"))))))))

(ert-deftest rdev-docker-home-fallback-uses-tmp ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env
        (list (cons "HOME" "/nonexistent-rdev-test-home")
              (cons "FAKE_DOCKER_PS_COUNT_FILE" ""))
      (rdev-docker-test--cleanup
        (let ((c (rdev--connect "dk")))
          (should (rdev-conn-p c))
          ;; The bootstrap fell back to /tmp/rdev-<uid>.
          (should (file-exists-p (format "/tmp/rdev-%d/rdev" (user-uid))))
          (should (cl-find-if (lambda (f) (string-prefix-p "rdev-server-" f))
                              (directory-files (format "/tmp/rdev-%d/rdev" (user-uid))))))))))

(ert-deftest rdev-docker-container-loss-reconnects-without-replay ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((conn (rdev-docker-test--connect-dk))
            (key (rdev-state-session-key "dk")))
        (should conn)
        (let ((rdev-reconnect-base 0.05) (rdev-reconnect-cap 0.1)
              (rdev-reconnect-max-attempts 60))
          ;; Kill the transport: the "container" stopped.
          (delete-process (rdev-docker-test--transport "dk"))
          (should (rdev-docker-test--wait
                   (lambda () (eq (rdev-state key) 'connected))))
          (should (= (rdev-conn-gen (gethash "dk" rdev--conns)) 2))
          ;; Same container identity: same session key, fresh generation.
          (should (equal (rdev-state-session-key "dk") key)))))))

(ert-deftest rdev-docker-container-replacement-gets-new-session ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home)
              (cons "FAKE_DOCKER_PS_COUNT_FILE" "")
              (cons "FAKE_DOCKER_ID" "aaaaaaaaaaaaaaaa"))
      (rdev-docker-test--cleanup
        (let ((rdev-reconnect-base 0.05) (rdev-reconnect-cap 0.1)
              (rdev-reconnect-max-attempts 60)
              (old-key (progn (rdev-docker-test--fresh) (rdev--connect "dk")
                              (rdev-state-session-key "dk"))))
          (should (equal old-key "docker:local:aaaaaaaaaaaaaaaa"))
          ;; Recreate the container under the same name with a new ID: the
          ;; replacement is resolved during reconnect, not before.
          (rdev-docker-test--env-apply (list (cons "FAKE_DOCKER_ID" "bbbbbbbbbbbbbbbb")))
          (delete-process (rdev-docker-test--transport "dk"))
          (should (rdev-docker-test--wait
                   (lambda ()
                     (and (eq (rdev-state (rdev-state-session-key "dk")) 'connected)
                          (not (equal (rdev-state-session-key "dk") old-key))))))
          (let ((new-key (rdev-state-session-key "dk")))
            (should (equal new-key "docker:local:bbbbbbbbbbbbbbbb"))
            (should (eq (rdev-state new-key) 'connected))
            (should (eq (rdev-state old-key) 'disconnected))
            (should-not (gethash old-key rdev--key-hosts))
            (should (rdev-docker-test--log-contains
                     old-key
                     "container replaced: docker:local:aaaaaaaaaaaaaaaa -> docker:local:bbbbbbbbbbbbbbbb"))
            ;; The new session has an empty cache and works.
            (should (file-exists-p "/rdev:dk:/etc/hostname"))))))))

(ert-deftest rdev-docker-reconnect-to-missing-container-fails ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((rdev-reconnect-base 0.05) (rdev-reconnect-cap 0.1)
            (rdev-reconnect-max-attempts 3)
            (conn (rdev-docker-test--connect-dk))
            (key (rdev-state-session-key "dk")))
        (should conn)
        ;; The container goes away for good: attempts exhaust to FAILED.
        (rdev-docker-test--env-apply (list (cons "FAKE_DOCKER_INSPECT_FAIL" "notfound")))
        (delete-process (rdev-docker-test--transport "dk"))
        (should (rdev-docker-test--wait
                 (lambda () (eq (rdev-state key) 'failed)) 15))
        (should (rdev-docker-test--log-contains key "attempt failed"))))))

;;;; Streaming processes through the relay

(ert-deftest rdev-docker-process-streams-and-exit-codes ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (rdev-docker-test--connect-dk)
      (let* ((default-directory "/rdev:dk:/tmp/")
             (buf (generate-new-buffer " *rdev-docker-proc*"))
             (proc (make-process :name "dp" :buffer buf
                                 :command '("sh" "-c" "echo out; echo err 1>&2; exit 3")
                                 :file-handler t)))
        (should (rdev-docker-test--chan-of proc))
        ;; Output streams incrementally and the exit code is exact.
        (should (rdev-docker-test--wait
                 (lambda () (string-match-p "out" (with-current-buffer buf (buffer-string))))))
        (should (rdev-docker-test--wait
                 (lambda () (string-match-p "err" (with-current-buffer buf (buffer-string))))))
        (should (rdev-docker-test--wait
                 (lambda () (not (process-live-p proc)))))
        (should (= (process-exit-status proc) 3))
        (kill-buffer buf)))))

(ert-deftest rdev-docker-container-loss-marks-processes-interrupted ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (rdev-docker-test--connect-dk)
      (let* ((default-directory "/rdev:dk:/tmp/")
             (buf (generate-new-buffer " *rdev-docker-proc*"))
             (proc (make-process :name "dp" :buffer buf
                                 :command '("sh" "-c" "sleep 30")
                                 :file-handler t)))
        ;; Wait for the relay handshake, not just the channel: only then is
        ;; the local relay connected and able to report the 255 exit code.
        (should (rdev-docker-test--wait
                 (lambda ()
                   (when-let* ((chan (rdev-docker-test--chan-of proc)))
                     (rdev-chan-sock chan)))))
        (let ((rdev-reconnect-base 0.05) (rdev-reconnect-cap 0.1)
              (rdev-reconnect-max-attempts 60))
          ;; The container is lost under a running process: the process is
          ;; reported as exited 255 and never replayed.
          (delete-process (rdev-docker-test--transport "dk"))
          (should (rdev-docker-test--wait
                   (lambda () (not (process-live-p proc)))))
          (should (= (process-exit-status proc) 255))
          (should (rdev-docker-test--wait
                   (lambda () (eq (rdev-state (rdev-state-session-key "dk")) 'connected)))))
        (kill-buffer buf)))))

(ert-deftest rdev-docker-pty-resize-and-signal ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (rdev-docker-test--connect-dk)
      (let* ((default-directory "/rdev:dk:/tmp/")
             (buf (generate-new-buffer " *rdev-docker-pty*"))
             (p (make-process :name "dp" :buffer buf :command '("sh")
                              :connection-type 'pty :file-handler t :noquery t)))
        (unwind-protect
            (progn
              (should (rdev-docker-test--wait (lambda () (process-live-p p))))
              (accept-process-output nil 0.2)
              (set-process-window-size p 33 101)
              (process-send-string p "stty size\n")
              (should (rdev-docker-test--wait
                       (lambda ()
                         (with-current-buffer buf
                           (string-match-p "33 101" (buffer-string))))))
              (process-send-string p "sleep 30\n")
              (accept-process-output nil 0.2)
              (interrupt-process p)
              (process-send-string p "echo after-int\n")
              (should (rdev-docker-test--wait
                       (lambda ()
                         (with-current-buffer buf
                           (string-match-p "after-int" (buffer-string))))))
              (process-send-string p "exit 4\n")
              (should (rdev-docker-test--wait (lambda () (not (process-live-p p)))))
              (should (= 4 (process-exit-status p))))
          (when (process-live-p p) (delete-process p))
          (kill-buffer buf))))))

;;;; Security negatives: no listener, no credential leakage

(ert-deftest rdev-docker-opens-no-listener-and-leaks-no-token ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((token (rdev--relay-token))
            (before (process-list)))
        (rdev-docker-test--connect-dk)
        ;; No listening socket was opened for the Docker target: the relay
        ;; server only exists once a remote process is started.
        (should-not (cl-some (lambda (p)
                               (and (eq (process-type p) 'network)
                                    (not (memq p before))))
                             (process-list)))
        ;; The per-session relay token never reaches the connection log.
        (should (rdev-docker-test--wait
                 (lambda () (eq (rdev-state (rdev-state-session-key "dk")) 'connected))))
        (should-not (rdev-docker-test--log-contains
                     (rdev-state-session-key "dk") (regexp-quote token)))))))

;;;; Remote engine identity and error mapping

(ert-deftest rdev-docker-remote-engine-identity ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts '(("remote" . (:transport docker :container "fakec"
                                   :docker-host "devbox"))
                      ("local" . (:transport docker :container "fakec"))))
        (rdev-state-ssh-g-function
         (lambda (h) (format "user u\nhostname %s.example\nport 22\n" h))))
    ;; The engine is namespaced by the canonical SSH key, not the alias.
    (should (equal (rdev-docker--engine-key (rdev--host-spec "remote"))
                   "u@devbox.example:22"))
    (should (equal (rdev-docker--engine-key (rdev--host-spec "local")) "local"))))

(ert-deftest rdev-docker-ssh-failure-is-ssh-error ()
  (rdev-docker-test--fresh)
  (let ((remote '(:transport docker :container "fakec" :docker-host "devbox"))
        (local '(:transport docker :container "fakec")))
    ;; An ssh signature on a remote engine is an SSH error.
    (let ((err (should-error
                (rdev-docker--exit remote 255 ""
                                   "ssh: Could not resolve hostname devbox"))))
      (should (eq (car err) 'rdev-ssh-error)))
    ;; A Docker/daemon signature keeps the Docker error class and reason.
    (let ((err (should-error
                (rdev-docker--exit local 1 ""
                                   "Cannot connect to the Docker daemon"))))
      (should (eq (car err) 'rdev-docker-error))
      (should (eq (rdev-docker-test--reason err) 'engine-unreachable)))
    ;; Exit 255 on a local engine is not an SSH failure.
    (let ((err (should-error (rdev-docker--exit local 255 "" "docker failed"))))
      (should (eq (car err) 'rdev-docker-error)))))

;;;; Addressing: configured keys and explicit `docker+NAME' addresses only

(defun rdev-docker-test--count (file)
  "Number of lines the fake CLI appended to FILE."
  (/ (or (file-attribute-size (file-attributes file)) 0) 2))

(defmacro rdev-docker-test--with-counter (var &rest body)
  "Run BODY with VAR bound to a fresh `docker ps' count file, then delete it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "rdev-docker-ps-count")))
     (unwind-protect
         (rdev-docker-test--with-env (list (cons "FAKE_DOCKER_PS_COUNT_FILE" ,var))
           ,@body)
       (ignore-errors (delete-file ,var)))))

(ert-deftest rdev-docker-bare-name-is-never-a-container ()
  ;; A running container named like an unconfigured host must not capture
  ;; it: the name stays SSH and Docker is not even asked.
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-docker-program rdev-docker-test--fake))
    (rdev-docker-test--with-counter count
      (should-not (rdev--host-spec "fakec"))
      (should-not (rdev--docker-p "fakec"))
      (should-not rdev-hosts)
      (should (zerop (rdev-docker-test--count count))))))

(ert-deftest rdev-docker-explicit-address-spec ()
  (let ((rdev-hosts nil))
    (should (equal (rdev--host-spec "docker+fakec")
                   '(:transport docker :container "fakec")))
    (should (equal (rdev--host-spec "docker+web.1@build")
                   '(:transport docker :container "web.1" :docker-host "build")))
    (should (equal (rdev--host-spec "docker+web@me@build:2222")
                   '(:transport docker :container "web" :docker-host "me@build:2222")))
    (should (rdev--docker-p "docker+fakec"))
    ;; Not addresses: bad container names, no name, other prefixes.
    (should-not (rdev--host-spec "docker+-rm"))
    (should-not (rdev--host-spec "docker+"))
    (should-not (rdev--host-spec "xdocker+fakec"))
    (should-not rdev-hosts))
  ;; A configured entry with the same key wins, even an SSH one.
  (let ((rdev-hosts '(("docker+fakec" . nil))))
    (should-not (rdev--docker-p "docker+fakec"))))

(ert-deftest rdev-docker-explicit-address-connects-without-config ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-docker-program rdev-docker-test--fake))
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home))
      (unwind-protect
          (let ((conn (rdev--conn "docker+fakec")))
            (should (eq (rdev-conn-transport conn) 'docker))
            (should (equal (rdev-state-session-key "docker+fakec")
                           "docker:local:fakeid0123456789abcdef"))
            (should (file-directory-p "/rdev:docker+fakec:/"))
            (should-not rdev-hosts))
        (ignore-errors (rdev-disconnect "docker+fakec"))
        (rdev-docker-test--fresh)))))

(ert-deftest rdev-docker-ssh-hosts-follow-includes ()
  (let* ((home (make-temp-file "rdev-auto-home-" t))
         (cfg (expand-file-name "config" home))
         (inc (expand-file-name "included" home)))
    (unwind-protect
        (progn
          (with-temp-file inc (insert "Host included-host\n"))
          (with-temp-file cfg
            (insert "Include included\n"
                    "Host *.example.com !skip.example.com\n"
                    "Host literal\n"))
          (let ((rdev-ssh-args (list "-F" cfg))
                (rdev-hosts nil))
            (rdev-docker-test--with-env (list (cons "HOME" home))
              (let ((hosts (rdev--ssh-hosts)))
                (should (member "literal" hosts))
                (should (member "included-host" hosts))
                (should-not (cl-some (lambda (h) (string-match-p "[*?!]" h))
                                     hosts))))))
      (delete-directory home t))))

;;;; Completion: background discovery, explicit keys

(ert-deftest rdev-docker-completion-offers-local-containers-as-addresses ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-docker-program rdev-docker-test--fake)
        (home (make-temp-file "rdev-auto-home-" t)))
    (unwind-protect
        (rdev-docker-test--with-env (list (cons "HOME" home))
          ;; Cold cache: the first call waits briefly for the lookup it starts.
          (let ((hosts (rdev--target-completion)))
            (should (member "docker+fakec" hosts))
            (should (member "docker+other" hosts))
            (should-not (member "fakec" hosts)))
          ;; The same keys complete after `/rdev:'.
          (should (member "docker+fakec:" (file-name-all-completions "docker+f" "/rdev:"))))
      (rdev-docker-test--fresh)
      (delete-directory home t))))

(ert-deftest rdev-docker-completion-local-discovery-can-be-disabled ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-docker-program rdev-docker-test--fake)
        (rdev-docker-auto-detect nil)
        (home (make-temp-file "rdev-auto-home-" t)))
    (unwind-protect
        (rdev-docker-test--with-env (list (cons "HOME" home))
          (rdev-docker-test--with-counter count
            (should-not (cl-some (lambda (h) (string-prefix-p "docker+" h))
                                 (rdev--target-completion)))
            (should (zerop (rdev-docker-test--count count)))))
      (delete-directory home t))))

(ert-deftest rdev-docker-completion-never-waits-on-a-hung-engine ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts nil)
        (rdev-docker-program rdev-docker-test--fake)
        (rdev-docker-discovery-wait 0.2)
        (rdev-docker-auto-detect-timeout 0.6)
        (rdev-docker-discovery-backoff 60)
        (home (make-temp-file "rdev-auto-home-" t)))
    (unwind-protect
        (rdev-docker-test--with-env (list (cons "HOME" home)
                                          (cons "FAKE_DOCKER_PS_SLEEP" "5"))
          (rdev-docker-test--with-counter count
            (let ((t0 (float-time)) hosts)
              (setq hosts (rdev--target-completion))
              ;; Bounded by the short cold-cache wait, not the engine.
              (should (< (- (float-time) t0) 1.0))
              (should-not (cl-some (lambda (h) (string-prefix-p "docker+" h)) hosts))
              ;; A second prompt while the lookup is running starts no other
              ;; one and does not wait at all.
              (setq t0 (float-time))
              (rdev--target-completion)
              (should (< (- (float-time) t0) 0.15))
              (should (rdev-docker-test--wait
                       (lambda () (= 1 (rdev-docker-test--count count))) 2))
              ;; The hung lookup is killed at the timeout and remembered...
              (should (rdev-docker-test--wait
                       (lambda () (gethash "local" rdev-docker--failed)) 3))
              (should-not (gethash "local" rdev-docker--inflight))
              ;; ...so completion does not retry it within the backoff.
              (rdev--target-completion)
              (sleep-for 0.2)
              (should (= 1 (rdev-docker-test--count count))))))
      (rdev-docker-test--fresh)
      (delete-directory home t))))

(ert-deftest rdev-docker-completion-serves-stale-snapshot-and-refreshes ()
  (rdev-docker-test--fresh)
  (let* ((rdev-hosts nil)
         (rdev-docker-program rdev-docker-test--fake)
         (home (make-temp-file "rdev-auto-home-" t))
         (ps (expand-file-name "ps" home)))
    (unwind-protect
        (rdev-docker-test--with-env (list (cons "HOME" home)
                                          (cons "FAKE_DOCKER_PS_FILE" ps))
          (should (member "docker+fakec" (rdev--target-completion)))
          (with-temp-file ps (insert "newc\tabc123\timg\tUp\n"))
          (let ((rdev-docker-discovery-ttl 0))
            ;; Stale: answered from the old snapshot at once...
            (let ((hosts (rdev--target-completion)))
              (should (member "docker+fakec" hosts))
              (should-not (member "docker+newc" hosts)))
            ;; ...while the refresh runs; the next prompt sees its result.
            (should (rdev-docker-test--wait
                     (lambda () (zerop (hash-table-count rdev-docker--inflight))) 3))
            (let ((rdev-docker-discovery-ttl 60))
              (let ((hosts (rdev--target-completion)))
                (should (member "docker+newc" hosts))
                (should-not (member "docker+fakec" hosts))))))
      (rdev-docker-test--fresh)
      (delete-directory home t))))

(ert-deftest rdev-docker-completion-queries-each-engine-once ()
  ;; Two configured targets on the local engine plus local discovery: one
  ;; `docker ps'.  Containers that already have a configured key are not
  ;; offered again under an address.
  (rdev-docker-test--fresh)
  (let ((rdev-hosts '(("a" :transport docker :container "fakec")
                      ("b" :transport docker :container "fakec")))
        (rdev-docker-program rdev-docker-test--fake)
        (home (make-temp-file "rdev-auto-home-" t)))
    (unwind-protect
        (rdev-docker-test--with-env (list (cons "HOME" home))
          (rdev-docker-test--with-counter count
            (let ((hosts (rdev--target-completion)))
              (should (member "a" hosts))
              (should (member "b" hosts))
              (should (member "docker+other" hosts))
              (should-not (member "docker+fakec" hosts)))
            (should (= 1 (rdev-docker-test--count count)))))
      (rdev-docker-test--fresh)
      (delete-directory home t))))

(ert-deftest rdev-docker-completion-offers-configured-and-running ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (let ((hosts (rdev--target-completion)))
      (should (member "dk" hosts))             ; the configured target key
      (should (member "docker+other" hosts))   ; a running container
      (should-not (member "docker+fakec" hosts))) ; already configured as dk
    (rdev-docker-test--fresh))
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env '(("FAKE_DOCKER_PS_FAIL" . "daemon"))
      (rdev-docker-test--fresh)
      ;; A failed discovery is silent and configured keys still complete.
      (let ((hosts (rdev--target-completion)))
        (should (member "dk" hosts)))
      (rdev-docker-test--fresh))))

;;;; Precedence, commands and UI

(ert-deftest rdev-docker-configured-key-wins-over-alias ()
  ;; The configured `rdev-hosts' entry decides the transport (precedence, C5).
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (should (rdev--docker-p "dk"))
    (should (eq (plist-get (rdev--host-spec "dk") :transport) 'docker))))

(ert-deftest rdev-docker-connect-command-uses-explicit-address ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env
        (list (cons "HOME" rdev-docker-test--home)
              (cons "FAKE_DOCKER_PS_COUNT_FILE" ""))
      (rdev-docker-test--cleanup
        (rdev-docker-test--fresh)
        (unwind-protect
            (let ((before (copy-sequence rdev-hosts)))
              ;; A bare container name connects as its explicit address and
              ;; adds nothing to the configuration.
              (should (equal (rdev-docker-connect "other") "docker+other"))
              (should (equal rdev-hosts before))
              (should (eq (rdev-conn-transport (gethash "docker+other" rdev--conns))
                          'docker))
              ;; An address or a configured key is used as given.
              (should (equal (rdev-docker-connect "docker+other") "docker+other"))
              (should (equal (rdev-docker-connect "dk") "dk")))
          (ignore-errors (rdev-disconnect "docker+other")))))))

(ert-deftest rdev-docker-connect-rejects-ssh-configured-name ()
  (rdev-docker-test--fresh)
  (let ((rdev-hosts '(("web" . nil))))
    (should-error (rdev-docker-connect "web"))))

(ert-deftest rdev-docker-ui-shows-container-target ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((conn (rdev-docker-test--connect-dk)))
        (should conn)
        ;; The readable name, not the truncated ID.
        (should (equal (rdev-ui--target "dk") "docker:local/fakec"))
        (let ((row (rdev-ui--row "dk")))
          (should (equal (aref (cadr row) 1) "docker:local/fakec")))
        ;; `rdev-status' shows the name and a short ID.
        (rdev-status)
        (with-current-buffer "*rdev*"
          (should (string-match-p "container fakec (fakeid012345) on engine local"
                                  (buffer-string))))))))

(ert-deftest rdev-docker-restart-server-keeps-container ()
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((gen (rdev-conn-gen (rdev-docker-test--connect-dk))))
        (rdev-restart-server "dk")        ; non-interactive: no prompt
        (should (rdev-docker-test--wait
                 (lambda () (and (eq (rdev-state (rdev-state-session-key "dk")) 'connected)
                                 (> (rdev-conn-gen (gethash "dk" rdev--conns)) gen)))))
        ;; The fake "container" (the test machine) is unaffected by a restart.
        (should (file-exists-p "/rdev:dk:/etc/hostname"))))))

(provide 'rdev-docker-test)
;;; rdev-docker-test.el ends here

;;;; Review fixes: failure records, identity by ID, bounds, messages

(ert-deftest rdev-docker-failed-first-connect-records-reason ()
  ;; A container that cannot be inspected still gets a session: the failure
  ;; and its reason show in the state, the log and the connection list.
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (rdev-docker-test--fresh)
      (rdev-docker-test--with-env '(("FAKE_DOCKER_INSPECT_FAIL" . "notfound"))
        (let* ((err (should-error (rdev--connect "dk")))
               (key (rdev-state-session-key "dk")))
          (should (eq (rdev-docker-test--reason err) 'not-found))
          (should (equal key "docker:local:unresolved/fakec"))
          (should (eq (rdev-state key) 'failed))
          (should (rdev-docker-test--log-contains key "connect failed: .*no container fakec"))
          (should (equal (aref (cadr (rdev-ui--row "dk")) 2) "failed"))))
      ;; Once the container exists, the real key replaces the placeholder
      ;; without a misleading "container replaced" record.
      (let ((conn (rdev--connect "dk"))
            (key (rdev-state-session-key "dk")))
        (should conn)
        (should (equal key "docker:local:fakeid0123456789abcdef"))
        (should (eq (rdev-state key) 'connected))
        (should-not (rdev-docker-test--log-contains
                     "docker:local:unresolved/fakec" "container replaced"))))))

(ert-deftest rdev-docker-vanished-container-keeps-session-key ()
  ;; The cached key survives a failed re-inspect, so the connection list
  ;; neither signals nor runs Docker again.
  (rdev-docker-test--with-target
    (rdev-docker-test--cleanup
      (let ((conn (rdev-docker-test--connect-dk))
            (key (rdev-state-session-key "dk")))
        (should conn)
        (rdev-disconnect "dk")
        (let ((count (make-temp-file "rdev-docker-inspect-count")))
          (unwind-protect
              (rdev-docker-test--with-env
                  (list (cons "FAKE_DOCKER_INSPECT_FAIL" "notfound")
                        (cons "FAKE_DOCKER_INSPECT_COUNT_FILE" count))
                (should-error (rdev--connect "dk") :type 'rdev-docker-error)
                (should (equal (rdev-state-session-key "dk") key))
                (should (eq (rdev-state key) 'failed))
                (should (rdev-ui--entries))
                (should (equal (aref (cadr (rdev-ui--row "dk")) 2) "failed"))
                ;; Exactly the one inspect of the connect attempt.
                (should (= 1 (rdev-docker-test--count count))))
            (ignore-errors (delete-file count))))))))

(ert-deftest rdev-docker-session-key-never-signals ()
  (rdev-docker-test--fresh)
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env '(("FAKE_DOCKER_INSPECT_FAIL" . "daemon"))
      (should (equal (rdev-state-session-key "dk") "docker:local:unresolved/fakec"))))
  (rdev-docker-test--fresh))

(ert-deftest rdev-docker-exec-uses-container-id ()
  ;; Probe and transport address the inspected ID, so a container recreated
  ;; under the same name in between cannot receive the session.
  (rdev-docker-test--with-target
    (let ((log (make-temp-file "rdev-docker-exec-log")))
      (unwind-protect
          (rdev-docker-test--with-env (list (cons "FAKE_DOCKER_EXEC_LOG" log))
            (rdev-docker-test--cleanup
              (should (rdev-docker-test--connect-dk))
              (let ((targets (split-string
                              (with-temp-buffer (insert-file-contents log) (buffer-string))
                              "\n" t)))
                (should (>= (length targets) 2))
                (should (cl-every (lambda (c) (equal c "fakeid0123456789abcdef"))
                                  targets)))))
        (ignore-errors (delete-file log))))))

(ert-deftest rdev-docker-tmp-fallback-requires-ownership ()
  ;; The /tmp fallback is refused when its directory is a symlink (a
  ;; pre-planted path); a fresh one is created mode 0700.
  (let* ((root (make-temp-file "rdev-fallback-" t))
         (script (rdev--bootstrap-script t))
         (prefix (substring script 0 (string-search "; F=" script)))
         (prefix (string-replace "/tmp/rdev-" (concat root "/rdev-") prefix))
         (run (lambda ()
                (with-temp-buffer
                  (let ((default-directory temporary-file-directory)
                        (process-environment
                         (cons "HOME=/nonexistent-rdev-test-home" process-environment)))
                    (call-process "sh" nil t nil "-c"
                                  (concat prefix "; echo \"OK $D\""))
                    (buffer-string)))))
         (base (format "%s/rdev-%d" root (user-uid))))
    (unwind-protect
        (progn
          (should (string-match-p "\\`OK .*/rdev\n" (funcall run)))
          (should (= (file-modes base) #o700))
          (delete-directory base t)
          (make-directory (concat root "/elsewhere/rdev") t)
          (make-symbolic-link (concat root "/elsewhere") base)
          (should (string-match-p "RDEV-ERR no writable directory" (funcall run))))
      (delete-directory root t))))

(ert-deftest rdev-docker-discovery-output-is-byte-capped ()
  (let ((rdev-docker--discovery-max-bytes 30))
    ;; The cut drops the partial last line and reports truncation.
    (let ((snap (rdev-docker--parse-ps "a\tid1\ti\ts\nbbbbbbbbbb\tid2\timg\tUp 1 min\n")))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) (car snap)) '("a")))
      (should (cdr snap))))
  ;; A flooding engine is cut off, in the blocking and background paths.
  (let* ((home (make-temp-file "rdev-auto-home-" t))
         (ps (expand-file-name "ps" home)))
    (unwind-protect
        (progn
          (with-temp-file ps
            (dotimes (i 2000) (insert (format "c%d\tid%d\timg\tUp\n" i i))))
          (rdev-docker-test--with-spec '(:transport docker)
            (rdev-docker-test--with-env (list (cons "FAKE_DOCKER_PS_FILE" ps))
              (let ((rdev-docker--discovery-max-bytes 200)
                    (rdev-docker-discovery-max 10000))
                (rdev-docker-test--fresh)
                (let ((snap (rdev-docker--discovery-for-host "dk")))
                  (should (< 0 (length (car snap)) 20))
                  (should (cdr snap)))
                (rdev-docker-test--fresh)
                (let ((rdev-docker-discovery-wait 2))
                  (let ((snap (rdev-docker--snapshot (rdev--host-spec "dk"))))
                    (should (< 0 (length (car snap)) 20))
                    (should (cdr snap))))))))
      (rdev-docker-test--fresh)
      (delete-directory home t))))

(ert-deftest rdev-docker-error-messages-name-engine-and-account ()
  (rdev-docker-test--with-spec '(:transport docker :container "fakec")
    (rdev-docker-test--with-env '(("FAKE_DOCKER_INSPECT_FAIL" . "notfound"))
      (rdev-docker-test--fresh)
      (let ((msg (cadr (should-error (rdev-docker--cached-info "dk" (rdev--host-spec "dk"))))))
        (should (string-match-p "no container fakec on the local engine" msg))))
    (rdev-docker-test--with-env '(("FAKE_DOCKER_INSPECT_FAIL" . "permission"))
      (rdev-docker-test--fresh)
      (let ((msg (cadr (should-error (rdev-docker--cached-info "dk" (rdev--host-spec "dk"))))))
        (should (string-match-p "container fakec on the local engine" msg))
        (should (string-match-p (regexp-quote (user-login-name)) msg))
        (should (string-match-p "docker' group" msg))))
    (rdev-docker-test--with-env '(("FAKE_DOCKER_INSPECT_FAIL" . "daemon"))
      (rdev-docker-test--fresh)
      (let ((msg (cadr (should-error (rdev-docker--cached-info "dk" (rdev--host-spec "dk"))))))
        (should (string-match-p "cannot reach the local engine" msg)))))
  (rdev-docker-test--fresh))
