---
name: godot-excavator-attachment-import
description: "Import swap-in work attachments (tiltrotators, quick-coupler tools, buckets, breakers, grapples) into the ExcavatorSim Godot client: mount under the bucket_link frame, bake authored passive-mechanism animation into a runtime lookup table, wire modifier-key controls, bind soil contracts, and verify against the source clip. Use when adding a new attachment to attachment_catalog.json, adapting a Blender-animated attachment GLB, adding a modifier-key control pair, or diagnosing passive linkage / morph-track misbehaviour during attachment joint drive."
---

# Import Excavator Attachments

The pipeline, end to end: source docs → GLB inspection → passive-rig bake → catalog entry →
runtime rig → modifier-key controls → soil integration → verification. The working example is
`xtr13_gb12` (Steelwrist XTR13 tiltrotator + GB12 bucket); see
[references/steelwrist-xtr13-case.md](references/steelwrist-xtr13-case.md) for its concrete data.

Anchor files:

- `godot/client/resources/models/attachment_catalog.json` — `couplers` (mount platform:
  GLB, joints, controls, socket path, hidden frame) and `tools` (GLB, socket root, soil
  contract, `supported_couplers`). The tool's `supported_couplers` list is the
  compatibility contract: switching a tool auto-resolves the coupler to its first
  supported entry, and switching a coupler auto-resolves the tool to the first
  compatible one. `coupler_id "none"` means direct pin; `kind: "native"` tools are the
  host model's own bucket mesh (they are hidden whenever a coupler is mounted).
- `godot/client/scripts/attachment_rig.gd` — runtime mount/pose driver (`AttachmentRig` node in `main.tscn`)
- `godot/client/scripts/attachment_input_mapper.gd` — modifier-key axis borrowing
- `tools/bake_steelwrist_tilt_rig.py` — reference baker (GLB binary → rig JSON)
- `godot/client/tests/attachment_switch_test.gd` — regression pattern

## 1. Establish the mount contract from source material

Read the attachment's own documentation first (e.g. `装配与动画说明.md` beside the .blend). When
the .blend is open, use Blender MCP to enumerate actions/clips and the F-curve channels each one
drives. Produce three lists before writing anything:

- **Mount root** — the node that parents to the host `bucket_link` frame (e.g. `XTR13_ROOT`).
- **Driven joints** — nodes the operator controls (e.g. `TILT_Y`, `ROTATE_Z`), their local axes,
  ranges, and which clip is their authority.
- **Passive mechanism** — every node/track the clips drive besides the joints: linkage pivots,
  rod translations, morph-target weights. These replay from a baked table, never solved live.

Also record the **socket contract**: which node a swappable tool mounts under (e.g.
`S50_TOOL_SOCKET`), whether tools mount with an identity transform, and which nodes stay fixed.

## 2. Inspect the GLB as Godot imports it

Instantiate the GLB headless (`PackedScene` → `instantiate()`) and dump the hierarchy around the
joints. Two import facts drive all name handling:

- Godot sanitizes node names with `validate_node_name()` semantics: `.` becomes `_`
  (`chrome piston.001` → `chrome piston_001`), while `|` and spaces survive. Resolve every
  catalog/baked path against the sanitized name — the direct-path resolver in
  `attachment_rig.gd` compares both raw and sanitized names.
- The imported `AnimationPlayer` sits as a **sibling** of the asset root, so it is freed with
  the unused instance wrapper after reparenting the root — it cannot interfere at runtime, and
  it must not be the runtime authority anyway (the rig replays the baked table).

Capture rest-local transforms, then check clip semantics: authored animation tracks store
**absolute local TRS** (playback overwrites the node's transform outright). Drive runtime joints
with the same absolute axis-angle convention.

## 3. Bake the passive table correctly

Follow `tools/bake_steelwrist_tilt_rig.py`: parse the glTF JSON + BIN chunk directly, build full
node paths from the `children` graph, sample the drive-joint rotation channel for angle keys, and
per key capture every passive channel (rotation, translation, weights). Three details that make
the data correct:

- **Morph weights are vector-valued.** A glTF `weights` channel outputs a flat scalar array of
  `n_keys × n_targets`; compute `width = out_accessor.count / in_accessor.count` and slice one
  width-wide vector per key. Baking a single scalar silently drops all but the first morph
  target and the hoses/shrouds deform into garbage.
- **Sort samples by angle.** Clip time walks non-monotonically (`0 → +45 → 0 → -45 → 0`); a
  time-ordered table defeats range lookup. Sort by `angle_deg` at bake or load.
- **Paths come from the glTF hierarchy, not intuition.** Passive nodes may live under a fixed
  ancestor (the XTR13 pistons sit under `UPPER_FIXED`, not under `TILT_Y`). Build paths from the
  node graph and re-bake whenever the source GLB is re-exported.

## 4. Keep the angle convention consistent end to end

One effective signed angle must drive the joint quaternion *and* index the passive table:

- Map axis names to the **positive** axis: `"z" → Vector3.BACK`, `"y" → Vector3.UP`,
  `"x" → Vector3.RIGHT`. `Vector3.FORWARD` is a direction constant equal to `-Z`, not the +z
  axis — using it mirrors the joint against every baked sample (pistons extend on the wrong
  side, rods detach from their brackets).
- Apply any sign correction to both the joint rotation and the table lookup (the rig folds
  `_tilt_sign` into `tilt_eff` once and uses it for both).
- Verify sign by asserting the joint quaternion's twist around its axis equals the keyed sample
  angle at both range extremes.

## 5. Mount at runtime

`attachment_rig.gd` shows the contract: instantiate the GLB, find the root node inside it,
reparent that node under the mount frame (`PIVOT_BUCKET_JOINT/AttachmentMount`) with an identity
transform, then free the now-empty instance wrapper. Two hygiene details:

- Set `owner = null` on the reparented subtree first to avoid orphan-owner warnings.
- Clear the previous attachment's children back to any foreign children it had absorbed (the
  bucket-soil visual mesh reparents under the tool) before freeing.
- Mount the tool GLB under the socket node with identity transform — the authored hierarchy
  already carries the correct socket offset.
- On `model_replacing`/`model_activated`, clear and re-mount so the attachment follows excavator
  model switches; emit `attachment_changed` so world systems reconfigure.

## 6. Modifier-key controls

`attachment_input_mapper.gd` implements the industry-style pattern: a held modifier borrows an
existing axis pair instead of adding new bindings.

- `Q` + bucket curl/dump (`I`/`K`, `J`/`L` pairs) → tilt; `O` + swing (`A`/`D`) → rotate.
- While the modifier is held, mask **only the borrowed axis pair** from the base
  `(swing, boom, arm, bucket)` command and leave the other three axes live.
- Keep the mapper as a probe-driven `RefCounted` so headless tests can exercise it without input
  devices; expose the mask as `(masked_axes, attachment_axes)` per physics frame.

## 7. Soil and world integration

Soil systems resolve through indirection so the active tool drives ground contact:

- `motion_presentation.get_soil_frame_node("bucket_link")` and `get_soil_contract()` return the
  attachment tool frame + its contract when mounted, falling back to the host bucket otherwise.
  Point every consumer (excavation world, soil effects, debug overlay) at these accessors.
- Author a per-attachment soil contract (`resources/attachments/*_soil_contract.json`) as a copy
  of a proven sibling contract; the rig patches `model_id` to the attachment id at load.
- On `attachment_changed`: clear bucket payload/local material and reconfigure soil effects
  against the new frame; terrain state is preserved.

## 8. Verify against ground truth

The GLB's own `AnimationPlayer` is the reference implementation — use it as the oracle:

- Instantiate the GLB, `play()` the drive clip, `seek()` to sparse angles, and compare the baked
  table's quaternions/positions/weight vectors against live playback. This catches bad path
  resolution, wrong sign conventions, and mis-sliced weights in one shot.
- In the headless test, assert **counts and direction**, not just motion: passive-node count
  (unresolved names fail silently), twist sign at ±extremes, which piston extends on +tilt, and
  rigid-link invariants (rod-end ↔ bracket-pin distance stays constant across the range).
- Assert morph weights reach expected targets at sampled angles (e.g. `TILT_M45 = 1.0` at +45°).
- Live check: mount via the UI selector, drive both axes with the modifier keys, and confirm
  joint/passive transforms through node inspection — screenshots alone cannot show that a rod
  stayed pinned.
- Pin every artifact with `sha256` in the catalog (glb, rig JSON, soil contract) and update all
  pins whenever any artifact is regenerated — a stale pin fails activation.
