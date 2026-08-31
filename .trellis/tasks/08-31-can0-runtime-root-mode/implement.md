# Implementation Plan — Writable Root-Owned `/run`

## 1. Preflight

- Preserve unrelated working-tree changes, especially `docs/procurement/` and
  the pending release-build/spec work.
- Read the current task artifacts and backend CAN Gateway spec before editing.
- Confirm no release binary is running before the final packaging step.

## 2. Minimal Helper Change

- In `tools/can_gateway/can0_setup.py`, change
  `_validate_runtime_root()` to check only directory type and UID 0.
- Leave `_validate_lock_directory()`, `_validate_lock_file()`, lock open flags,
  syscall ordering, stable errors, and `configure_can0()` untouched.

## 3. Focused Regression Tests

- Update `tools/can_gateway/tests/test_can0_setup.py` so root-owned `0777`
  runtime metadata is accepted while wrong type/UID remain rejected.
- Add an injected successful transaction with runtime `0777` and strict
  child/lock metadata.
- Exercise unsafe child and lock cases while the parent is writable; assert
  `CAN0_SETUP_FAILED`, sanitized detail, and zero runner calls.
- Assert required no-follow/directory flags and stable symlink/open failure
  handling.
- Retain the existing injected complete-transaction mutex test and real Linux
  flock test without expanding into soak or hardware tests.

## 4. Contracts and Operator Documentation

- Update `.trellis/spec/backend/can-gateway-control.md` to state that `/run`
  need only be a real root-owned directory; keep `/run/excavatorsim` `0700` and
  `can0.lock` `0600` singleton requirements explicit.
- Update `tools/can_gateway/README.md` with target compatibility, fail-closed
  behavior, and the writable-parent denial-of-service limitation.
- Do not edit the archived task; the new task records the superseding decision.

## 5. Fast Verification

- Run Ruff against the changed Python files.
- Run the focused `test_can0_setup` unit suite.
- Run shell syntax checks for packaging scripts only if packaging-related files
  are touched.
- Do not run Godot visual tests, paired soak, or unrelated full-suite tests.

## 6. Linux Release Refresh

- After intended source/spec changes are safely committed or otherwise isolated
  from unrelated work, run `tools/build_release_dist.ps1` to rebuild the
  standalone Linux helper and Godot Linux package.
- Verify standalone and bundled helper hashes match, helper/archive executable
  modes are `0755`, no output CSV/log residue is packaged, and manifests record
  the intended commit/dirty state.
- Smoke the frozen helper in a root Linux namespace or target-equivalent fixture
  whose opened runtime parent is root-owned `0777`; verify unsafe child/lock
  objects still fail before CAN commands. This is a focused helper smoke, not a
  hardware or visual acceptance test.

## 7. Review Gate and Rollback Point

- Review the final diff for changes outside runtime-root validation,
  tests/spec/docs, and generated release artifacts.
- If any strict child/lock validator or CAN behavior changed, stop and revert
  that scope before packaging.
- Record final artifact paths and manifests for redeployment.

