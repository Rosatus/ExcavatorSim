# Implement — gamepad support for assist menu, attachments and local axes

## What changed

### Pad layer (new shared mechanism)

`attachment_input_mapper.gd`
- `PAD_LAYER_ACTIONS`: `pad_layer_dpad_up/down/left/right` → D-pad buttons.
- `LOCAL_PAD_LAYERS` (keyed by manifest `axis_id`): `boom_swing` → D-pad Left +
  right-stick X; `boom_fold` → D-pad Up + right-stick Y.
- Specs may carry `pad_modifier_action` + `pad_negative_action`/`pad_positive_action`
  (catalog `controls.tilt`/`rotate` got them — XTR13 on D-pad Down: stick X =
  rotate, stick Y = tilt). Pad pairs reuse existing operator actions, so no new
  axis events were needed.
- `mask_operator_axes` now suppresses keyboard-masked axes AND pad-masked axes
  (derived via `ACTION_AXIS_INDEX`). `read_local_axis(axis_id, neg, pos)` reads
  the pad pair while the modifier is held. Probe kind `"pad"` added for tests.
- `configure_local_axes(axis_ids)` registers only the active model's axes —
  models without local axes never mask.

### Plumbing

- `motion_client.gd`: registers the four `pad_layer_dpad_*` actions
  (`_ensure_input_actions`), `configure_local_axis_layers()` forwarder,
  `get_local_axis_input(axis_id, …)` now routes through the mapper.
- `product_session.gd`: `get_attachment_input_axes`/`get_local_axis_input` return
  neutral while `_chassis.input_axes_suspended()` (assist picker or slope
  preview).
- `motion_presentation.gd`: passes `axis_id` through, registers local pad
  layers after `_load_local_axis_contract`, clears on model teardown.
- `tracked_chassis_controller.gd`: `operator_assist` gains `JOY_BUTTON_Y`;
  `_navigate_assist_menu` merges D-pad just_pressed into the nav axis;
  `input_axes_suspended()` added.
- `camera_rig.gd`: preset actions dropped joypad bindings; new
  `camera_cycle_view` on `JOY_BUTTON_BACK` (View) cycles
  operator→chase→work_tool→inspection→cab; `cycle_mode()`; stale joy bindings
  are stripped at ensure-time.
- `operator_ui.gd`: `_ensure_ui_pad_bindings()` adds A→`ui_accept`,
  B→`ui_cancel` (engine defaults ship keyboard-only); `_menu_navigation_direction`
  handles left-stick Y with a latch; stick deflections consumed so engine ui_*
  actions can't double-navigate; assist rows are FOCUS_NONE; assist hint and
  control hint are prompt-aware.
- `attachment_catalog.json` XTR13 controls gained `pad_*` fields.
- `operator_ui_strings.gd`/`control_input_hud.gd`: guide, hints and footer
  rewritten for the new layout.
- `control_input_hud.gd` layout split by prompt mode (2026-09-25 HUD rework,
  revised after first iteration): keyboard keeps the classic key-tile
  crosses (WASD/IJKL keycaps + captions); gamepad switches to drawn
  `_PadWidget`s — a plus-silhouette D-pad with pressed-arm fill and layer
  captions, and octagonal-gate stick widgets whose nub tilts with live
  `Input.get_axis` while direction petals light on press. Captions live
  around the widget edges; per-mode registries (`_kb_reg`/`_pad_reg`) feed
  `_tiles`/`_keys`/`_captions`, and zero-size anchor Controls at petal
  positions keep the `is_action_highlighted_for_test`/`_tiles` hooks.
  `_sync_layer_captions` + `PAD_LAYER_OVERRIDES` relabel borrowed
  right-stick arms while a D-pad modifier is held.

### Final gamepad map

- Sticks: swing/arm (L), boom/bucket (R) — unchanged.
- Tracked: LT/LB, RT/RB per-track — unchanged.
- Wheeled (SY155W): **RT drives, LT reverses, LB/RB steer, A drifts**
  (`wheeled_vehicle_controller.gd` INPUT_ACTIONS — was LT/LB drive, RT/RB
  steer; swapped to a trigger-driving layout per user request).
- Y: assist picker (T also works). Menu open: D-pad/left-stick select, A
  confirm, B/Y close. Slope preview: A confirm, B exit, left stick adjusts.
- View button: cycle camera presets; R3 still resets.
- Hold D-pad Down + right stick: tiltrotator (X rotate, Y tilt).
- Hold D-pad Left + right stick X: boom swing (SY80U).
- Hold D-pad Up + right stick Y: boom fold (SY155W).
- D-pad Right: reserved.
- Pause menu: stick/D-pad nav, A activate, B back, LB/RB pages, Start/Esc toggle.

## Verification (headless, godot 4.7.2 custom/voxel 1.7 at C:\apps\godot_voxel)

- `pad_layer_input_test.gd` (new, added to matrix): registrations, mapper pad
  redirection + masking, local-axis per-model layer, assist D-pad nav edges.
- Updated `camera_workflow_test.gd` (View cycle, no D-pad presets) — PASS.
- Extended `attachment_switch_test.gd::_check_input_mask` (pad path) — PASS.
- PASS: assist_menu, equipment_command_mapper, control_input_hud,
  sy80u_switch_smoke, sy155w_session, model_switch, jolt_articulated_equipment,
  tracked_chassis_locomotion, slope_preview_v2, bucket_level_assist,
  machine_feedback, excavation_gameplay, gb12_soil, bucket_solid_support,
  authority_shadow, sensor_telemetry.
- `operator_ui_test.gd`: still fails only at the pre-existing "real excavation
  world did not publish soil timing" (documented exclusion in matrix).
- `slope_grade_assist_test.gd`: FAILS in workspace — **pre-existing**, not this
  task. Reproduced identically on clean HEAD + only the uncommitted
  bucket-solid-support files (attachment_rig/bucket_soil_tool/
  jolt_chassis_track_runtime/kinematic_articulation_state/bucket_solid_contact_solver);
  SY205 drive progress 0.229 m on both. Flag to the bucket-solid task owner.
- `sy155w_wheeled_test.gd`: FAILS in workspace ("wheel stations support load",
  "right turn") — drives `set_wheeled_commands` directly, never reads input
  bindings, so the remap cannot be the cause; same pre-existing physics-side
  attribution. Not in the maintained matrix. Baseline run hangs on a
  `locomotion_mode` snapshot key missing at HEAD — the test itself depends on
  the in-flight workspace state, further confirming the attribution.

## Pending human acceptance

Real-gamepad feel: modifier reachability, stick sign direction on tilt/fold/
swing (signs chosen for "stick direction ≈ motion direction"; see catalog +
LOCAL_PAD_LAYERS to flip), View cycle order, menu nav latch feel.
