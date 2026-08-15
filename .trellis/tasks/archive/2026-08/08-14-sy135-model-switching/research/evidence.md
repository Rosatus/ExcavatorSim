# SY135 Model-Switching Evidence

## Source Asset

| Level | Evidence |
|---|---|
| Observed | Source: `E:/projects/blender/Excavator/SY135/export/godot/SY135_excavator_godot.glb`; 5,613,436 bytes; SHA-256 `8e0f478b265bb0f32f7736a0e388f5bb812b7f36c143edeb1553ff86d2d960c9`. |
| Observed | glTF 2.0, one scene, 14 nodes, 8 meshes, 9 materials, 3 embedded PNG images, no animation, no skin, and no required extensions. |
| Declared | Root/pivot chain: indices `13/11/8/7/6` named `CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT`; `REF_BUCKET_TIP` is node 5 below the bucket pivot. |
| Declared | Exporter extras call the slew axis `Z`, other joint axes `X`, and provide rest/link values. Names/extras are claims, not validated Godot runtime axes or pin centers. |
| Validated | Godot 4.7.1 imports 15 scene nodes (14 glTF nodes plus the scene wrapper), 8 meshes, 9 surfaces with materials, and all 3 embedded textures; aggregate bounds are position `(-1.276079, 0.0, -6.091319)` and size `(2.522953, 4.984285, 7.912169)`. No animation, skeleton, collision, or script resources were introduced. |
| Validated | The imported five-frame chain preserves the declared parents and unit scales. Pinocchio-derived zero, four isolated poses, one asymmetric pose, and zero restore validate Godot `+Y` slew, `+X` work-equipment axes, positive signs, unchanged local origins, and clean subtree motion. `REF_BUCKET_TIP` remains a bucket child at local offset `(0.0, 0.0, -1.212636)`. |
| Decision | Copy the supplied GLB unchanged after implementation approval; do not re-export or alter the user-owned source. Reject runtime activation if controlled poses disprove the pivot contract. |

## Existing SY135 Backend Seed

- `assets/model/library/sy135_reference.urdf:95` through `:121` define the required continuous `swing_joint`, `boom_joint`, `arm_joint`, and `bucket_joint` chain.
- `assets/model/library/sy135_reference.urdf:122` through `:162` provide the required tooth/GNSS/IMU frames used by the model contract.
- `assets/provenance.json:10` records the reference seed and its upstream AGPL-3.0-only provenance.
- `assets/model/sy205_glb_derived_v4.json:151` explicitly prevents using the SY135 seed as an SY205 runtime/replay/rollback model. Promoting it as the selectable SY135 model must preserve that boundary.
- The URDF's joint origins differ from the new GLB's visual link lengths. The adapter must consume adjacent authority rotation deltas and preserve imported visual origins; it must not force Python frame origins onto GLB pivots.

## Current Single-Model Assumptions

- Backend startup fixes `URDF_PATH` and constructs one `ExcavatorModel` in `backend/src/babylon_sim/cli.py:76`.
- `RuntimeController` constructs simulation, recording, replay, and exchange state around that model in `backend/src/babylon_sim/runtime.py:119`.
- `create_app` stores fixed model/visual paths and each WebSocket captures the runtime in `backend/src/babylon_sim/web.py:218` and `:600`.
- Model identity is fixed in `backend/src/babylon_sim/constants.py:20`, `protocol/version-manifest.json:2`, `protocol/godot-pinocchio-v3.schema.json:45`, and `godot/client/scripts/motion_protocol.gd:12`.
- RRD export/import binds recordings to the fixed model identity in `backend/src/babylon_sim/rrd.py:86` and `:376`.
- Godot mounts only `PresentationRoot/SY205Excavator` in `godot/client/scenes/main.tscn:241`; `MotionPresentation`, `CameraRig`, and contract tests use SY205-specific paths.
- `ExcavationWorld` derives contact from `bucket_link` plus a fixed `Vector3(0.0, -0.55, 0.0)` in `godot/client/scripts/excavation_world.gd:10` and `:144`. This must become model-specific.

## Existing Reset And Authority Seams

- `MotionClient` already clears pose buffers, pending inputs/commands, accepted revisions, and authority generation on reconnect/reset/epoch changes (`godot/client/scripts/motion_client.gd:397`, `:431`, `:493`, `:623`).
- `ExcavationWorld` clears bucket soil and previous-tooth state on pose/authority clear while keeping the logical terrain authority (`godot/client/scripts/excavation_world.gd:131`).
- `CameraRig` resolves its target only once (`godot/client/scripts/camera_rig.gd:17`), so model activation must explicitly retarget it.

## Recommended Boundary

- Use a controlled reconnect/new-session selection. Godot records the requested model, disconnects and clears derived state, then includes that model in the next hello.
- The backend resolves the requested descriptor before `hello_ack`, stops the previous runtime only when no active session owns it, creates a fresh runtime around the selected URDF, and replies with the selected identity.
- A conflicting selection while another session remains active fails with a stable busy/incompatible diagnostic rather than silently switching or mismatching models.
- Keep SY205 as the default. Preserve `TerrainState`; clear model-coupled transient state and all backend runtime/legacy recording state.

## Verification Inventory

- Godot standalone entry: `godot/client/tests/run_standalone_matrix.ps1`.
- Existing import/pivot pattern: `godot/client/tests/sy205_glb_test.gd`.
- Existing motion/presentation parity pattern: `godot/client/tests/motion_client_test.gd`.
- Backend full gate: `pixi run verify`; runtime gate: `pixi run backend-smoke`.
- Required new coverage: per-model asset contract, SY135 Pinocchio fixture/parity, model identity/schema, session replacement, cross-model recording rejection, and `SY205 -> SY135 -> SY205` Godot lifecycle.
