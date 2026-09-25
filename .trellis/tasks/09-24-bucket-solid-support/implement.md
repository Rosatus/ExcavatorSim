# Implementation and evidence

## Delivered
- Added `bucket_solid_contact_solver.gd`: active bucket physical plates/teeth, iterative RID-filtered overlap plus translation/rotation sweep, chassis-motion-aware world sweep, unilateral implicit spring/damper, effective mass/inertia, direct-state COM and dynamic-object opposite reaction.
- Jolt runtime now uses fresh same-tick solid contacts, with no 45-tick limit or next-tick stale support replay. Voxel terrain is excluded; voxel cutting remains independent. Native and mounted tool collision contracts are selected through MotionPresentation and AttachmentRig. Attachment tilt/rotate candidate motion uses the same accepted contact fraction.
- Added gravity-on integration test covering hard ground, raised ordinary object, pure rotation, side wall, thin obstacle, shallow overlap, voxel exclusion, dynamic obstacle, neutral hold, release, reset/bypass and active attachment/no-tool lifecycle.
- Updated stale voxel integration assertion to wait boundedly for asynchronous positive mass commit. Updated client boundary contract.

## Checks
PASS: `bucket_solid_support_test.gd` final — gravity-on native hard surface lift 0.752m, max compression 0.0255m, 233 contact frames; raised object lift 0.912m, max compression 0.0234m, 279 contact frames; 180-frame neutral holds; retraction returns to track support. Boundary pass covers rotation, wall, thin sweep, chassis sweep, voxel exclusion, offset automatic COM and dynamic reaction.
PASS: `jolt_articulated_equipment_test.gd`; `bucket_passthrough_mode_test.gd` (including active GB12 collision handoff and no-tool clear); `attachment_switch_test.gd`; `authority_shadow_test.gd`; `bucket_soil_tool_test.gd`; `voxel_excavation_world_test.gd` after bounded async commit wait.
Godot headless parser/check-only passed for changed runtime and solver. `git diff --check` passed (CRLF normalization warnings only).

## Limitations
The response is compliant game physics with tuned force/torque budgets, not calibrated hydraulic hardware. Subjective visual/feel review remains pending human review. Training map starts in pass-through; turn off “铲斗穿透地面” before exercising support.
