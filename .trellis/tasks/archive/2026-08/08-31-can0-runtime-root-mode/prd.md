# Accept Writable Root-Owned `/run` for the can0 Lock

## Goal

Allow the fixed Linux can0 setup helper to run on target systems whose real
`/run` directory is owned by root but is group- or other-writable, while
preserving the strict root-only security boundary at
`/run/excavatorsim/can0.lock` and the existing stable failure contract.

## Background

- The target reports `/run` as `root:root 0777`. The current
  `_validate_runtime_root()` rejects any group/other write bit, producing
  `CAN0_SETUP_FAILED: unsafe can0 lock runtime`
  (`tools/can_gateway/can0_setup.py:218-224`).
- The parent-mode restriction came from the archived secure-lock task, whose
  design assumed `/run` had no group/other write
  (`.trellis/tasks/archive/2026-08/08-28-can0-helper-secure-lock/design.md:5-8,19-29`).
- The child directory and lock are independently authorized after fd-relative,
  no-follow opens: the directory must be root-owned mode `0700`, and the lock
  must be a root-owned regular mode `0600` inode with one hard link
  (`tools/can_gateway/can0_setup.py:227-243,292-327`).

## Requirements

- `_validate_runtime_root()` must accept any real directory owned by UID 0,
  including mode `0777`; it must still reject non-directories and non-root
  owners.
- Continue opening `/run` with `O_DIRECTORY`, `O_NOFOLLOW`, and `O_CLOEXEC`,
  and continue authorizing its opened inode with `fstat`.
- Continue requiring `/run/excavatorsim` to be a root-owned directory with
  exact mode `0700`. Do not delete, chmod, chown, replace, or otherwise take
  over an unsafe pre-existing child.
- Continue requiring `can0.lock` to be a root-owned, regular, exact-mode
  `0600`, single-link inode. Do not follow symlinks or repair unsafe objects.
- Preserve fd-relative `mkdir/open`, after-open `fstat`, exclusive `flock`,
  complete-transaction serialization, descriptor cleanup, and bounded stable
  `CAN0_SETUP_FAILED` diagnostics.
- Unsafe child-directory or lock-object states must fail before any `ip link`
  inspection or mutation command is invoked.
- Update the CAN Gateway security contract and operator documentation to state
  the relaxed parent requirement, the unchanged strict child/lock requirement,
  and the residual local denial-of-service risk on writable `/run` parents.
- Rebuild the Linux Gateway/helper distribution and the Linux Godot release
  package so the deployed `can0-setup-helper` contains the fix; regenerate and
  verify build manifests.

## Acceptance Criteria

- [x] Root-owned directory metadata for `/run` is accepted at modes `0755` and
  `0777`; a non-directory or UID other than 0 still returns
  `CAN0_SETUP_FAILED`.
- [x] An injected complete setup using writable root-owned `/run`, strict child
  `0700`, and strict lock `0600` reaches the normal configuration transaction.
- [x] With writable root-owned `/run`, a preoccupied child directory, symlink
  open failure, wrong child owner/mode/type, or unsafe lock
  owner/mode/type/link count returns a sanitized `CAN0_SETUP_FAILED` and invokes
  no runner command.
- [x] Regression tests assert the runtime/child opens retain `O_DIRECTORY` and
  `O_NOFOLLOW`, and the lock open retains `O_NOFOLLOW`; open/stat/mkdir/flock
  failures do not leak raw exception content or a traceback.
- [x] Existing deterministic transaction-level concurrency proves the second
  setup cannot enter while the first holds the lock; the root-Linux real-flock
  check remains valid.
- [x] Focused Python lint/tests pass without changing CAN readiness,
  configuration order, SocketCAN sending, frame encoding, Windows PC001, or
  receive behavior.
- [x] The rebuilt Linux standalone and Godot-bundled helpers match, are
  executable ELF artifacts, contain current manifests, and the packaged helper
  accepts the target `/run` security model.

## Out of Scope

- Changing bitrate, `restart-ms`, `txqueuelen`, interface readiness, CAN frame
  construction, payloads, scheduling, SocketCAN send/receive, Windows transport,
  or any other ICT behavior.
- Automatically repairing, deleting, renaming, or taking ownership of unsafe
  objects under `/run`.
- Preventing an unprivileged local user from causing availability failures by
  repeatedly preoccupying or replacing entries under a non-sticky writable
  `/run`. The helper must fail closed and remain non-exploitable in that case.
- Changing the target system's `/run` mount or permissions.
