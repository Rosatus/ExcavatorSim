# Unify operator input semantics

## Goal

Make keyboard and gamepad controls express one stable, model-independent
excavator operator intent. Convert that intent to each model's joint-coordinate
sign exactly once so input devices never carry SY135/SY205 calibration and the
same direction bug cannot recur independently across keyboard, gamepad, local
Jolt, and Python compatibility motion.

## Background

- The product has four equipment channels in fixed order `(swing, boom, arm,
  bucket)`, but the current `motion_*_positive/negative` names describe joint
  sign rather than operator outcome.
- Keyboard and gamepad presently have separate model multiplier tables. Their
  apparent disagreement is isolated to boom because physical keyboard `I`
  means stick-up while Godot joy Y positive means stick-down; the two tables are
  compensating both device coordinates and model joint coordinates at once.
- The corrected keyboard evidence establishes that SY135 and SY205 require
  different semantic-to-joint signs. That difference belongs at the selected
  model adapter, not in `InputMap`.
- Python currently treats `input_snapshot.axes` as joint-coordinate velocity
  commands. Reinterpreting the same v3 payload silently would be unsafe, so the
  semantic wire contract is introduced as `godot-pinocchio-v4` rather than
  changing v3 in place.
- CAN/QML projection consumes accepted pose transforms, not input axes. This
  task must not change CAN IDs, payload encoding, QML calibration, gateway pose
  projection, or the external relay.

## Requirements

- **R1 — Canonical operator vector:** define a versioned four-axis operator
  semantic vector in order `(swing, boom, arm, bucket)` with positive meanings
  `right rotation`, `boom raise`, `arm extend`, and `bucket curl`; negative
  means `left rotation`, `boom lower`, `arm retract`, and `bucket dump`.
- **R2 — Device-independent actions:** replace ambiguous joint-sign InputMap
  actions with explicit operator actions. Physical bindings are invariant
  across models: `A/D` left/right rotation, `I/K` boom lower/raise, `W/S` arm
  extend/retract, and `J/L` bucket curl/dump. The corresponding XInput stick
  direction must produce the same operator action and scalar as the keyboard.
- **R3 — One calibration source:** author one strict, versioned model command
  profile containing the semantic-to-joint sign for SY135 and SY205. Godot and
  Python consume that profile; any Godot runtime copy must be generated from
  the canonical source and guarded by exact parity/hash validation rather than
  maintained manually.
- **R4 — Exactly-once conversion:** convert operator axes to selected-model
  joint axes once at the motion-authority boundary. Local Jolt articulation and
  Python compatibility simulation must receive the same joint-coordinate
  result for the same `(model, operator vector)`. Digging response continues to
  act on the established joint-coordinate working direction after conversion.
- **R5 — Versioned transport:** add `godot-pinocchio-v4`, whose
  `input_snapshot.axes` explicitly carries the canonical operator vector.
  Client/server handshake, constants, schemas, manifests, fixtures, and tests
  move together. V3 is not silently reinterpreted and no dual semantic fallback
  is added to the product path.
- **R6 — Lifecycle safety:** model activation/reconnect/reset/focus loss retain
  zero re-arm. A model switch selects a complete validated command profile
  before non-zero operator input can be accepted; missing, malformed, unknown,
  or non-`±1` signs fail closed.
- **R7 — HUD truth:** the lower-right HUD remains keyed to physical controls and
  highlights the fixed operator action directly. It no longer discovers tiles
  by inspecting model-mutated key bindings. Operator guide text and labels must
  match the canonical meanings for both models.
- **R8 — Compatibility boundaries:** track controls, camera controls, lifecycle
  keys, joint limits, physics axes/anchors, pose presentation, CTN1 telemetry,
  Python CAN gateway, QML compatibility profiles, and CAN encoding remain
  unchanged.

## Acceptance Criteria

- [ ] **AC1:** a contract test locks the exact positive/negative meaning and
      order of all four operator axes in protocol v4.
- [ ] **AC2:** SY135 and SY205 install identical keyboard and joy events for all
      eight equipment actions; no keyboard/gamepad model multiplier table or
      opposite-action key swapping remains.
- [ ] **AC3:** keyboard and gamepad samples for each of the eight physical
      directions produce equal operator vectors before model conversion.
- [ ] **AC4:** the shared profile maps canonical operator axes to the expected
      joint signs for both models, is rejected on schema/hash/parity failure,
      and Godot/Python profile results agree for neutral plus both directions of
      every joint.
- [ ] **AC5:** isolated direction tests prove, for both models, `D/A` rotates
      right/left, `K/I` raises/lowers the boom, `W/S` extends/retracts the arm,
      and `J/L` curls/dumps the bucket in both local Jolt and Python
      compatibility paths.
- [ ] **AC6:** v3/v4 mismatch fails handshake before input acceptance; v4 zero
      arming, focus-loss zero, monotonic sequence, ACK correlation, reconnect,
      and model-switch neutral re-arm tests pass.
- [ ] **AC7:** HUD key labels and held highlights stay correct across both model
      switches without dynamic key-to-tile remapping.
- [ ] **AC8:** Godot standalone tests, focused Python protocol/model/runtime
      tests, the complete backend verification gate, and cross-runtime sign
      parity pass. Existing CAN/QML pose checkpoints remain byte/numerically
      unchanged for identical accepted poses.

## Out of Scope

- Modifying QML, the external CAN relay, CAN IDs/payload units, QML calibration,
  or pose-to-CAN projection.
- Changing excavator joint geometry, limits, speed/acceleration tuning, track
  controls, or digging behavior beyond preserving the pre-existing accepted
  joint-coordinate response.
- Supporting user-configurable control schemes, alternate excavator control
  patterns, or runtime remapping UI.
- Maintaining a v3/v4 mixed-semantic compatibility mode; mismatched versions
  fail closed.
