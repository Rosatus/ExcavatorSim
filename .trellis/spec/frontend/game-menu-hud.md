# Game menu and driving HUD

## Current product contract (2026-09-09)

`MotionOperatorUI` owns the product entry point: deferred local start after model initialization, a hidden menu on entry and no blocking onboarding. Low-level `ProductSession.request_reset()` still returns stopped; confirmed product UI reset resumes gameplay. F6/F7 have no product UI handler or buttons.

Esc / gamepad Start toggles the menu. The UI processes while SceneTree is paused, clears camera drag and blocks camera input, clears MotionClient focus before pausing, and requests local lifecycle pause. Closing restores only lifecycle/tree pause changes owned by the menu. Existing neutral arming remains authoritative. B cancels a confirmation before closing the menu. Destructive model/reset actions require confirmation, with cancel focused initially.

Navigation: Up/Down, D-pad, or the left stick (latched per deflection so held input cannot skip entries; stick events are consumed so the engine ui_* actions never double-navigate) traverse the curated visible enabled controls; Tab/Shift+Tab follows the same order; A/Enter activates (JOY_BUTTON_A is bound onto `ui_accept` at UI init — the engine default ships keyboard-only); B returns (bound onto `ui_cancel` and handled explicitly for menu back); LB/RB changes pages. Scroll containers follow focused controls. Keyboard/mouse and meaningful controller input switch prompts; analog noise does not.

The main scene stores only the OperatorUI owner and ControlInputHUD. `operator_menu_controls.tscn` supplies runtime-only controls instantiated before onready binding; do not instance the pre-composition menu layout into main.tscn, where it would expose obsolete panels in the editor.

`game_menu_layout.gd` owns composition and `game_ui_theme.gd` owns the visual tokens. Three switchable UI themes (`debug` default, `industrial`, `sany`) are selected from the Settings page and persisted in `user://operator_ui.cfg`; switching rebuilds the composed UI in place because the variants differ structurally. `industrial` and `sany` are *console variants* (`GameSkin.is_console_variant`): identical console layout and chrome, differing only in palette accent — amber `efb64d` vs SANY brand red `e82e24` (`accent_for`/`on_accent_for` pick accent and on-accent lettering; the red SANY plate takes paper-white lettering where amber takes dark ink). In all themes the open menu hides the HardwareDock and centers the panel on the viewport; under `debug` the dock stays in the upper-left while driving. Under console variants the dock never exists: a slim PC001 connection lamp sits in the menu header, CAN recording/Gateway restart live in the Advanced page (focusable), and driving shows only the lower-right HUD plus the menu button. Settings, controls, engineering tools and video settings are separate scrollable pages — the 视频设置 tab hosts the window-mode selector (windowed / borderless fullscreen / exclusive fullscreen → `DisplayServer.window_set_mode`) and the fps-cap selector (60/120/uncapped → `Engine.max_fps`), both persisted under `[video]` in `operator_ui.cfg` and applied once at startup via `_apply_saved_video_settings`; the saved pair records the *requested* state so a refused window change cannot rewrite user intent. `physics/common/physics_interpolation` is enabled project-wide so >60 fps caps render smooth physics-driven motion; `CameraRig` opts out (`PHYSICS_INTERPOLATION_MODE_OFF`) since it re-places the camera every render frame, and `MotionPresentation._activate_model` calls `reset_physics_interpolation` on the new asset root to prevent a teleport smear. Driving HUD is mouse-transparent; the lower-right HUD is prompt-aware with two separate subtrees. Keyboard mode keeps the classic key-tile crosses (WASD, IJKL) with a key letter plus a small function caption per tile, and a 2x2 travel keycap grid (R/Y over F/H). Gamepad mode replaces the crosses with drawn widgets (`_PadWidget`): the D-pad is a plus silhouette with pressed-arm accent fill and per-direction layer captions (up fold, down tiltrotator, left boom swing, right reserved); each analog stick is an octagonal gate with four direction petals and a nub that tilts with live `Input.get_axis` values, surrounded by function captions. Travel keycaps are shared (pad mode shows LT/RT over LB/RB, wheeled RT/LT drive + LB/RB steer). While a D-pad modifier is held the borrowed right-stick captions relabel to the layer's functions. Per-mode `_kb_reg`/`_pad_reg` registries feed `_tiles`/`_keys`/`_captions`; pad anchors are zero-size Controls carrying highlight meta, so all twelve base actions plus four pad-layer actions keep highlight and test hooks in both modes. Tests use `get_control_for_test(id)` semantic lookups because layout reparents controls after binding.

Console variants use a near-fullscreen machine console (panel up to 1360x820): the visible plate is a chamfered octagon drawn by a `MenuRoot` backdrop (`_Backdrop._draw`: plate fill, shadow, double-line border, breathing accent corner brackets, viewport corner reticles — `_Backdrop.accent` is set per variant); `StatusPanel` itself uses a transparent `frame_pad` stylebox for content inset. Inside: full-width header (title + lamp chip + `SYS-OPS // REV` micro text + scrolling hazard-stripe divider tinted via `stripe_color`), a left navigation rail (accent Resume CTA, numbered page buttons driving a `tabs_visible = false` TabContainer, "LB/RB 翻页" hint), a content column with per-page title header, and a footer row (Completion status + key hints). Rail buttons stay in the controller focus cycle (`_menu["nav"]`); `tab_changed` syncs their pressed state, page title and focus. The debug menu keeps the compact centered dialog (780x700) with visible tab bar.

CAN supervision runs while paused: heartbeat, shutdown/start deadlines and ICT replies continue; physical telemetry samples are not emitted while simulation is paused. The menu refreshes hardware status at 5 Hz.

## Verification

Focused contracts: `operator_ui_test.gd`, `control_input_hud_test.gd`, `camera_workflow_test.gd`, `ict_status_indicator_test.gd`, `gateway_restart_ui_test.gd`. UI bounds cover 1280x720, 1920x1080 and 2560x1080. Smaller phone-sized viewports are outside this desktop product target.

Manual acceptance: restart the main scene, drive immediately, open/close with Esc and controller Start; navigate all pages and reset dialog using only gamepad; reset and drive again; inspect HUD readability over bright and dark terrain. Aesthetic and control-feel acceptance remains human-owned per validation-budget.md.

## Atmosphere
`menu_atmosphere.gdshader` provides low-contrast contours and slow warm/cool gradients; `fx_strength` (0 debug, 1 console variants) blends in vignette, scanline and warm-glow accents. Its `ui_time` is advanced by the visible menu, independently of paused simulation. No background animation runs during driving. Entry/page tweens use pause-processing mode; rapid page changes restore previous page opacity before replacing the tween. HUD surfaces remain static to preserve readable input feedback. Headless UI tests do not prove GPU visual quality.

Driving-time assist overlays follow the same variant split. The T-key/gamepad-Y assist picker (`AssistMenu`; left stick, W/S or D-pad navigate, A/Enter activate, Y/T and B/Esc close; while it is open `input_axes_suspended()` parks attachment and local-axis reads so menu presses cannot jog a mounted layer) under console variants gains a hazard-stripe top edge, accent tick + `ASSIST` micro label, nav-rail-styled rows (selection = accent left bar via `set_pressed_no_signal`), muted hint and a deferred scale-pop on open (`_pop_assist_menu`); under debug it stays the plain centered dialog with `▶` marker rows. `SlopeSideView` under console variants redraws its frame as a rounded instrument plate (`set_theme_variant` → `_rounded_poly` slab with double rim, header band with accent title/tick, faint metre grid); its semantic guidance colors (terrain, target, cut fill, tooth) are theme-invariant, and the `d` distance dimension stays strictly horizontal (constant pixel height with vertical end ticks) regardless of the smoothed-relax knee height. `_style_assist_menu` rebuilds rows on theme switch since rows carry variant-specific stylebox overrides.

Console-variant motion/chrome (all menu-scoped, none during driving): `hazard_stripes.gdshader` draws a seamless scrolling safety-stripe divider under the menu header (FRAGCOORD-space, edge-faded, `stripe_color` per variant); `menu_sheen.gdshader` sweeps a slow highlight band across the panel (`tint` uniform per variant); the header PC001 lamp breathes via `modulate.a` in `_process`; the menu title/subtitle/section headings use letter-spaced `FontVariation` with accent tick marks; the menu button reads `≡ Esc / 菜单`. Menu open runs a power-on boot sequence (`_boot_menu_industrial`): root alpha flicker (0→1→0.45→1), an accent energy scanline sweeping down the plate (`_Backdrop.scan`), and staggered cascade-ins — rail items grow from the left edge, content from the right (`scale`+`modulate` tweens, pause-processed). Menu close snaps the panel content off instantly while the plate/backdrop fades out over ~0.12 s (`_close_tween` → `_hide_menu_root_if_collapsed`). Page switches under console variants fade+stretch-in the new page (`scale.x` from 0.9, left pivot). Under console variants the driving HUD gains a hazard-stripe top edge, accent title, divider, inset corner-bracket overlay (`Control._draw`, mouse-transparent), forward-skewed key plates, pressed-key accent fill and a scale-pop tween on activation; its geometry and action mapping are unchanged.

Latest UI refinement: the persistent machine/operation/bucket DrivingHUD is removed. Those readouts live in Advanced. The lower-right control HUD remains persistent during driving; the HardwareDock stays during driving only under the debug theme (console variants remove it entirely).

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

The optional performance overlay is owned by OperatorUI, persisted under
ui.performance_overlay and rebuilt independently of theme menus. It ignores mouse
input; recording badge occupies the row above it. A 40-bin ring holds FPS and
peak frame intervals, redrawn at 4 Hz. Off disables processing; PerformanceCapture
arbitrates viewport timing between recording and overlay, so stopping either
consumer cannot disable the other. Native Jolt integration is not included in
chassis/track script clocks; never label wall frame interval as GPU latency.

Assist side-view viewport (2026-09-18): latch a world-space swing-pivot anchor
on entry/mode change; clear it when hidden or empty. Project this same anchor
through the snapshot origin so the tooth-relative level origin cannot pan the
HUD. Keep a fixed 17 x 12 m view; terrain edits and joint motion never auto-fit
the camera. Actual vehicle translation remains visible. The machine symbol follows the live swing pin horizontally; its tread bottom
rests on interpolated terrain beneath the machine center in both assist modes.
The terrain sample interval includes the chassis. Its schematic height is
independent of the model-specific slew-pivot height; real equipment joints and
the tooth keep their measured positions. The silhouette uses a
centered capsule track, separate counterweight/cab outlines and real work-joint
links with a bucket outline. Reserve the header above the drawing.
Focused regression: `slope_preview_v2_test.gd` checks stationary pose under
origin/tooth/terrain changes, real travel and relatching. Human review: enable
level assist, extend/retract with tracks stopped, then travel and re-enter;
inspect the outline and tooth/target readability at 1280x720 and 1920x1080.


Performance overlay readability (2026-09-18): 360 x 372 px top-right panel.
Current FPS/mean frame interval lead; ten-second minimum bin-average FPS and
maximum single-frame interval are separate prominent fields (never label the
minimum as 1% low). Timestamped 40-bin history expires at ten seconds. Reference
lines are 60 FPS/33.3 ms, labelled outside the plots. CPU frame/physics single
tick/GPU are secondary non-additive timings. Pause/background clears history
and suspends sampling; resume begins fresh. Headless overlay tests cover window
expiry, focus exclusion, bounded storage, 720p/1080p bounds and capture ownership.
Human review: toggle Advanced performance panel and inspect labels/graphs over
actual gameplay at those resolutions; subjective readability remains unverified.
