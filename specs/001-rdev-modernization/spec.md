# Feature Specification: RDEV 2.0 — Remote Development Modernization

**Feature Branch**: `001-rdev-modernization`

**Created**: 2026-11-22

**Status**: Draft

**Input**: User description: "RDEV 2.0 — Incremental modernization and expansion of the existing Emacs remote development package (``: client, remote agent, local process relay) into a reliable, performant, extensible environment comparable to VS Code Remote SSH, preserving existing architecture, paths, commands, and configuration."

## Scope & Delivery Model

This is a modernization of an existing, working package, not a new build. The current client, remote agent, and local process relay are the authoritative baseline. Work is delivered in five ordered milestones (see Milestones); each milestone's stories are independently testable and shippable. Existing behavior, public commands, customization variables, the `/rdev:HOST:/path` path syntax, and the remote agent's standard-library-only footprint are preserved throughout.

## Clarifications

### Session 2026-11-22

- Q: Which remote host operating systems must be fully supported and tested beyond Linux? → A: Linux and macOS hosts are both fully supported and tested from Milestone 1.
- Q: What happens by default to remote processes when Emacs disconnects, SSH fails, or the relay crashes? → A: Owned processes are terminated; keeping them alive is an opt-in setting available only if implemented and tested.
- Q: On a save when the remote file changed since it was opened, what should happen? → A: Refuse the save with a conflict error, then offer refresh, compare, or an explicit overwrite confirmation.
- Q: How is direct TCP mode treated when enabled for a non-loopback address without encryption? → A: Refused by default; allowed only via an explicit per-connection opt-in, with a warning shown on each connect.
- Q: What is the oldest Python version the remote agent must run on? → A: Python 3.8.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trust the baseline: audit and regression safety net (Priority: P1)

A maintainer needs to know what is broken or risky today and be able to change the package without silently breaking what works. They get a prioritized audit report and an automated regression suite capturing current behavior before any refactoring starts.

**Why this priority**: Every later change depends on knowing current behavior and detecting regressions. Without it, "preserve existing behavior" cannot be verified.

**Independent Test**: Run the regression suite against the unmodified package; it passes for working behavior and lists known failures separately. Review the audit report for coverage of every area in the audit scope.

**Acceptance Scenarios**:

1. **Given** the current package, **When** the audit is complete, **Then** a report exists classifying every finding as P0–P3 and as confirmed defect, defect needing runtime verification, missing feature, architecture limitation, security concern, performance bottleneck, or compatibility risk.
2. **Given** the regression suite, **When** run before any change, **Then** every currently working public feature is covered and known failures are recorded separately rather than hidden.
3. **Given** any later change, **When** the suite is run, **Then** a regression in previously working behavior is detected and reported.

---

### User Story 2 - Edit remote files without losing or corrupting data (Priority: P1)

A developer opens a remote file via `/rdev:HOST:/path`, edits, and saves. An interrupted save never leaves a truncated or half-written file, and if someone else changed the file in the meantime the developer is told instead of silently overwriting.

**Why this priority**: Data loss/corruption is the most severe failure for an editing tool.

**Independent Test**: Save while killing the connection mid-write and verify the original or complete new content exists, never partial content. Modify the file externally between open and save and verify a conflict is reported.

**Acceptance Scenarios**:

1. **Given** an open remote file, **When** the connection drops during save, **Then** the remote file contains either the complete old or complete new content and the local buffer retains the unsaved edits.
2. **Given** a file changed remotely after it was opened, **When** the developer saves, **Then** the save is refused with a distinct conflict error and the developer can refresh, compare, or explicitly overwrite.
3. **Given** a symlinked file, **When** saved, **Then** the link is preserved and the target updated, and file permissions are retained.
4. **Given** a very large file, **When** opened or saved, **Then** transfer proceeds in bounded-memory pieces, is integrity-verified, and interrupted transfers leave no stray remote data.
5. **Given** an append operation, **When** requested, **Then** it follows explicit append semantics distinct from an ordinary save.

---

### User Story 3 - Reliable connections that survive network failures (Priority: P1)

A developer connects to a host over SSH (using their existing SSH configuration) and keeps working through flaky networks. Connection setup is dependable, status is visible, and failures recover automatically without losing work.

**Why this priority**: Connection reliability underlies every remote workflow.

**Independent Test**: Connect, kill the network/SSH process, observe state transitions and automatic reconnection with bounded backoff; verify buffers and unsaved edits persist and no command is re-executed with unknown status.

**Acceptance Scenarios**:

1. **Given** a host reachable via SSH alias, port, key, agent, or ProxyJump, **When** the developer connects for the first time, **Then** the remote agent is installed safely and atomically and the connection reaches a connected state; partial/interrupted installs are cleaned up.
2. **Given** an incompatible or outdated agent, **When** connecting, **Then** it is upgraded or rejected with an actionable error.
3. **Given** repeated connect requests for the same host, **When** issued concurrently, **Then** only one active connection exists.
4. **Given** a connected session, **When** the connection fails, **Then** the state becomes degraded/reconnecting, open buffers and unsaved edits are preserved, pending requests fail clearly, active remote processes are marked interrupted/uncertain, and reconnection retries with bounded exponential backoff.
5. **Given** a reconnected session, **When** the developer saves a previously open file, **Then** a conflict check occurs first and watchers and project context are re-established.
6. **Given** a command whose completion status is unknown after a failure, **When** reconnection succeeds, **Then** it is never automatically re-run.
7. **Given** multiple hosts, **When** used simultaneously, **Then** each connection operates independently.

---

### User Story 4 - Manage connections from a single view (Priority: P2)

A developer lists, connects, reconnects, disconnects, restarts the remote agent, and views logs for all remote connections from a table interface (`tabulated-list-mode`), in addition to existing commands such as `rdev-status`.

**Why this priority**: Visibility and control make failures diagnosable without restarting Emacs.

**Independent Test**: Open the connection list with two hosts; perform each action and verify state and log output update.

**Acceptance Scenarios**:

1. **Given** several connections, **When** the list is opened, **Then** each shows host and current state.
2. **Given** a selected connection, **When** reconnect, disconnect, restart-agent, or show-logs is invoked, **Then** the action takes effect and the display reflects the new state.
3. **Given** existing commands, **When** used, **Then** they behave as before.

---

### User Story 5 - Run commands, shells, and builds on the remote host (Priority: P2)

A developer runs one-off commands, asynchronous processes, interactive shells, and `compile`/`recompile` on the remote host through standard Emacs mechanisms, with correct output, exit codes, signals, and cancellation, and with error navigation back to remote source files.

**Why this priority**: Running builds/tests/shells remotely is the core daily workflow after editing.

**Independent Test**: Run each Emacs process mechanism against a remote project and compare output, exit status, filters, sentinels, and environment against local behavior; cancel a running build.

**Acceptance Scenarios**:

1. **Given** a remote working directory, **When** a process is started by any standard Emacs mechanism (process creation, file-process, synchronous file-process, shell commands, async shell commands, compilation, shell/comint), **Then** output streams incrementally, exit codes are exact, and no buffered output is lost at exit.
2. **Given** a running remote process, **When** the developer interrupts, signals, or kills it, **Then** the whole process group terminates and resources are released.
3. **Given** an interactive terminal, **When** the window is resized, **Then** the remote terminal size follows.
4. **Given** a compile with errors, **When** the developer follows an error, **Then** the corresponding remote source file opens at the right location.
5. **Given** a process producing output faster than Emacs consumes, **When** running, **Then** memory use stays bounded and behavior on client stall/disconnect is defined.
6. **Given** a connection loss, relay crash, or agent exit, **When** it occurs, **Then** the documented process ownership/termination policy applies, and no persistence is promised beyond what is implemented and tested.

---

### User Story 6 - Work with remote projects natively (Priority: P2)

A developer discovers and switches between remote projects, finds files, and searches code with standard Emacs project and directory tools, without downloading the whole tree.

**Why this priority**: Navigating a codebase is a prerequisite to the IDE-level features.

**Independent Test**: Open a remote Git repository; use project file finding, project switching, Dired, path completion, and cancellable search; verify results match the remote tree.

**Acceptance Scenarios**:

1. **Given** a remote Git repo or directory with configured markers, **When** a file in it is visited, **Then** it is recognized as a project and project commands run in the correct remote environment.
2. **Given** a project, **When** the developer finds a file, switches projects, or opens Dired, **Then** results come from remote data and previously opened remote projects are offered.
3. **Given** a search with literal or regex pattern, glob filters, ignore rules, and a max result count, **When** run, **Then** structured matches stream in incrementally, are cancellable, and work with a documented fallback or clear actionable error if the preferred fast search tool is absent.
4. **Given** a high-latency link, **When** completing remote paths, **Then** a 1000-entry directory completes in at most 2 round trips and 500 ms.
5. **Given** remote file changes, **When** the platform supports notifications, **Then** standard watch interfaces report them and caches are invalidated; otherwise a defined fallback applies. Watches are removed on disconnect.

---

### User Story 7 - Code intelligence, Git, and debugging on the remote host (Priority: P3)

A developer opens a remote Python or C++ file and gets diagnostics, completion, go-to-definition, references, rename, and code actions from a language server running remotely; uses Git and Magit workflows in remote repositories; and, in a later milestone, debugs with a remote debug adapter.

**Why this priority**: IDE-level parity with VS Code Remote; depends on stable files, processes, and projects.

**Independent Test**: Run dedicated integration scenarios for the language server, Git/Magit, and debugger against a disposable remote host.

**Acceptance Scenarios**:

1. **Given** a remote project, **When** the language client starts, **Then** the server runs remotely with the correct project root, path/URI mapping, and survives or cleanly handles restart and disconnection.
2. **Given** a remote repository, **When** status, diff, log, branch, stage, and commit are performed, **Then** each completes correctly.
3. **Given** a remote debug adapter, **When** a debug session is launched, **Then** source paths map between local and remote, working directory and process I/O are correct, termination is clean, and reconnection behavior is defined.

---

### User Story 8 - Secure by default (Priority: P2)

A developer can use the package on shared machines and networks without exposing the host or their files.

**Why this priority**: Security-critical behavior must not be deferred.

**Independent Test**: Automated tests for token handling, local socket permissions, malformed input, and path handling.

**Acceptance Scenarios**:

1. **Given** SSH transport, **When** connecting, **Then** native SSH authentication and host-key verification apply, no keys or passwords are stored, and bootstrap does no unsafe shell interpolation.
2. **Given** the direct network transport, **When** configured without encryption, **Then** it is refused unless explicitly opted in; defaults bind to loopback only; tokens are strong, redacted from logs, compared safely, and failed authentication is handled; SSH tunneling is documented as recommended.
3. **Given** the local process relay, **When** created, **Then** its socket is in a private location with restrictive permissions and malformed or oversized messages are rejected without crashing Emacs.
4. **Given** remote file operations, **When** parameters are invalid, point to special files or symlinks, or attempt traversal, **Then** they are validated and remote permissions honored; the agent never runs with elevated privileges.

---

### User Story 9 - Measured performance and clear documentation (Priority: P3)

A maintainer sees benchmark baselines (also under simulated latency, loss, and bandwidth limits, and compared with Emacs TRAMP) and uses install/developer documentation.

**Why this priority**: Evidence-based optimization and adoption require data and docs, but follow correctness.

**Independent Test**: Run the benchmark suite and read the docs to install and develop from scratch.

**Acceptance Scenarios**:

1. **Given** the benchmark suite, **When** run, **Then** it reports median, p95, failure rate, and memory where practical for connect/bootstrap, stat, open, save, directory listing, project enumeration, search, process start, shell responsiveness, and language-server start, under low latency, 50 ms, 150 ms RTT, packet loss, interrupted connections, and reduced bandwidth.
2. **Given** identical workloads, **When** compared with TRAMP, **Then** results are reported side by side.
3. **Given** any optimization, **When** proposed, **Then** it cites a measured bottleneck and does not reduce data integrity.
4. **Given** the docs, **When** followed, **Then** a new user can install and connect, and a contributor can build, test, and extend.

---

### Edge Cases

- Remote home-directory shorthand and existing paths continue to resolve exactly as before.
- Connection drops during bootstrap, mid-save, mid-search, or mid-process; SSH prints banners/noise before agent output.
- Remote filesystem lacks atomic replace or durability guarantees; target is a symlink, special file, or read-only.
- File deleted or replaced remotely while cached or open; cache grows large.
- Two Emacs sessions editing the same file; same host reached by different aliases.
- Output flood from a process while Emacs is busy; client stops reading.
- Malformed, oversized, or out-of-order protocol messages; mismatched agent/client versions.
- Remote host lacks the preferred search tool, language server, or notification support.
- Relay crash while remote process runs; process identifiers colliding across connections.
- Non-UTF-8 file contents and non-default coding systems.

## Requirements *(mandatory)*

### Functional Requirements

**Preservation & compatibility**

- **FR-001**: All currently working public commands, customization variables, remote methods, and the `/rdev:HOST:/path` syntax (including home-directory expansion) MUST continue to work, or a documented migration path MUST be provided.
- **FR-002**: The existing connection model, file-name handler, local process relay design, SSH stdio and explicitly supported TCP transports, and standard-library-only remote agent MUST be retained unless a verified limitation requires change, and any such change MUST be documented with compatibility implications.
- **FR-003**: Remote operations MUST behave like native Emacs file and process operations where feasible; an unsupported operation MUST fail explicitly rather than claim success.
- **FR-004**: The package MUST support Emacs 30.1 or later and keep `require 'rdev` working.
- **FR-004b**: The remote agent MUST run on Python 3.8 or newer using only the standard library, and MUST report a clear, actionable error when the host's interpreter is missing or older.
- **FR-004a**: Linux and macOS remote hosts MUST both be fully supported and covered by automated tests from Milestone 1; platform-specific behavior (file watching, terminals, atomic replace) MUST be verified on both. Where no macOS host is available in the build environment, macOS results MUST be recorded as "not run" (never claimed as passing) and re-run at each milestone close.

**Audit & regression (Milestone 1)**

- **FR-005**: An audit report covering client, remote agent, and relay MUST be produced before functional changes, classifying each finding as P0–P3 and as confirmed vs. unverified.
- **FR-006**: An executable regression suite for existing behavior MUST exist before substantial refactoring, with known failures recorded separately and the suite run after each phase.

**Connections (A)**

- **FR-007**: Bootstrap MUST detect status reliably regardless of output chunking, lose no protocol bytes, install atomically with safe paths and permissions, verify completeness, clean up interrupted installs, check version compatibility, and report structured, actionable errors.
- **FR-008**: Each connection MUST be in exactly one of: disconnected, connecting, bootstrapping, initializing, connected, degraded, reconnecting, failed, disconnecting; transitions MUST be deterministic and duplicate active connections for one logical session MUST NOT occur.
- **FR-009**: Automatic reconnection MUST be configurable with bounded exponential backoff, preserve buffers and unsaved edits, mark affected processes interrupted/uncertain, fail pending requests, re-establish project context and watchers, refresh metadata, require conflict checking before later saves, and never re-run commands of unknown status.
- **FR-010**: Commands for connect, list connections, reconnect, disconnect, restart server, and show logs MUST exist alongside existing commands, with a table-style management view.
- **FR-011**: Client and agent MUST negotiate protocol version and capabilities at startup; incompatible versions MUST be rejected with an actionable error.

**Files (B)**

- **FR-012**: File operation handlers (attributes, existence/readability/writability checks, truename, read, write, directory listing, copy, rename, delete, make-directory, directory display, local copy, process handlers) MUST be verified against native Emacs behavior.
- **FR-013**: Ordinary saves MUST be atomic in visibility (temp file in destination directory, complete write, flush, permissions applied, version validated, atomic replace, new metadata returned), with defined behavior where guarantees are unavailable; atomic visibility MUST be documented as distinct from power-loss durability; appends MUST have separate explicit semantics; symlink behavior MUST NOT change silently.
- **FR-014**: The file version recorded at open MUST be verified by the remote side at save time in a race-safe manner; on a conflict the save MUST be refused with a dedicated error and the user MUST be offered refresh, compare, or overwrite; overwrite MUST require explicit confirmation and MUST NOT occur by default or silently.
- **FR-015**: Optional chunked read/write operations (begin, write chunk, commit, abort, read chunk) MUST support configurable chunk and maximum sizes, transfer identifiers, integrity verification, cleanup of interrupted transfers, and bounded memory, while existing whole-file read/write remain available.
- **FR-016**: The metadata cache MUST be isolated per host, invalidated correctly (including parent directories) after every modifying operation, size-limited, inspectable via optional statistics, manually clearable, and watch-invalidated where available, and MUST behave correctly when cached entries disappear or change.
- **FR-017**: Standard file-notification add/remove-watch interfaces MUST work remotely, preferring native platform facilities with negotiated capabilities and a defined fallback, requiring no third-party dependencies on the remote host, and removing watchers on disconnect.

**Processes (C)**

- **FR-018**: Process handling MUST be correct for creation, stdin/EOF, stdout/stderr, PTY allocation, resizing, signals, process-group termination, exit codes, abnormal termination, connection loss, cancellation, and relay shutdown; process identifiers MUST be scoped per connection; startup/output/exit races MUST NOT lose or misorder output.
- **FR-019**: Shared mutable agent state (process registry, identifier allocation, shutdown, notifications, reaping, dispatch) MUST be protected against races and deadlocks, adding synchronization only where needed.
- **FR-020**: Compatibility with filters, sentinels, process buffers, coding systems, separate stderr, environment variables, terminal settings, and working directories MUST be tested for each standard process mechanism.
- **FR-021**: By default, remote processes owned by a session MUST be terminated (including their process groups) when the session ends or fails, whether due to Emacs disconnect, SSH failure, agent exit, or relay crash. A configurable policy MAY allow processes to keep running, but only as an explicit opt-in; persistent remote processes MUST NOT be advertised unless implemented and tested.

**Projects & search (D)**

- **FR-022**: Project discovery MUST support Git repositories, configurable markers, user-selected directories, and previously opened remote projects, and integrate with the standard Emacs project facilities (current project, find file, switch project, project-level commands) without downloading whole trees.
- **FR-023**: A documented remote search capability MUST support literal and regex patterns, glob filters, ignore rules, result limits, cancellation, structured match locations, and incremental delivery; it MUST prefer a fast external search tool when present and otherwise use a documented fallback or return an actionable error.
- **FR-024**: Minibuffer completion of remote paths MUST work and, at 150 ms RTT, complete a 1000-entry directory in at most 2 round trips and 500 ms; optional third-party completion framework integration MUST NOT be mandatory.

**Tool integration (E)**

- **FR-025**: Language-server support MUST run servers remotely with correct project roots and path/URI mapping, and support diagnostics, completion, definition, references, rename, code actions, restart, and disconnection handling, verified by dedicated integration tests.
- **FR-026**: Standard compile and recompile MUST work with remote working directories, streamed output, accurate exit status, error navigation to remote files, cancellation, and ANSI color sequences rendered correctly in the compilation buffer.
- **FR-027**: Git and Magit workflows (status, diff, log, branches, stage, commit) MUST work in remote repositories using existing process facilities; compatibility fixes MUST be added only where testing shows a need, and Git functionality MUST NOT be reimplemented in the agent.
- **FR-028**: Debugger integration MUST define remote adapter execution, source path mapping, working directories, process I/O, termination, and reconnection behavior, and is delivered after language-server and compilation support are stable.

**Protocol reliability (F)**

- **FR-029**: Incoming messages MUST be validated (headers, size limits, syntax, protocol version, identifiers, parameter types, required fields, supported methods, response structure); malformed or oversized messages MUST be rejected safely.
- **FR-030**: The agent MUST remain responsive during long operations using bounded concurrency while preserving request/response correlation.
- **FR-031**: Searches, file enumeration, long reads, and remote commands MUST be cancellable with resources released; operations that cannot be cancelled safely MUST be documented.
- **FR-032**: Output flow MUST be bounded so a fast producer cannot cause unbounded memory growth, with defined behavior when the client stalls or disconnects.

**Security (G)**

- **FR-033**: SSH use MUST rely on native SSH authentication and host-key verification, store no keys or passwords, and avoid unsafe shell interpolation in bootstrap. Remote commands and processes MUST be executed argv-based by default (no shell unless the user explicitly requests one), and user-supplied values MUST never be interpolated into shell strings.
- **FR-034**: The direct network transport MUST default to safe binding, refuse unencrypted non-loopback connections by default, allowing them only through an explicit per-connection opt-in that shows a warning on every connect, use strong stored tokens, redact tokens and other sensitive environment values (names matching token/secret/password/key patterns) from logs, compare tokens in constant time, and handle authentication failures; SSH tunneling MUST be documented as recommended.
- **FR-035**: The agent MUST refuse to run as root, with no override flag or environment variable. File operations MUST validate parameters, protect against unintended deletion/overwrite, honor remote permissions, handle symlinks, special files, and traversal correctly, and run as an unprivileged user-level service.
- **FR-036**: The local relay socket MUST reside in a private runtime location with restrictive permissions, validate frame sizes and types, and tolerate malformed input without crashing Emacs.

**Performance, quality, docs (H, I)**

- **FR-037**: A benchmark suite MUST measure the operations and network scenarios listed in User Story 9, report median, p95, failure rate, and memory where practical, and compare with TRAMP on identical workloads; optimizations MUST be justified by measurements.
- **FR-038**: Automated tests MUST cover Emacs-side behavior (path parsing, handler dispatch, expansion, buffer identity, read/write, encoding, errors, cache invalidation, connection state, relay, reconnection), agent-side behavior (framing, filesystem, atomic writes, conflicts, chunks, permissions, processes, PTY, thread safety, authentication, cleanup), and disposable-host end-to-end workflows (connect, bootstrap, open project, edit, save, run, shell, search, compile, disconnect, reconnect, recover edits), with language-server, Git, and debugger scenarios added as those milestones land.
- **FR-039**: Installation and developer documentation MUST be provided. Splitting the package into multiple files is permitted only where it demonstrably improves maintainability, without circular dependencies.
- **FR-040**: Errors MUST be classified as one of ssh, transport, agent, filesystem or process failure, exposed as distinct Emacs error symbols and shown in user-visible messages, so users can tell which layer failed.

### Key Entities

- **Connection**: A logical session to one host; has a state, transport, agent version/capabilities, pending requests, processes, watches, and logs.
- **Remote Agent**: The user-level service on the remote host; versioned, installed atomically, advertises capabilities.
- **Remote Path**: `/rdev:HOST:/path` address mapping an Emacs file name to a host and path.
- **File Version**: Metadata/hash snapshot recorded at open and verified at save.
- **Transfer**: An identified, integrity-checked, chunked read or write with lifecycle and cleanup.
- **Metadata Cache Entry**: Per-host cached attributes with expiry, size bounds, and invalidation.
- **Remote Process**: A process scoped to a connection with I/O streams, terminal, exit status, and ownership policy.
- **Watch**: A subscription to remote file changes, tied to a connection.
- **Project**: A remote directory recognized by markers or user selection.
- **Search Request/Match**: A cancellable search with structured results.
- **Audit Finding**: A classified (P0–P3) issue with evidence and category.
- **Benchmark Result**: Timing/failure/memory measurement for an operation under a network scenario.

## Milestones

1. **Baseline & critical reliability**: audit, regression suite, atomic saves, message validation, hardened bootstrap, process-lifecycle race fixes, TCP safety gate.
2. **Robust core**: conflict detection, connection states, reconnection, chunked transfer, cache invalidation, bounded resource use (output backpressure, worker pool), remote search.
3. **Emacs integration**: Dired, project integration, compilation, shell/comint, file watching.
4. **IDE capabilities**: remote language server, Git/Magit, navigation, optional completion integrations.
5. **Advanced**: debugger integration, advanced terminal compatibility, performance optimization, broader platform support beyond Linux/macOS, release preparation.

Milestones are completed in dependency order; safety-critical requirements are not deferred.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of previously working public features and existing remote paths pass the regression suite after every milestone.
- **SC-002**: In 100 fault-injected save attempts (connection killed at random points), 0 result in a truncated or corrupted remote file and 0 lose local unsaved edits.
- **SC-003**: 100% of externally-modified-file save attempts are reported as conflicts rather than silently overwritten.
- **SC-004**: First-time connection to a fresh host succeeds in at least 99% of 100 trials, including with noisy login output and interrupted installs, and completes in under 15 seconds on a low-latency link excluding agent download.
- **SC-005**: After a forced connection loss, the session is automatically restored within 30 seconds of network recovery in at least 95% of trials, with no duplicate execution of unknown-status commands.
- **SC-006**: During remote search, large-file transfer, and heavy process output, no single command-loop stall attributable to RDEV exceeds 200 ms at RTT ≤ 50 ms (asynchronous paths). Synchronous Emacs file-name-handler calls cannot avoid blocking; each blocks for at most one round trip plus the configured timeout, is interruptible with `C-g`, and the measured blocking times are published in the documentation.
- **SC-007**: Remote process output matches local execution byte-for-byte and exit codes match exactly across all supported process mechanisms in the compatibility test matrix.
- **SC-008**: A cancelled search or command stops and releases resources within 2 seconds.
- **SC-009**: A process flooding output for 60 seconds causes no unbounded memory growth (bounded within a documented limit).
- **SC-010**: A developer can open a remote project, find a file, search, edit, save, compile, and navigate to an error without leaving standard Emacs workflows, in a single end-to-end scenario that passes automatically.
- **SC-011**: Core language-server features (diagnostics, completion, definition, references, rename, code actions) pass dedicated tests for a remote Python project and a remote C++ project; Git status/diff/log/branch/stage/commit pass in a remote repository.
- **SC-012**: Every security requirement (FR-033–FR-036 behaviors) has at least one automated test, and all pass.
- **SC-013**: Benchmarks exist for every listed operation and network scenario; any measured regression greater than 20% versus the recorded baseline is investigated and documented.
- **SC-014**: A new user can install and connect following the documentation in under 15 minutes; a new contributor can run all test suites from the developer guide.

## Assumptions

- Target users are Emacs 30.1+ users on Linux/macOS clients connecting to Linux or macOS hosts that have OpenSSH and a standard Python interpreter, version 3.8 or newer (the agent uses only the standard library). Other host platforms (e.g., BSD) are best-effort and considered in Milestone 5.
- The existing sources under `` (client, agent, relay) are the baseline; the audit may reveal additional defects that are folded into the milestones by priority.
- Direct network transport remains supported but secondary; SSH is the recommended path.
- Persistent remote processes that survive disconnection are not in scope unless explicitly implemented and tested; the default policy is to terminate owned processes on session end (confirmed in clarification); keeping them alive is opt-in.
- Debugger integration is a separate, later milestone and may be partial where adapters make full support infeasible.
- Optional integrations (third-party completion framework, ripgrep) are never mandatory.
- The end-to-end suite is written to run unchanged against any SSH target (disposable local sshd or an externally supplied Linux/macOS host) and avoids GNU-only tooling; where no macOS host exists in the build environment, macOS results are recorded as "not run" rather than claimed. Network impairment tooling is available for benchmarks, with a documented user-space fallback.
- Numeric targets in Success Criteria are initial targets, refined after baselines are recorded.
