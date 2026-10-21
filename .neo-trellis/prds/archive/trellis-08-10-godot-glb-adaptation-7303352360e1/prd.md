# Integrate the SY205 Godot GLB

## Goal

Place the user-supplied SY205 excavator GLB into the Godot client, verify its imported structure, and establish a stable Godot-side visual adapter contract before the motion vertical slice starts. Subsequent motion work must use this delivered asset instead of the placeholder mesh while preserving Python motion authority.

## Confirmed facts

- The source file is `E:/projects/blender/Excavator/SY205/export/godot/SY205_excavator_godot.glb`.
- The source is a single GLB scene rather than five separate files. Its SHA-256 is `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a`.
- The GLB contains 20 nodes, 11 meshes, 9 materials, two embedded PNG textures, no skins, and no animations. The embedded textures are `lvdai_T` (512×512) and `Excavator_T` (2048×2048).
- The imported hierarchy contains explicit mechanical pivots and five identifiable frame groups: root/base, slew/upper structure, boom base, arm hinge, and bucket hinge. It also contains four visual linkage meshes and reference pivots.
- The existing Python frame contract remains authoritative: `base_link`, `upper_structure_link`, `boom_link`, `arm_link`, and `bucket_link` use row-array right-handed transforms and the existing frame-parity fixture.
- The Godot client owns visual composition. It must not turn the GLB hierarchy, local physics, or any visual effect into a second motion authority.

## Requirements

### R1 — Reproducible asset placement

- Copy the source bytes without re-exporting or modifying them to `godot/client/assets/visual/SY205_excavator_godot.glb`.
- Record the source path, byte size, SHA-256, inspection date, and import assumptions in a Godot-side asset note/manifest.
- Keep the asset under the Godot client; do not make the backend protocol or legacy five-file manifest depend on the new filename.

### R2 — Import and structure validation

- Import the GLB with the installed Godot 4.7.1 Forward+ project and verify that it opens without editor/import errors.
- Verify the exact pivot paths and mesh ownership listed in the design artifact.
- Verify that embedded material textures survive import and that the asset does not require external texture files.
- Treat the absence of animation, skin, or collision resources as an explicit first-slice fact; do not synthesize authoritative physics from the visual asset.

### R3 — Five-frame visual adapter contract

- Define a Godot-side mapping from the Python frame names to the GLB pivot nodes without renaming protocol identifiers:
  `base_link` → `CTRL_EXCAVATOR_ROOT`,
  `upper_structure_link` → `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW`,
  `boom_link` → `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE`,
  `arm_link` → `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT`,
  `bucket_link` → `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT`.
- Preserve the GLB's existing parent-child mechanical hierarchy so boom, arm, bucket, and linkage visuals move as one coherent presentation chain.
- Calibrate the asset root and per-frame rest transforms against `backend/tests/fixtures/frame-parity/baseline.json` before enabling live pose updates. Do not guess matrix storage, handedness, or scale from raw GLB JSON alone.
- Keep linkage meshes attached to the imported hierarchy for the first slice; they are visual auxiliaries, not independently commanded joints.

### R4 — Handoff to motion work

- Make the adapter contract consumable by M2 without changing the motion protocol or backend authority boundary.
- Keep placeholders available as a fallback until the imported asset passes the static structure and frame-parity checks.
- Add a focused headless/MCP validation path that proves the asset can be instantiated and all five mapping targets resolve.

## Acceptance criteria

- [x] The copied file exists at `godot/client/assets/visual/SY205_excavator_godot.glb` and its SHA-256 equals the supplied source hash.
- [x] Godot imports and instantiates the GLB with no editor or headless import errors.
- [x] All five mapping targets resolve, and the imported scene contains the expected major meshes and linkage nodes.
- [x] Embedded textures/materials are available after import; no external texture path is required.
- [x] The adapter manifest records the mapping, calibration status, and explicit no-animation/no-collision limitation.
- [x] A focused Godot check passes and the existing backend/protocol files remain unchanged.

## Out of scope

- Re-authoring, remodeling, splitting, or repairing the user-supplied GLB.
- Connecting WebSocket motion, keyboard/gamepad input, terrain, soil, or replay; those remain in later milestones.
- Creating authoritative rigid-body/collision behavior from the GLB.
- Changing the existing backend visual manifest, protocol identifiers, or Python motion service.

## Open questions

- None blocking planning. The realistic-first recommendation is to preserve the supplied linkage meshes as part of the imported mechanical hierarchy and calibrate only the five named frame targets; no additional user decision is required unless the visual review finds a visible coordinate or scale mismatch.
