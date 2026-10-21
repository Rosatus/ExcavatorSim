# GLB-derived URDF v4

## Goal

Replace the outdated Python kinematic URDF with the model generated from the approved SY205 Godot
GLB. Keep the GLB unchanged and label non-observable physical fields as provisional estimates.

## Requirements

1. Generate a right-handed, Z-up URDF from
   `godot/client/assets/visual/SY205_excavator_godot.glb` with the existing four active joint names
   and required frame names.
2. Use the imported GLB rest pose as joint zero: swing around Python +Z; boom, arm, and bucket
   around Python +X.
3. Keep `base_link` grounded and fold the GLB root/slew vertical offsets into `swing_joint`.
4. Generate deterministic primitive geometry, inertials, tooth markers, and sensor frames, clearly
   identifying all estimates in the evidence JSON.
5. Keep current joint limits and provisional calibration values unless ordinary tests show a direct
   incompatibility.
6. Use model version `sy205-glb-urdf-v4` while keeping wire protocol `babylon-sim-v3` because the
   message shape does not change.
7. Replace the active backend URDF with the generated SY205 model and regenerate affected fixtures
   and provenance.
8. Align Godot's model identity and parity fixtures with the active backend model. The existing GLB
   pivot adapter and passive four-bar presentation remain unchanged unless normal tests fail.
9. Store the old URDF at `assets/model/library/sy135_reference.urdf` for future SY135 GLB work. It is
   not an SY205 runtime, replay, or rollback model.

## Acceptance Criteria

- [x] M1 deterministically generates the candidate URDF, evidence JSON, and SY135 reference copy.
- [x] The generated model loads in Pinocchio with four active velocity coordinates, the existing
      joint order, and all required frames.
- [x] M2 replaces the active backend URDF, updates model identity/fixtures/provenance, and passes
      ordinary backend verification.
- [x] M3 updates Godot model identity/fixtures and passes focused motion plus normal standalone/MCP
      smoke checks.
- [x] Runtime and Godot agree that the active machine model is `sy205-glb-urdf-v4`.

## Out of Scope

- Production-accurate mass, inertia, hydraulics, friction, contact, or structural analysis.
- A dynamic rigid-body authority or feedback from Godot physics into Python motion.
- Replay conversion or special compatibility support for the old URDF.
- Re-exporting or modifying the user-owned GLB.
