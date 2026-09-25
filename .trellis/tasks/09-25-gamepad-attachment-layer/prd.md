# Gamepad support for assist menu, attachments and local axes

User request: after assist modes, two-piece boom (双截臂), offset boom swing (偏摆臂) and tiltrotator (倾斜旋转铲斗) were added, they lack gamepad support. Plan and implement pad bindings on top of the existing gamepad scheme.

## Confirmed decisions

- Camera presets move off D-pad: JOY_BUTTON_BACK (Xbox View) cycles Operator → Chase → WorkTool → Inspection → Cab. D-pad is freed for a hold-modifier layer. Keyboard 1–5 and R3 reset unchanged.
- Assist menu toggle = JOY_BUTTON_Y (T key kept). Menus: A=confirm, B=cancel, D-pad AND left stick navigate.

## Binding map

- `ui_accept` += JOY_BUTTON_A, `ui_cancel` += JOY_BUTTON_B (added once at UI init; engine defaults had none).
- `operator_assist` += JOY_BUTTON_Y. Assist picker: left stick/W-S axis + D-pad up/down navigate (edge), A confirms, B/Y/Esc close. Slope preview: A confirms, B exits.
- Pad layer (hold-modifier, right stick redirected while held):
  - D-pad Down held → tiltrotator: right stick X = rotate, Y = tilt (XTR13; catalog `pad_*` fields)
  - D-pad Left held → boom swing on right stick X (SY80U `boom_swing` local axis)
  - D-pad Up held → boom fold on right stick Y (SY155W `boom_fold` local axis)
  - D-pad Right = reserved.
- While a pad modifier is held, its stick source axis is masked from base equipment axes (existing `mask_operator_axes` path extended).
- Attachment/local axes suspend while assist menu open or slope preview active (new chassis `input_axes_suspended()` gate in ProductSession).

## Scope

- `attachment_input_mapper.gd`: pad-layer specs, per-model local-axis registration, pad masking, probe kind "pad".
- `attachment_catalog.json`: XTR13 controls gain `pad_*` fields (catalog has no hash pin).
- `motion_client.gd`: register `pad_layer_dpad_*` actions (D-pad buttons), `get_local_axis_input(axis_id, neg, pos)`, `configure_local_axis_layers`.
- `product_session.gd` / `motion_presentation.gd`: signature + gating + local-layer registration.
- `tracked_chassis_controller.gd`: TOGGLE_ACTIONS gains joypad events (Y); assist nav merges D-pad; `input_axes_suspended()`.
- `camera_rig.gd`: D-pad presets → View-button cycle.
- `operator_ui.gd` / `operator_ui_strings.gd` / `control_input_hud.gd`: A/B ui_accept/cancel wiring, left-stick menu nav with latch, prompt texts.

## Acceptance

- Automated: new `pad_layer_input_test.gd` (mapper pad paths, local-axis redirect+mask, assist D-pad nav, action registrations); updated `camera_workflow_test.gd` (View cycle) and `attachment_switch_test.gd` (pad mask). Existing keyboard paths and matrix suites unchanged.
- Human (pending): real gamepad feel — modifier reachability, stick direction signs, menu nav, camera cycle order.

## Non-goals

No remapping UI, no keyboard changes, no manifest edits (local pad map lives in a code table keyed by axis_id), no lifecycle/pause bindings beyond assist/menu.
