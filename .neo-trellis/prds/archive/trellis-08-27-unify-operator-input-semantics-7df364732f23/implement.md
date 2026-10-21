# Implementation plan

## 1. Contract and shared calibration

- [x] Add the v4 operator-axis definition and `equipment-command-profile-v1`
  schema/data with SY135/SY205 signs.
- [x] Add strict Python validation plus deterministic Godot runtime-copy
  generation/parity verification.
- [x] Update active protocol/version manifests and tests so v3/v4 mismatch
  fails closed rather than reinterpreting axes.

## 2. Godot semantic input

- [x] Replace ambiguous `motion_*_positive/negative` bindings with explicit
  operator actions and one model-independent keyboard/XInput layout.
- [x] Add the shared operator-to-joint mapper, selected-model validation, and
  neutral-rearm lifecycle behavior.
- [x] Route ProductSession/local Jolt and MotionClient transport through the
  same mapper boundary without double conversion.
- [x] Keep digging response on joint coordinates and remove keyboard/gamepad
  model profiles plus opposite-key swapping.
- [x] Simplify the HUD to fixed action tiles and update guide copy/tests.

## 3. Python compatibility input

- [x] Decode v4 axes as operator semantics and apply the shared profile once
  before compatibility simulation consumes joint velocity commands.
- [x] Preserve gateway-only validation/ACK behavior and all focus/stale/zero
  input safety.
- [x] Add per-model neutral and isolated-direction tests matching Godot's
  semantic-to-joint results.

## 4. Cross-runtime and regression validation

- [x] Prove identical keyboard/gamepad operator vectors for all eight physical
  directions and both selected models.
- [x] Prove Godot/Python joint-axis parity for neutral and ± each channel.
- [x] Prove isolated final model motion meanings for both models and authority
  profiles.
- [x] Run Godot editor parsing, focused input/HUD/articulation tests, and the
  complete standalone matrix.
- [x] Run focused Python protocol/profile/runtime tests and `pixi run verify`.
- [x] Run provenance validation and confirm identical accepted-pose CAN/QML
  checkpoints remain unchanged.
- [x] Run `git diff --check` and Trellis task validation.

## Validation evidence

- Backend: Ruff, strict mypy, and 182 pytest cases passed.
- Godot: editor parse and the 31-script standalone matrix passed on Godot
  4.7.1, including mapper, HUD, both articulated models, CAN/QML checkpoints,
  and release-candidate coverage.
- Shared contract: generated-copy check and provenance verification passed.
- `pixi run verify` executed all code checks successfully; its final
  path-only scan is blocked by the pre-existing Windows-inaccessible
  `tools/can_gateway/.venv-linux/lib64` link (`WinError 1920`).

## Risk and rollback points

- Protocol-version edits must not land separately from both consumers.
- Generated Godot profile bytes/hash and provenance must be updated together.
- The mapper must run exactly once in both local and compatibility paths;
  tests should fail on both missing and double conversion.
- Preserve the user's pre-existing dirty QML/CAN profile files and do not stage
  them unless separately requested.
