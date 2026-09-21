# Reusable Jolt wheeled motion and wheel animation

## Goal
Add reusable, physically plausible wheeled-machine locomotion and wheel animation, including the existing SY155W in the authoritative product scene.

## Requirements / acceptance
- One Jolt rigid-body pose authority; per-wheel suspension and combined tire traction, braking, reversing, Ackermann steering, speed-sensitive steering and airborne wheel spin.
- Configuration and visual adapters reusable for future imported wheeled machines; preserve original GLB bytes/pivot origins/authority work-equipment semantics.
- Wheel roll/steer/suspension follow physical wheel state; lifecycle resets and focus/menu gating prevent stale motion.
- Existing tracked machines remain on their current solver and controls.
- Runnable demo, integration instructions, focused physics and product-integration tests. Manufacturer parameter calibration and subjective operator acceptance remain distinct from automated evidence.

## Progress
- Generic force-only solver, controller, wheel animator, standalone demo implemented.
- Jolt 60/120 Hz tests pass: support/sag, acceleration, braking, reverse, right turn, Ackermann, low-friction circle, slope support, no air propulsion, visual angle/reset, input rearming.
- Forward+ demo PNG inspected; no material/mesh disappearance. GUI launch emitted unrelated optional CAN gateway warning.
- Current milestone: configure and integrate existing SY155W with main runtime/presentation/controls.
- Skill human gate empty for wheel pivot mapping: source build_sy155w.py lines 130-164 and 356-362 explicitly construct wheel pivots at source (+/-1.3,+/-0.972,.535), radius .535, rolling axis +Y, steer +Z, and tie-bar endpoints. Imported Godot nodes independently measured (wheels-out.log): front -Z, roll local +Z -> chassis +X, steer local +Y, rest origin +/-0.972,.535,+/-1.3. Original source and runtime GLB will remain unchanged. Physics tuning is provisional simulation configuration.
- Next: profile loader and source-preserving imported-pivot adapter; select wheel solver in existing Jolt runtime; update controls; run SY155W and tracked regression tests; capture actual imported model.

## Delivered / validation
- SY155W selected via independent `wheeled_machine_profiles.json`; shared Jolt runtime owns wheel support/traction and permanent tire/hull collisions, reuses accepted terrain readiness. Imported wheel animator validates SHA/rest transforms and follows physics snapshots. GLB unchanged.
- Main-scene input, wheel animation, model switching, attachments and fold/hydraulic lifecycle pass extended sy155w_session_test.
- Tests passed: wheeled_locomotion_test at 60/120 Hz; sy155w_wheeled_test; sy155w_session_test; sy155w_import_test (81 source oracle poses); control_input_hud_test. git diff --check passed.
- Forward+ screenshots inspected: demo.png and sy155w.png. Actual SY155W wheel mode, model visibility, steering and updated R/F/Y/H HUD confirmed. Subjective handling/operator acceptance remains user-owned and has not been claimed passed.
- Existing jolt_chassis_track_test fails three SY205 assertions: reset clearance .0854 vs .0600 and two reverse zero-crossing expectations. Restoring pre-change tracked runtime (with only inert compile stubs for new wheel ports) reproduced all three exactly; baseline logs retained. No unrelated tracked physics fix attempted.
- Import/runtime unrelated warnings: duplicate terrain texture UIDs, Terrain3D interpolation deprecation, optional CAN gateway no heartbeat; editor shutdown resource warning. Product wheel tests themselves have no script errors.
- docs/wheeled-machines.md documents controls, generic and product integration, provenance and limitations. Physics is provisional real-time suspension/tire tuning, not manufacturer-calibrated. Fixed axle housings/tie bar are not a full suspension linkage simulation. Human visual/handling acceptance remains pending; task not archived as fully accepted.
- Implementation committed in batches: 5e7d6b4 (reusable module), 960dad0 (SY155W integration). Next: user drive-test SY155W and supply handling feedback if tuning is wanted. No further automated gate outstanding for wheel behavior.

User steering update: wheel keyboard is now G forward / V left / B reverse / N right, Space brake. Independent wheel InputMap actions preserve gamepad LT/LB and RT/RB and tracked R/F/Y/H. Product/demo, HUD highlights/help and docs updated. Existing control_input_hud_test passed; diff whitespace check passed.
