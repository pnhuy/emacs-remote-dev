<!--
SYNC IMPACT REPORT
Version change: (unratified template) → 1.0.0
Bump rationale: initial ratification; the file was an unfilled template, so there is no prior version.
Modified principles: none (all new)
Added sections:
  - Core Principles, Articles I–X
  - Development Workflow and Change Governance (Article XI)
  - Definition of Done (Article XII)
  - Governance
Removed sections: none (all template placeholders replaced)
Templates:
  - ✅ .specify/templates/plan-template.md — "Constitution Check" now lists the Article gates
  - ✅ .specify/templates/spec-template.md — no constitution references; no change needed
  - ✅ .specify/templates/tasks-template.md — no constitution references; no change needed
  - ✅ .specify/templates/checklist-template.md — no constitution references; no change needed
  - ⚠ specs/001-rdev-modernization/{spec,plan,tasks}.md — pending reconciliation of the items below
Reconciliation items for the existing 001-rdev-modernization feature (not edited by this command):
  - Art. IV says the agent MUST run without root privileges; spec FR-035 / task T120 allow an explicit
    `--allow-root` override. Per Article XI this needs either a documented exception or removal of
    the override.
  - Art. VI makes Linux primary and macOS "SHOULD"; spec FR-004a makes macOS a MUST with "not run"
    recording. The spec is stricter than the constitution, which is permitted; no conflict.
  - Plan "Constitution Check" previously gated on user constraints because the constitution was
    unfilled; it should be re-run against Articles I–XII (e.g. /speckit-analyze).
Deferred placeholders: none
-->
# RDEV Constitution

RDEV — Emacs Remote Development — is an Emacs package that provides a VS Code Remote SSH-like
development experience using JSON-RPC over SSH. It is an existing project, not a greenfield one.
Its components are:

- `rdev.el`: Emacs Lisp client, file-name handlers, connection management, remote process
  integration.
- `rdev-server.py`: Python remote agent implementing JSON-RPC, filesystem operations and remote
  process execution.
- `rdev-relay.py`: local Python relay connecting Emacs subprocess interfaces with remote processes.

## Core Principles

### Article I — Architecture Preservation and Incremental Evolution

The existing implementation is the foundation of the project.

- Existing working functionality MUST be preserved unless an explicitly approved change requires
  otherwise.
- Large-scale rewrites MUST be avoided when incremental refactoring can achieve the same outcome.
- The `/rdev:HOST:/path` remote filename convention MUST remain compatible.
- The persistent JSON-RPC connection over SSH MUST remain a primary transport.
- The local process relay architecture MUST be preserved unless evidence demonstrates a superior
  alternative.
- Public Emacs commands, functions, variables and existing RPC methods MUST remain
  backward-compatible whenever reasonably possible.
- Breaking changes MUST include a documented justification, a migration path and regression tests.
- New abstractions MUST solve demonstrated problems rather than introduce unnecessary complexity.
- Architecture changes MUST be documented before implementation.

### Article II — Native Emacs Integration First

RDEV MUST behave as a natural extension of Emacs rather than a separate remote IDE framework. The
guiding principle is that a remote project should feel like an ordinary Emacs project.

- Standard Emacs buffers MUST remain the primary editing interface.
- File operations MUST integrate through Emacs file-name handlers and documented Emacs APIs.
- Remote processes MUST integrate with standard Emacs process interfaces wherever technically
  feasible.
- Existing Emacs packages SHOULD work without RDEV-specific modifications.
- Built-in Emacs facilities MUST be preferred over custom replacements.
- The implementation MUST prioritize compatibility with: `find-file` and `save-buffer`; Dired;
  `project.el`; `compile` and `recompile`; `shell` and `comint`; Eglot; Git and Magit; Dape.
- Integration compatibility MUST be demonstrated through executable tests, not inferred from the
  existence of low-level APIs.
- The package MUST NOT globally override or disrupt unrelated local or TRAMP workflows.
- Existing Emacs customizations and major modes MUST continue functioning on RDEV buffers wherever
  supported.

### Article III — Data Integrity and Correctness Above All

Data integrity is the highest technical priority.

- RDEV MUST NOT silently discard unsaved buffer changes.
- Ordinary remote file saves MUST avoid partial-file corruption.
- Atomic replacement MUST be used when supported and appropriate.
- Concurrent external file changes MUST be detected before overwriting newer content wherever
  reliable version checking is supported.
- File permissions, symbolic links and metadata MUST be handled according to documented semantics.
- Binary files and character encodings MUST be transferred without unintended modification.
- Failed operations MUST return meaningful errors.
- Connection failures MUST preserve local editing state.
- Automatic retries MUST distinguish idempotent and non-idempotent operations.
- Non-idempotent operations MUST NOT be blindly replayed following uncertain execution.
- Caches MUST NOT compromise filesystem correctness.
- Operations involving deletion, overwrite or process termination MUST follow explicit and
  predictable semantics.
- Correctness and data safety MUST take precedence over performance optimization or feature
  delivery.

### Article IV — Security by Design

- RDEV MUST follow the principle of least privilege.
- SSH MUST remain the preferred mechanism for authentication and encrypted communication.
- Existing SSH configuration, keys, agents and host key verification MUST be respected.
- RDEV MUST NOT implement custom password storage or SSH key management.
- The remote agent MUST run without root privileges.
- Remote filesystem operations MUST respect the permissions of the authenticated user.
- Commands MUST use argument-based execution rather than unsafe shell interpolation by default.
- JSON-RPC requests MUST be validated.
- Protocol message sizes and resource usage MUST be bounded.
- Local Unix sockets MUST use restrictive permissions.
- Publicly exposed, unencrypted TCP connections MUST NOT be enabled by default.
- Credentials, authentication tokens and sensitive environment variables MUST NOT appear in
  ordinary logs.
- Remote agent installation and updates MUST be verified and performed safely.
- Security-relevant behavior MUST have automated tests.
- Security-sensitive configuration changes MUST require explicit user intent.
- Convenience MUST NOT override transport security or data protection.

### Article V — Performance, Responsiveness, and Resource Efficiency

The goal is measurable performance improvement, not optimization based on assumptions.

- RDEV MUST provide a responsive editing experience over remote connections.
- Network operations SHOULD be asynchronous whenever the Emacs API permits.
- Long-running operations MUST NOT unnecessarily block the Emacs UI.
- Synchronous Emacs API constraints MUST be acknowledged rather than hidden.
- A persistent connection SHOULD be reused instead of repeatedly establishing SSH sessions.
- Remote operations SHOULD minimize unnecessary network round trips.
- Large transfers MUST use bounded memory and appropriate streaming or chunking.
- Concurrency MUST be bounded to prevent resource exhaustion.
- Process output MUST implement appropriate buffering or backpressure.
- Caching MUST have explicit invalidation rules.
- Performance improvements MUST be supported by benchmarks.
- Benchmarks SHOULD include comparison with equivalent TRAMP operations.
- Performance MUST be evaluated under realistic network latency.
- Optimizations MUST NOT violate correctness, security or maintainability.

### Article VI — Minimal Dependencies and Portability

- The Emacs client MUST primarily use built-in Emacs libraries.
- `jsonrpc.el` MUST remain the preferred JSON-RPC implementation.
- The remote Python agent MUST prefer standard-library dependencies.
- Additional dependencies MUST have a documented justification.
- RDEV MUST support Emacs 30.1 and later.
- Supported Python runtime versions MUST be explicitly defined and tested.
- Linux MUST be the primary remote target.
- macOS compatibility SHOULD be preserved where practical.
- The agent MUST NOT require administrative privileges or system-wide installation.
- Platform-specific functionality MUST be isolated behind clear interfaces.
- Optional tools such as ripgrep, Git, Eglot, Magit and Dape MUST NOT become mandatory dependencies
  for basic remote editing.
- Missing optional capabilities MUST fail gracefully with actionable diagnostics.

### Article VII — Testing and Regression Prevention

Tests protect both the current implementation and future development.

- Every significant implementation change MUST be testable.
- Emacs Lisp functionality MUST be tested using ERT.
- Python components MUST have automated unit tests.
- JSON-RPC protocol behavior MUST have dedicated tests.
- Filesystem tests MUST include failure and edge cases.
- Remote process tests MUST cover lifecycle, signals, output and abnormal termination.
- Security-sensitive operations MUST have negative tests.
- Integration tests MUST exercise actual Emacs-to-agent communication.
- Existing functionality MUST be covered by regression tests before substantial refactoring.
- Critical defects MUST receive regression tests that fail before the fix and pass afterward.
- Tests MUST be deterministic and isolated wherever practical.
- External SSH environments SHOULD be reproducible through containers or disposable test hosts.
- Known failing tests MUST be documented and MUST NOT be silently ignored.
- Static inspection alone MUST NOT be presented as proof of runtime compatibility.
- Every milestone MUST define objective acceptance criteria.

### Article VIII — Protocol Stability and Compatibility

- JSON-RPC 2.0 MUST remain the application protocol.
- LSP-style `Content-Length` framing MUST remain supported.
- Existing RPC method names and parameter contracts MUST be preserved unless a versioned change is
  justified.
- Protocol capabilities MUST be explicitly negotiated when necessary.
- The client and agent MUST detect incompatible versions.
- Protocol errors MUST be structured and actionable.
- Responses MUST be correlated correctly with requests.
- Notifications MUST have documented semantics.
- Resource-intensive protocol operations MUST enforce appropriate limits.
- New protocol capabilities MUST include documentation and automated tests.
- The protocol MUST remain independent of the Emacs user interface.
- Protocol changes MUST be evaluated for their effect on existing deployed agents.

### Article IX — Maintainability and Code Quality

- Code MUST favor clarity over cleverness.
- Functions SHOULD have narrow, coherent responsibilities.
- Transport, filesystem, process, project and UI concerns SHOULD be separated when doing so
  improves maintainability.
- Refactoring MUST be incremental and supported by tests.
- Public functions and configuration variables MUST be documented.
- Complex concurrency or lifecycle behavior MUST include explanatory comments.
- Error messages MUST help users diagnose and recover from failures.
- Duplicated functionality SHOULD be consolidated where appropriate.
- External libraries or frameworks MUST NOT be introduced without clear benefit.
- Proposed changes MUST account for existing Emacs conventions.
- Dead code and obsolete functionality SHOULD be removed only after compatibility assessment.
- The codebase MUST remain approachable for independent Emacs Lisp and Python contributors.

### Article X — User Experience and Operational Transparency

The desired experience is simple: connect to a host, open a project, and use Emacs normally.

- Remote development MUST work through familiar Emacs commands.
- Users SHOULD NOT need to manage remote agent processes manually.
- Agent installation and updates SHOULD be automatic when safely configured.
- Connection status MUST be visible and understandable.
- Errors MUST distinguish SSH, transport, agent, filesystem and remote process failures.
- Connection loss MUST be reported without disrupting unsaved editing buffers.
- The package SHOULD support standard Emacs completion interfaces.
- Configuration MUST use `defcustom` where appropriate.
- Debug logging MUST be available without exposing sensitive information.
- Optional advanced features MUST NOT complicate the basic connection and editing workflow.

## Development Workflow and Change Governance

### Article XI — Development Workflow and Change Governance

All Spec Kit implementation work MUST follow these rules:

- Inspect the relevant existing code before planning modifications.
- Identify current behavior and public compatibility requirements.
- Distinguish confirmed defects from suspected defects.
- Prioritize security, data integrity and critical reliability issues.
- Implement changes in small, independently testable increments.
- Add regression coverage for bug fixes.
- Document architectural decisions and protocol changes.
- Avoid unrelated refactoring during focused feature implementation.
- Run relevant tests before marking tasks complete.
- Explicitly report any unimplemented requirements or unsupported cases.
- Do not claim successful testing unless tests were actually executed.
- Do not replace working subsystems without evidence and documented justification.
- Constitution violations MUST be identified during planning and review.
- Exceptions to mandatory principles MUST be documented with rationale, risks and an approved
  migration or remediation plan.
- Amendments to this constitution MUST be intentional, documented and versioned.

## Definition of Done

### Article XII — Definition of Done

A feature is complete only when all of the following hold:

- The implementation meets its documented functional requirements.
- Existing supported functionality continues working.
- Relevant unit tests pass.
- Relevant integration tests pass where the required environment is available.
- Error and failure paths have been considered.
- Security implications have been reviewed.
- Public interfaces and configuration are documented.
- Protocol changes are documented and tested.
- Performance regressions have been evaluated when relevant.
- The feature can be used through normal Emacs workflows where applicable.
- Incomplete verification or environmental limitations MUST be reported explicitly.

## Governance

This constitution is the authoritative engineering policy for RDEV. It takes precedence over
ordinary implementation preferences and feature-specific convenience decisions.

- Specifications, technical plans, task lists and code reviews MUST remain consistent with it.
- When a requirement conflicts with the constitution, the conflict MUST be documented and resolved
  before implementation.
- Amendments follow semantic versioning: MAJOR for removing or redefining a principle in a
  backward-incompatible way, MINOR for adding a principle or materially expanding guidance, PATCH
  for clarifications and wording.
- Compliance is reviewed at planning (plan "Constitution Check"), at `/speckit-analyze`, and in
  code review.

The overarching objective is to transform the existing RDEV package into a reliable, secure,
efficient and natively integrated Emacs remote development environment without sacrificing its
current architecture or compatibility.

**Version**: 1.0.0 | **Ratified**: 2026-11-22 | **Last Amended**: 2026-11-22
