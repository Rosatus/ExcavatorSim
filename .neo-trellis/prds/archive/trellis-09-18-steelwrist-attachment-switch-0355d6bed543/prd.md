# Steelwrist attachment switching support

## Goal

Add an attachment (属具) selector below the existing machine/model selector in the
game menu. Support the Steelwrist XTR13 tiltrotator + GB12/S50 bucket assets from
`E:\projects\blender\Excavator\Attachments\Steelwrist_Animated`, with modifier-key
attachment controls (`Q+IJKL`, `O+WASD` style combos).

## Requirements

- Attachment catalog (`resources/models/attachment_catalog.json`) with entries:
  `standard_bucket` (native bucket, default), `xtr13_gb12` (rotator + bucket
  socketed), `xtr13_bare` (rotator only). GLB/contract paths pinned by sha256.
- Mounting contract (from `装配与动画说明.md`): `XTR13_ROOT` mounts under the
  model's `bucket_link` frame node at identity; `GB12_ROOT` parents to
  `S50_TOOL_SOCKET` at identity. Y-up GLB export, no extra 90° fix.
- Runtime `AttachmentRig` node: instantiates GLBs under the live `bucket_link`
  frame, drives `TILT_Y` (local Z, ±45°) and `ROTATE_Z` (local Y, continuous),
  applies a baked tilt-rig table (cylinder pivots, pistons, hose morph weights)
  sampled from the GLB's `Tilt_45` clip so the passive mechanism follows.
- Controls (keyboard): while `Q` held, `J/L` steer tilt (right-stick lateral);
  while `O` held, `A/D` steer rotation (left-stick lateral). Only stolen pairs
  are suppressed from the base equipment axes; `I/K`, `W/S` keep working.
- Soil: GB12 gets a provisional mesh-derived contract authored in `GB12_ROOT`
  space (`frame: "bucket_link"`, `model_id` patched to the host model at
  runtime). Soil proxies/tool frame resolve through a new `get_soil_frame_node`
  indirection so cutting/contain/spill follow the real tool incl. tilt/rotate.
- `xtr13_bare` keeps the host model's soil contract at the joint (approximate;
  documented limitation — no cavity).
- Attachment switch is instant (no reset dialog): clears bucket payload/material
  via `attachment_changed` → `ExcavationWorld` reconfigure (terrain preserved).
- Physics authority: tilt/rotate are presentation-level DOFs; the Jolt rig keeps
  the native curl body. Documented limitation for v1.

## Acceptance Criteria

- [ ] Menu shows 属具切换 under 机型切换; selecting an attachment activates it.
- [ ] XTR13+GB12 appears mounted at the stick end; native bucket hidden.
- [ ] `Q+J/L` tilts ±45° with cylinders/hoses following; `O+A/D` rotates 360°.
- [ ] Base axes unaffected when no modifier held; stolen pairs only suppressed.
- [ ] GB12 digs/fills/dumps via its own contract incl. tilted poses.
- [ ] Switching back to standard bucket restores native visuals + contract.
- [ ] Model switch re-mounts the active attachment on the new model.
- [ ] Headless test covers catalog pins, mount/socket identity, drive ranges,
      contract validity, mask semantics, switch lifecycle.
- [ ] Human visual review in running client.

## Progress

- Current milestone: implementation.
- Decisions: modular GLB pair (not the combined assembly); presentation-level
  tilt/rotate; instant switch clearing payload only; masked-pair input scheme.
- Blockers: none.
- Next: copy assets, bake tilt rig, author catalog+contract, implement rig/UI.
