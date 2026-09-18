# Game menu and driving HUD

## Current product contract (2026-09-09)

`MotionOperatorUI` owns the product entry point: deferred local start after model initialization, a hidden menu on entry and no blocking onboarding. Low-level `ProductSession.request_reset()` still returns stopped; confirmed product UI reset resumes gameplay. F6/F7 have no product UI handler or buttons.

Esc / gamepad Start toggles the menu. The UI processes while SceneTree is paused, clears camera drag and blocks camera input, clears MotionClient focus before pausing, and requests local lifecycle pause. Closing restores only lifecycle/tree pause changes owned by the menu. Existing neutral arming remains authoritative. B cancels a confirmation before closing the menu. Destructive model/reset actions require confirmation, with cancel focused initially.

Navigation: Up/Down or D-pad traverses visible enabled controls; Tab/Shift+Tab follows the same order; A/Enter activates; B returns; LB/RB changes pages. Scroll containers follow focused controls. Keyboard/mouse and meaningful controller input switch prompts; analog noise does not.

The main scene stores only the OperatorUI owner and ControlInputHUD. `operator_menu_controls.tscn` supplies runtime-only controls instantiated before onready binding; do not instance the pre-composition menu layout into main.tscn, where it would expose obsolete panels in the editor.

`game_menu_layout.gd` owns composition and `game_ui_theme.gd` owns the visual tokens. Three switchable UI themes (`debug` default, `industrial`, `sany`) are selected from the Settings page and persisted in `user://operator_ui.cfg`; switching rebuilds the composed UI in place because the variants differ structurally. `industrial` and `sany` are *console variants* (`GameSkin.is_console_variant`): identical console layout and chrome, differing only in palette accent — amber `efb64d` vs SANY brand red `e82e24` (`accent_for`/`on_accent_for` pick accent and on-accent lettering; the red SANY plate takes paper-white lettering where amber takes dark ink). In all themes the open menu hides the HardwareDock and centers the panel on the viewport; under `debug` the dock stays in the upper-left while driving. Under console variants the dock never exists: a slim PC001 connection lamp sits in the menu header, CAN recording/Gateway restart live in the Advanced page (focusable), and driving shows only the lower-right HUD plus the menu button. Settings, controls and engineering tools are separate scrollable pages. Driving HUD is mouse-transparent; the lower-right HUD uses two side-by-side directional crosses with four track keys above. All twelve actions have independent highlights and keyboard/gamepad labels. Tests use `get_control_for_test(id)` semantic lookups because layout reparents controls after binding.

Console variants use a near-fullscreen machine console (panel up to 1360x820): the visible plate is a chamfered octagon drawn by a `MenuRoot` backdrop (`_Backdrop._draw`: plate fill, shadow, double-line border, breathing accent corner brackets, viewport corner reticles — `_Backdrop.accent` is set per variant); `StatusPanel` itself uses a transparent `frame_pad` stylebox for content inset. Inside: full-width header (title + lamp chip + `SYS-OPS // REV` micro text + scrolling hazard-stripe divider tinted via `stripe_color`), a left navigation rail (accent Resume CTA, numbered page buttons driving a `tabs_visible = false` TabContainer, "LB/RB 翻页" hint), a content column with per-page title header, and a footer row (Completion status + key hints). Rail buttons stay in the controller focus cycle (`_menu["nav"]`); `tab_changed` syncs their pressed state, page title and focus. The debug menu keeps the compact centered dialog (780x700) with visible tab bar.

CAN supervision runs while paused: heartbeat, shutdown/start deadlines and ICT replies continue; physical telemetry samples are not emitted while simulation is paused. The menu refreshes hardware status at 5 Hz.

## Verification

Focused contracts: `operator_ui_test.gd`, `control_input_hud_test.gd`, `camera_workflow_test.gd`, `ict_status_indicator_test.gd`, `gateway_restart_ui_test.gd`. UI bounds cover 1280x720, 1920x1080 and 2560x1080. Smaller phone-sized viewports are outside this desktop product target.

Manual acceptance: restart the main scene, drive immediately, open/close with Esc and controller Start; navigate all pages and reset dialog using only gamepad; reset and drive again; inspect HUD readability over bright and dark terrain. Aesthetic and control-feel acceptance remains human-owned per validation-budget.md.

## Atmosphere
`menu_atmosphere.gdshader` provides low-contrast contours and slow warm/cool gradients; `fx_strength` (0 debug, 1 console variants) blends in vignette, scanline and warm-glow accents. Its `ui_time` is advanced by the visible menu, independently of paused simulation. No background animation runs during driving. Entry/page tweens use pause-processing mode; rapid page changes restore previous page opacity before replacing the tween. HUD surfaces remain static to preserve readable input feedback. Headless UI tests do not prove GPU visual quality.

Driving-time assist overlays follow the same variant split. The T-key assist picker (`AssistMenu`) under console variants gains a hazard-stripe top edge, accent tick + `ASSIST` micro label, nav-rail-styled rows (selection = accent left bar via `set_pressed_no_signal`), muted hint and a deferred scale-pop on open (`_pop_assist_menu`); under debug it stays the plain centered dialog with `▶` marker rows. `SlopeSideView` under console variants redraws its frame as a rounded instrument plate (`set_theme_variant` → `_rounded_poly` slab with double rim, header band with accent title/tick, faint metre grid); its semantic guidance colors (terrain, target, cut fill, tooth) are theme-invariant, and the `d` distance dimension stays strictly horizontal (constant pixel height with vertical end ticks) regardless of the smoothed-relax knee height. `_style_assist_menu` rebuilds rows on theme switch since rows carry variant-specific stylebox overrides.

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
