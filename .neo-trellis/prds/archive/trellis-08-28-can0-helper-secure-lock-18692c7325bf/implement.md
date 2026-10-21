# Implementation Plan — Secure Linux can0 helper locking

## 1. Preserve behavior

- [ ] Record existing can0 setup/helper tests and exact mutation order.
- [ ] Add failing regression for the reported pre-created user-owned lock and
  raw `PermissionError` traceback before changing implementation.

## 2. Implement secure lock boundary

- [ ] Replace the legacy lock constant with fixed `/run/excavatorsim` directory
  and `can0.lock` names.
- [ ] Add injectable fd-relative open/mkdir/fstat/flock operations and pure
  directory/file metadata validators.
- [ ] Require root ownership, safe modes, correct inode types, no final symlink,
  and `st_nlink == 1`; reject rather than repair unsafe existing objects.
- [ ] Hold the acquired fd around the existing complete inspect/configure/
  recovery/post-check transaction.
- [ ] Convert all lock-boundary OS/validation failures to bounded
  `CAN0_SETUP_FAILED` diagnostics.

## 3. Tests

- [ ] Cover safe create/reopen, hostile preoccupation, wrong owner, unsafe mode,
  symlink/non-regular/hardlink, and each syscall failure phase.
- [ ] Assert no mutation runner call occurs on any lock failure.
- [ ] Assert helper exit/stderr and Gateway propagation contain stable code,
  bounded detail, and no traceback/raw attacker content.
- [ ] Add deterministic transaction-level concurrent exclusion plus a
  Linux-only real-flock integration test.
- [ ] Re-run ready/no-op, mismatch, restoration, post-check, helper CLI,
  installer/sudoers, and package-layout tests.

## 4. Documentation and check

- [ ] Document the root-only runtime lock contract and remediation for an
  unsafe pre-existing object.
- [ ] Run focused Gateway tests, compile/lint/type checks, shell syntax, and
  Linux package inspection before handing off to the TX child.

## Rollback

- Restore only the lock implementation/constants; do not alter can0 state or
  delete an unknown runtime object during rollback.
