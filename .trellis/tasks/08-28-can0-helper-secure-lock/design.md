# Design — Secure Linux can0 helper locking

## 1. Root-only runtime path

Use `/run/excavatorsim/can0.lock`, not a file directly under `/run/lock`.
`/run` must be opened as a root-owned directory with no group/other write before
creating the child. The helper creates `excavatorsim` as root mode `0700`; an
existing child is accepted only after fd-based validation.

The lock is persistent for the boot lifetime, root-owned mode `0600`, regular,
and has exactly one link. It is not unlinked after use; `flock` release occurs
when its fd closes.

## 2. Safe acquisition sequence

Implement the syscall boundary behind a small injectable lock-ops seam so pure
validation and concurrency can be tested without root/hardware.

```text
open /run O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC
  → fstat: directory, uid 0, no group/other write
mkdirat("excavatorsim", 0700), tolerate only EEXIST
openat directory O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC
  → fstat: directory, uid 0, exact safe mode
openat lock O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600
  → fstat: regular, uid 0, no group/other access, st_nlink == 1
flock(fd, LOCK_EX)
  → run complete configure_can0 transaction
  → close fd releases lock
```

After-open `fstat` is authoritative; path-only prechecks never authorize use.
Unsafe existing objects are rejected, never chmod/chown/unlinked by runtime.

## 3. Errors

All directory/file create, open, validation, and flock failures are converted at
the lock boundary to `Can0SetupError(CAN0_SETUP_FAILED, <bounded message>)`.
Messages identify only the stable phase (`lock directory unavailable`, `unsafe
lock object`, `cannot acquire setup lock`) and do not echo attacker-controlled
paths, owners, modes, or raw exception text.

`can0_setup_helper.main()` continues producing one line
`CAN0_SETUP_FAILED: ...` and exit 1, without traceback. No `ip link set` command
runs before acquisition succeeds.

## 4. Concurrency tests

- Pure stat validator tests cover directory/file owner, mode, type, symlink and
  link-count variants with injected stat-like values.
- Injected ops tests convert mkdir/open/fstat/flock `PermissionError` and
  `OSError` into stable errors.
- A Linux multiprocessing test uses two helpers/lock holders and events/pipes to
  prove the second complete transaction cannot enter while the first holds the
  fd. Windows CI uses an injected blocking lock adapter for deterministic
  transaction-level mutual exclusion.

## 5. Compatibility

No changes occur below `configure_can0` command arguments or above its stable
error boundary. Interface parameters, setup/recovery order, helper CLI,
sudoers path, SocketCAN, ICT protocol, and frame construction are unchanged.
