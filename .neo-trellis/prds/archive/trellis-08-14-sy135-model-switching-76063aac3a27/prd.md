# Add SY135 Model Switching

## Goal

Import the supplied SY135 articulated GLB without modifying its source bytes, make SY205 and SY135 selectable as coherent simulation models, and ensure the Godot visual model and Python/Pinocchio URDF always use the same selected model identity.

The operator must be able to choose the excavator model without weakening the existing authority boundary: Python remains authoritative for kinematics, Godot adapts authority frames to the selected imported visual hierarchy, and excavation remains driven by the active model's `bucket_link` presentation frame.

## Background And Confirmed Facts

- The supplied source is `E:/projects/blender/Excavator/SY135/export/godot/SY135_excavator_godot.glb`, 5,613,436 bytes, SHA-256 `8e0f478b265bb0f32f7736a0e388f5bb812b7f36c143edeb1553ff86d2d960c9`.
- Raw GLB inspection reports one scene, 14 nodes, 8 meshes, 9 materials, 3 embedded PNG images, no animation, no skin, and no required extensions. Its declared pivot chain is `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT`, with a `REF_BUCKET_TIP` child.
- Pivot names, extras, axes, and rest angles are declared exporter evidence only. Exact Godot node paths, imported transforms, materials, bounds, rotation signs, and bucket-tip behavior still require controlled import validation before they become runtime contracts.
- The current Godot scene, motion presentation manifest, camera target, tests, protocol constants, and backend startup path assume one fixed SY205 model.
- `assets/model/library/sy135_reference.urdf` is an intentionally preserved future-SY135 seed. It has the required four active joint names and five authority frame names, but it has schematic geometry and different joint origins/rest rotations from SY205. Existing provenance explicitly forbids treating it as an SY205 runtime, replay, or rollback artifact.
- The backend constructs `ExcavatorModel`, live simulation, replay model, recording exchange, `/api/model`, and protocol identity at process/session construction time. Existing lifecycle reset does not replace the model.
- Model identity is currently fixed as `sy205-glb-urdf-v4` across backend constants, protocol schema/manifest, Godot handshake validation, parity fixtures, and RRD metadata/import validation.

## Requirements

### R1. Preserve And Validate The SY135 Asset

- Copy the supplied GLB unchanged into the repository only after planning approval; retain and verify its source SHA-256 and byte size.
- Validate the imported Godot `PackedScene`: exact node paths and parents, rest-local transforms and scales, mesh/material/texture survival, aggregate bounds, absence of unexpected skeleton/animation/collision/script resources, and controlled zero/isolated/asymmetric poses.
- Record observed source facts separately from validated runtime facts and project decisions.
- Reject the asset for runtime use if controlled poses disprove the declared pivot centers/axes or require hidden per-node repair; report re-authoring needs instead of mutating mesh vertices or source pivots.

### R2. Model Registry And Identity

- Define one model descriptor/registry contract that binds each selectable model ID to its backend URDF, protocol model version, Godot GLB, visual manifest, parity fixture, and any model-specific passive-mechanism policy.
- Keep SY205 as the default selection and preserve its current visual and kinematic behavior.
- Give SY135 a distinct runtime model version; never label SY135 state, downloads, recordings, replays, diagnostics, or visual contracts as SY205.
- Make `/api/model`, live simulation, replay kinematics, handshake metadata, Godot compatibility checks, and recording metadata resolve from the same selected descriptor.

### R3. Synchronized Selection

- Expose an operator-facing model selector using the existing Godot operator UI conventions.
- A successful selection must result in exactly one active Godot visual model and the matching Python/Pinocchio URDF.
- Reject unknown, unavailable, or incompatible model IDs with a stable diagnostic; do not fall back silently to a mismatched visual or URDF.
- Apply a user-approved controlled new-session switch: the Godot UI may request a different model, but the backend creates a fresh simulation session and the client reconnects before that model becomes ready.
- The new-session switch must not reuse stale pose, command, recording, replay, camera-target, bucket-tooth, or excavation transient state from the previous model.
- Preserve the authoritative Godot `TerrainState` heightfield across the model-session change, while clearing bucket inventory, previous-tooth sweep state, particles, and generation-gated derived work. Model selection does not change terrain authority.

### R4. Model-Specific Presentation Contracts

- Parameterize `MotionPresentation` by the selected model's visual manifest and asset root while preserving imported local origins/scales and applying clean adjacent-frame local rotation deltas parent-to-child.
- Parameterize the camera target and excavation bucket-frame lookup by the active model instead of an SY205 node name.
- Move the excavation contact proxy into the model-specific visual contract. Preserve SY205's existing offset and bind SY135 to its validated `REF_BUCKET_TIP`; do not reuse SY205's fixed `-0.55 m` offset for SY135.
- Reinitialize all presentation mappings, rest transforms, diagnostics, and passive linkage state when a new model becomes active.
- Do not assume SY205's visual four-bar linkage exists on SY135. SY135 may declare no passive mechanism if the imported hierarchy has none.

### R5. Backend URDF And Recording Isolation

- Promote the preserved SY135 URDF only under a new SY135 runtime role and provenance record; do not overwrite or reinterpret the preserved reference bytes as an SY205 artifact.
- Preserve the required joint/frame-name contract and validate Pinocchio `nv == 4`, finite transforms, and frame parity for both models.
- Keep replay kinematics and `/api/model` bound to the same selected URDF as live simulation.
- Record the selected model identity in exports and reject or explicitly isolate cross-model replay/import rather than evaluating one model's joint samples through another model's URDF.

### R6. Compatibility And Quality

- Existing SY205 startup and tests remain valid when no explicit model is selected.
- Add per-model import/contract/parity checks and a `SY205 -> SY135 -> SY205` selection lifecycle test at the selected lifecycle boundary.
- Run the Godot standalone matrix, backend tests, lint/type checks, provenance verification, runtime smoke, and visual review for both models.

## Acceptance Criteria

- [ ] The repository copy of the SY135 GLB is byte-identical to the supplied source and its identity is covered by automated checks.
- [ ] SY135 passes controlled Godot import and articulated-pose validation, or implementation stops with concrete re-authoring evidence before presenting it as selectable.
- [ ] The operator can select SY205 or SY135 through a controlled new-session reconnect, and the active Godot GLB, Python URDF, handshake identity, model download, live state, and replay state agree.
- [ ] SY205 remains the default and preserves its current behavior when no selection is provided.
- [ ] Switching cannot leave two active visuals or stale pose, camera, bucket-tooth, excavation, recording, or replay state.
- [ ] Switching preserves the logical terrain heightfield but clears bucket soil, previous-tooth sweep state, particles, and stale derived work.
- [ ] Unknown/incompatible model selection fails explicitly without a cross-model fallback.
- [ ] Both models pass model-specific import, hierarchy, material, transform, Pinocchio, protocol, and parity checks.
- [ ] Full repository quality gates and human visual checks pass for both models.

## Out Of Scope

- Re-exporting or modifying the user-owned Blender/GLB source during this task.
- Feeding Godot-derived transforms or passive visual linkage state back into Python authority.
- Replacing the hybrid terrain/excavation authority model or changing Jolt/Terrain3D ownership.
- Making arbitrary third-party excavator models dynamically discoverable without an explicit reviewed descriptor and contract.
- Claiming physical calibration fidelity beyond the supplied URDF and validated visual/kinematic contracts.

## Key Product Decision

- The user approved an operator-visible model change that takes effect through a controlled fresh simulation session. It is not a continuous hot swap and does not migrate pose, commands, recording/replay state, bucket inventory, or excavation transient state between models.
