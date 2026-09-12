# Game menu and driving HUD

## Current product contract (2026-09-09)

`MotionOperatorUI` owns the product entry point: deferred local start after model initialization, a hidden menu on entry and no blocking onboarding. Low-level `ProductSession.request_reset()` still returns stopped; confirmed product UI reset resumes gameplay. F6/F7 have no product UI handler or buttons.

Esc / gamepad Start toggles the menu. The UI processes while SceneTree is paused, clears camera drag and blocks camera input, clears MotionClient focus before pausing, and requests local lifecycle pause. Closing restores only lifecycle/tree pause changes owned by the menu. Existing neutral arming remains authoritative. B cancels a confirmation before closing the menu. Destructive model/reset actions require confirmation, with cancel focused initially.

Navigation: Up/Down or D-pad traverses visible enabled controls; Tab/Shift+Tab follows the same order; A/Enter activates; B returns; LB/RB changes pages. Scroll containers follow focused controls. Keyboard/mouse and meaningful controller input switch prompts; analog noise does not.

`game_menu_layout.gd` owns composition and `game_ui_theme.gd` owns the charcoal, warm-white and amber visual tokens. Settings, controls and engineering tools are separate scrollable pages. Driving HUD is mouse-transparent; the lower-right HUD uses two side-by-side directional crosses with four track keys above. All twelve actions have independent highlights and keyboard/gamepad labels. CAN recording, Gateway restart and TCP connection indicator remain in the upper-left HardwareDock during gameplay and menus; the menu reserves space beside it. Tests use `get_control_for_test(id)` semantic lookups because layout reparents controls after binding.

CAN supervision runs while paused: heartbeat, shutdown/start deadlines and ICT replies continue; physical telemetry samples are not emitted while simulation is paused. The menu refreshes hardware status at 5 Hz.

## Verification

Focused contracts: `operator_ui_test.gd`, `control_input_hud_test.gd`, `camera_workflow_test.gd`, `ict_status_indicator_test.gd`, `gateway_restart_ui_test.gd`. UI bounds cover 1280x720, 1920x1080 and 2560x1080. Smaller phone-sized viewports are outside this desktop product target.

Manual acceptance: restart the main scene, drive immediately, open/close with Esc and controller Start; navigate all pages and reset dialog using only gamepad; reset and drive again; inspect HUD readability over bright and dark terrain. Aesthetic and control-feel acceptance remains human-owned per validation-budget.md.

## Atmosphere
`menu_atmosphere.gdshader` provides low-contrast contours and slow warm/cool gradients. Its `ui_time` is advanced by the visible menu, independently of paused simulation. No background animation runs during driving. Entry/page tweens use pause-processing mode; rapid page changes restore previous page opacity before replacing the tween. HUD surfaces remain static to preserve readable input feedback. Headless UI tests do not prove GPU visual quality.

Latest UI refinement: the persistent machine/operation/bucket DrivingHUD is removed. Those readouts live in Advanced. HardwareDock and lower-right control HUD remain persistent during driving.

## Performance recording (2026-09-10)

`PerformanceCapture` is an opt-in root observer. Advanced tools and F12 start/stop
a bounded capture; F10 marks a hitch without changing gameplay. The small recording
badge is visible only while recording and ignores mouse input. Existing menu pause,
controller focus and destructive confirmation ownership remain unchanged. Recording
enables lightweight clocks, without additional diagnostic SDF reads. It preserves
the full-diagnostics setting and locks its checkbox during capture. Focus-transition
signals exclude the affected interval, including changes between process callbacks.
Save errors retain the buffer and expose retry rather than silently
starting over. Normal scene exit saves; abrupt termination cannot guarantee a trace.

No per-frame world snapshots, JSON serialization or file writes: late `_process`
captures numeric rows, a signal observes all voxel physics steps, and context polling
is capped at four Hz. Diagnostics remain observational and cannot become authority
time. Main-viewport GPU/CPU reports may lag; wall frame interval includes waits.
See [capture schema and usage](../../../docs/performance-capture.md).

Focused checks: `performance_capture_test.gd`, recording assertions in
`operator_ui_test.gd`, and `tools/tests/test_analyze_performance_capture.py`.
