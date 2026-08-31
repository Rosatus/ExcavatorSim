# Design — Writable Root-Owned `/run` Compatibility

## 1. Security Boundary

Relax only the parent-runtime predicate:

```text
opened /run inode:       directory + uid 0
opened excavatorsim:     directory + uid 0 + exact 0700
opened can0.lock:        regular + uid 0 + exact 0600 + st_nlink == 1
```

`/run` remains opened as a real directory with `O_DIRECTORY|O_NOFOLLOW`, then
validated by `fstat`. The implementation removes only the
`stat.S_IMODE(metadata.st_mode) & 0o022` rejection from
`_validate_runtime_root()`. It does not merge parent, child, or lock validators.

The child and lock remain the privileged object boundary. Every authorization
decision is made from the already-open fd rather than a path-only precheck.

## 2. Acquisition and Failure Semantics

The syscall sequence remains unchanged:

```text
open /run no-follow/directory -> fstat directory + uid 0
mkdirat excavatorsim 0700, tolerate only existing entry
openat excavatorsim no-follow/directory -> fstat exact root:0700
openat can0.lock no-follow/create -> fstat root:0600 regular single-link
flock exclusive -> complete configure transaction -> close fds
```

An attacker-created directory, symlink, file, or hard link is never repaired or
followed. Validation/open failures retain phase-specific, bounded
`CAN0_SETUP_FAILED` details and happen before runner inspection/mutation.

## 3. Threat-Model Trade-off

On a root-owned but writable `/run`, an unprivileged user may precreate or, when
the parent lacks sticky-bit protection, rename entries. The no-follow and
after-open validation sequence prevents those entries from becoming confused
deputies or redirecting privileged writes, but cannot prevent a local attacker
from causing setup denial of service. The approved behavior is fail-closed with
a stable diagnostic, not automatic takeover.

This deliberately supersedes only the archived task's parent-mode assumption.
Its strict child/lock inode rules and syscall strategy remain authoritative.

## 4. Regression Strategy

- Pure validator cases accept root-owned `0777` and reject wrong type/UID.
- An injected end-to-end lock acquisition uses runtime `0777` and safe child
  and lock metadata, proving the transaction proceeds.
- Unsafe child/lock matrices run under the same writable-parent metadata and
  prove no runner call occurs.
- Explicit flag assertions protect `O_DIRECTORY`/`O_NOFOLLOW`; injected
  symlink-style open errors protect the stable diagnostic boundary.
- Existing injected mutual exclusion stays the fast cross-platform authority.
  The root-only real Linux flock test remains a focused optional platform check.

## 5. Distribution and Rollback

The helper is frozen from `can0_setup_helper.py` plus `can0_setup.py` by
`tools/can_gateway/dist_linux.sh`; source-only validation is insufficient for
deployment. The unified release builder must refresh standalone Linux Gateway,
the Godot-bundled Linux copy, archive permissions, and build manifests.

Rollback is a source revert plus a Linux release rebuild. No state migration is
required because the on-disk lock path, directory/file modes, and helper CLI do
not change.

