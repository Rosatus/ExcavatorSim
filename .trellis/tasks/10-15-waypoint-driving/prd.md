# Automatic waypoint driving

## Scope
Implement Godot-local fixed-tick waypoint navigation through the existing Jolt command interfaces. First tracked SY135, then wheeled SY155W. No obstacle planning, reverse manoeuvres, Python dependency or pose writes. Preserve pre-existing godot_ai addon edits.

## Acceptance
Both models drive a square route on the training map and stop near the starting point. Tracked vehicles stop/align at corners. Wheels use physically feasible rounded corners with explicitly measured route error. Exercise production controller arbitration, not only a synthetic kinematic model. Provide a usable training-square action plus public waypoint API and visible progress/cancel/resume. Manual input cancels; menus/focus/pause latch pause; reset/model/map teardown cancels. Invalid/stale state, sustained unsupported motion and no progress stop with a reason.

## Milestones
1. Implement tracked controller and focused SY135 training-square integration evidence.
2. Implement wheel path tracking and SY155W training-square evidence, retaining tracked results.
3. Verify lifecycle/UI, review cumulative change, document operation and limits.

## Added user scope
Diagnose and fix equal-input tracked straight-travel drift (reported on SY135). Fix the common physical/control cause, not per-model bias constants; verify other representative tracks without suppressing legitimate slope/slip effects.

2026-10-15 user update: drift confirmed absent; stop investigating it. Refine tracked pivot so it fully aligns with the next travel direction before translating. Keep shared model-independent guidance. Wheel behavior unchanged.

## Progress
Tracked waypoint driver, production controller arbitration, T-menu actions and HUD implemented. Real main-scene SY135 square passed: final error 0.2542 m, max segment cross-track 0.2569 m, 92.93 simulated seconds. Evidence artifacts/navigation-sy135.log. Wheeled controller still pending. MCP HTTP connection verified ExcavatorSim/Godot 4.7.2 ready; tool discovery absent but local authenticated endpoint works. Existing addon changes untouched.
Wheel controller and product integration now complete. Final automated square evidence: artifacts/navigation-sy135-final.log (0.2542 m final, 0.1977 m perimeter), artifacts/navigation-sy155w-final.log (0.2629 m final, 2.2400 m perimeter). Both include all four midpoint visits and settled arrival. Lifecycle guards pass, including string epoch identity, stale/unsupported/blocked-turn exits, real takeover/menu/focus/neutral rearm/reset for both models. Assist menu and gamepad-layer regressions pass (artifacts/*-navigation.log). Added cyan world route and localized HUD/menu state. No protocol/backend/physics solver changes.

Rendered MCP acceptance completed for both models in the actual main scene. SY135 reported completed_points=5, position=(-6.005753,0.067627,-7.745901), speed=0.000247 m/s. SY155W reported completed_points=5, position=(-6.0017,0.000062,-7.730868), speed=0.000048 m/s. Route node visible. User's configured normal bucket mode was retained. One MCP eval compile failure was caused by tool-snippet space indentation; stopped/relaunched and retried with tabs successfully; no product parse failure.

Straight-drive investigation: common flat fixture passes SY135/SY80U/SY205 at yaw 0 and 0.7, ~30 m travel, max lateral error 0.000102 m (artifacts/straight-models.log). Training main scene normal/passthrough + voxel seam and rendered Input.action_press(left/right) both remain straight. Construction flat spawn likewise straight; urban encounters equipment collision with nonzero yaw reaction wrench. No evidence-based root cause for user's unspecified no-contact drift yet, so NO model bias or physics change introduced. Diagnostic runner supports --training --normal --construction/--urban. Need user's exact map/location/equipment pose/prior manoeuvre to reproduce. Scope is not fully complete: keep task active for that issue and human handling/readability review.

Latest completed refinement: tracked pivot uses fixed segment bearing instead of lookahead direction, preserves 0.65 rad driving-entry threshold, brakes residual translation, requires <=1° heading error and <=0.035 rad/s yaw rate with 0.2 s dwell before proceeding. Added offset-corner/momentum/dwell regression plus independent actual departure-heading assertions in the real square fixture. Focused lifecycle test PASS; SY135 square PASS: five alignments, maximum departure error 0.6857°, final error 0.2550 m, perimeter error 0.2494 m, duration 100.13 s (artifacts/navigation_lifecycle_test-alignment.log, artifacts/navigation_square_test-alignment.log). Wheel branch unchanged; prior evidence remains valid. User closed drift investigation; no further reproduction requested.

Latest precision follow-up: user requested physical arrival at vertices before pivot. Implemented tracked distance-proportional crawl, 3 cm brake trigger, 0.025 m/s stable stop, 5 cm position guard after braking and before departure from pivot. Outside tolerance fails visibly instead of advancing/repositioning by transform. Wheel control unchanged. SY135 production square PASS (artifacts/navigation-precision.log): final 0.022006 m, perimeter 0.022282 m, max departure edge offset 0.022638 m, max departure heading 0.685713°, all five alignments, 107.17 s. Lifecycle/precision guards PASS (artifacts/navigation-precision-lifecycle.log), including 25 cm early-arrival rejection, crawl, settling and post-pivot drift rejection.

Next: user handling/readability review of the refined tracked turn; no remaining authorized implementation known. See docs/automatic-driving.md for operation/API/acceptance and current limits. Game remained stopped during this headless refinement. Existing godot_ai edits preserved.

## Validation
Agent automated: parse/import, focused navigation logic and production training-square scenarios for both models; lifecycle cancellation/rearm regressions. User has requested MCP-connected square acceptance; inspect available connection and use objective runtime evidence if possible.
Human manual: final handling/readability judgment remains separate from automated geometric acceptance.

## Initial findings
Godot MCP tool discovery exposes no tools in this chat despite user reporting connection. Project config points at godot-ai attach ports 8000/9500; inspect locally without changing plugin. TrackedChassisController owns input arbitration; Jolt snapshots provide chassis heading/pose/velocity. Existing wheel solver is front Ackermann, requiring curvature-limited motion.

## Responsiveness follow-up (2026-10-15)
User found precise tracking sluggish. Increased shared tracked cruise demand from 1.0 to 1.6 m/s and pivot yaw limit from 0.55 to 0.8 rad/s, with stronger large-angle alignment feedback. Continuous outer approach ramp shortens premature crawling; final 25 cm demand and all arrival/alignment/settling gates retained. No wheel or physical solver changes. Current SY135 square PASS: 77.0667 s (28.1% less than 107.1667 s), final error 0.019245 m, perimeter 0.018951 m, departure offset 0.019255 m, heading 0.854181 degrees, five alignments. Phase times: aligning 28.683 s, driving 46.017 s, braking 2.25 s. Added 95 s tracked completion budget and phase reporting to existing acceptance fixture; all previous precision checks retained. Lifecycle PASS. Evidence: artifacts/navigation-responsive.log and artifacts/navigation-responsive-lifecycle.log. Latest changes verified headlessly; human handling judgment pending. Next: user evaluates faster tracked driving in training map.
