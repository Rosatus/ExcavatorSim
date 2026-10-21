# Correct SY135 QML neutral semantics

## Goal

Commit the verified QML renderer neutral-angle correction, regression coverage, contract update, and missing Godot checkpoint UID.

## Requirements

- Treat the external SY135 QML/C++ implementation as the immutable semantic
  authority for work-equipment joint angles.
- Correct the built-in compatibility profile so the QML renderer's fixed
  arm/bucket `+180 degree` offsets produce the Godot neutral adjacent-link
  rotations `(+35, -90, -50)`.
- Preserve the correction as an executable Python regression and document the
  cross-layer contract in the backend specification.
- Track the stable Godot UID generated for the existing CAN/QML pose checkpoint
  test without changing that test's behavior.
- Keep these changes separate from the archived operator-input semantics task.

## Acceptance Criteria

- [x] The built-in profile emits neutral QML joint outputs `(35, 90, 130)`.
- [x] Regression tests independently apply the QML renderer offsets and compare
  neutral plus isolated joint motion against Godot adjacent-frame relations.
- [x] The CAN integration test proves decoded frames reconstruct the same
  rendered neutral joint relations.
- [x] The QML compatibility specification explains why a Sensor2Ang
  inverse/forward round-trip alone is insufficient.
- [x] The checkpoint test's `.gd.uid` sidecar is tracked consistently with the
  rest of the Godot test suite.
- [x] Focused tests, repository quality gates, and whitespace checks pass, or a
  pre-existing environment-only limitation is recorded precisely.
- [x] Work is committed in reviewable batches, pushed to `origin/main`, and the
  Trellis task is archived with a journal entry.

## Notes

- External source evidence:
  `E:/projects/dev_arch2.0_36b5586c/GuideSystem/GuideSystemModuleNew/Working/WorkingModel3DView.qml`
  applies `boomPhi`, `armPhi + 180`, and `bktPhi + 180` as nested local-X
  rotations.
- This is a lightweight corrective task; the verified local diff already
  contains the implementation, contract update, and regression coverage.
- Validation on 2026-08-27: Ruff, strict mypy, all 182 backend tests,
  provenance, the 17-test QML compatibility suite, `git diff --check`, and the
  31-script Godot standalone matrix passed. The aggregate `pixi run verify`
  reached only its final standalone-path scan, which cannot stat the existing
  Linux virtual-environment link `tools/can_gateway/.venv-linux/lib64` on
  Windows (`WinError 1920`); no environment files were changed.
