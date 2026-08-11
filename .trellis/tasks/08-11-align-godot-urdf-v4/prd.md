# Align Godot With SY205 URDF v4

## Goal

Update the Godot client so its model identity and parity fixtures match the active SY205 backend
URDF.

## Requirements

- Depend on the active backend replacement from M2.
- Change Godot's expected model version to `sy205-glb-urdf-v4`.
- Regenerate or update the Godot parity fixture and its manifest hash from the active backend
  fixture.
- Keep the existing GLB frame map, local-pivot adapter, coordinate conversion, and passive four-bar
  presentation unchanged unless an ordinary regression test fails.
- Update fake handshakes and tests that directly encode the old model identity.

## Acceptance Criteria

- [ ] Godot accepts backend handshakes using `sy205-glb-urdf-v4`.
- [ ] Zero and one asymmetric pose render without missing frames, detached pivots, or non-finite
      transforms.
- [ ] Existing focused motion/pivot/linkage tests pass after fixture updates.
- [ ] The normal Godot standalone matrix and one MCP runtime smoke pass.

## Out of Scope

- A special min/max human approval sequence.
- Replay conversion or old-URDF compatibility work.
- Re-authoring the GLB or changing passive-linkage authority.
