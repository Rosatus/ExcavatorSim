# Secure Linux can0 helper locking

## Goal

Prevent unprivileged pre-creation of the can0 helper lock from breaking or
redirecting the root helper, and make every lock failure a stable actionable
setup diagnostic rather than a traceback.

## Background

- `_exclusive_setup_lock()` currently performs
  `lock_path.open("a+")` on `/run/lock/excavatorsim-can0.lock`, follows a final
  symlink, and does no owner/mode/type/link validation
  (`tools/can_gateway/can0_setup.py:16-17,189-203`).
- `can0_setup_helper.main()` catches only `Can0SetupError`; a raw
  `PermissionError`/`OSError` escapes (`tools/can_gateway/can0_setup_helper.py:15-22`).
- The entire inspect/mutate/post-verify transaction is already inside the lock;
  command order and the fixed no-argument sudo boundary must remain unchanged.

## Requirements

- Replace the shared top-level lock with a fixed root-only runtime directory,
  `/run/excavatorsim` mode `0700`, containing a persistent
  `can0.lock` mode `0600`.
- Create/open via no-follow, fd-relative Linux syscalls; validate by `fstat`
  after open. The directory must be a root-owned directory with no group/other
  write. The lock must be root-owned, regular, non-symlink, non-hard-linked
  (`st_nlink == 1`), and inaccessible to group/other.
- Refuse unsafe existing objects without deleting or repairing an
  attacker-controlled inode and without invoking any `ip link set` mutation.
- Hold one exclusive `flock` across inspect, optional configuration, recovery,
  and post-verification; release it only when the transaction exits.
- Convert mkdir/open/stat/validation/flock `OSError` paths into the existing
  stable `CAN0_SETUP_FAILED` category with bounded sanitized detail. Helper
  stderr, ICT result, status, and Web error must not contain a traceback or
  attacker-controlled path/content.
- Preserve fixed helper path, no-argument CLI, sudoers scope, can0 setup order,
  readiness semantics, SocketCAN behavior, and all frame construction.

## Acceptance Criteria

- [ ] A normal root-owned `0700` directory plus root-owned regular `0600`
  singleton lock serializes complete concurrent setup transactions.
- [ ] A user-preoccupied legacy/shared lock, wrong directory/file owner,
  group/other-writable mode, symlink, non-regular object, or hard-linked file is
  rejected before the first mutation command.
- [ ] Injected mkdir/open/stat/flock `PermissionError` and generic `OSError`
  return `CAN0_SETUP_FAILED`, produce no traceback, and keep the helper process
  contract deterministic.
- [ ] A concurrency regression proves the second setup cannot enter its first
  inspect/mutation until the first complete transaction releases the lock.
- [ ] Ready no-op, mismatch configuration, restoration-on-failure,
  post-verification, installer/sudoers, and package-layout tests remain valid.

## Out of Scope

- Changing can0 parameters, transport sending, CAN bytes, sudoers command
  breadth, other ICT features, or introducing a daemon/system service.
