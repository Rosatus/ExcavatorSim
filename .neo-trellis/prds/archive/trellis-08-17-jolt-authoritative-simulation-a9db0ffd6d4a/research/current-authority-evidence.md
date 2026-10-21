# Current Authority And Migration Evidence

## Observed Runtime

- `backend/src/babylon_sim/simulation.py:114-171` integrates four independent
  command channels with calibration limits; it has no gravity, contact, chassis,
  mass, or hydraulic state.
- `backend/src/babylon_sim/model.py:156-164` calls Pinocchio forward kinematics and
  frame placement only.
- `backend/src/babylon_sim/runtime.py:446-488,555-582` owns the 100 Hz Python tick
  and publishes the resulting authoritative view.
- `godot/client/scripts/motion_client.gd:573-617` gates Python epoch/revision and
  accepts named-frame poses.
- `godot/client/scripts/tracked_chassis_controller.gd:42-57` directly writes the
  local chassis transform; Jolt only provides an optional validated height hint at
  `:168-210`.
- `godot/client/scripts/terrain_collider.gd:4-6,80-115` is a copied static collider
  derivative and explicitly does not feed Python or TerrainState.

## Existing Migration Seams

- Runtime profiles and capability negotiation already isolate optional workers:
  `backend/src/babylon_sim/runtime.py:144-204,228-249`.
- `bucket_load_feedback_v1` demonstrates negotiated, generation-tagged,
  latest-value Godot-to-Python observations without making them authority:
  `backend/src/babylon_sim/runtime.py:330-363`.
- `ChassisMotionRoot` provides a local pose owner that can be replaced by a physics
  rig in an explicit mode, while `MotionPresentation` retains visual/model mapping.
- Model switching already rebuilds sessions rather than mutating an established
  Python runtime in place: `backend/src/babylon_sim/session_manager.py:124-159`.

## Contract Implications

- The strict v3 schema cannot absorb new authority/body/contact/sensor fields
  silently; use a separate versioned contract/profile.
- New state requires authority epoch, physics tick, monotonic time, model/rig and
  terrain identity. Do not reuse recording `buffer_generation`.
- Input safety semantics must move to or be revalidated by the actual Godot
  authority, even when commands enter through Python.

