# Design

Reuse operator controller signals and existing reset/model confirmations. Build a focused layout helper and shared theme, reparent existing controls after bindings resolve, preserving hardware tools. Main menu is a centered responsive sheet over a dim background; advanced content scrolls. Driving HUD remains separate and mouse-transparent.

UI owns menu toggle, SceneTree pause and camera input exclusion. Before pause, clear optional transport input focus and pause local lifecycle. UI processes while paused. Closing restores prior mouse mode, transport focus and local running through existing neutral arming. Auto-start is a deferred UI product action after ProductSession initialization, avoiding changing low-level compatibility/test lifecycle defaults.

HUD uses compact rows for ISO sticks/tracks and updates device copy only on meaningful device input. Reuse authoritative bucket projection via existing controller labels.

CAN bridge supervision continues while paused; physical telemetry emission stops. Preserve externally owned lifecycle pause. Camera modal gate also clears drag so releasing mouse in the menu cannot leave an orbit stuck on resume. Tests use semantic control lookups, not pre-layout paths.

## User refinement
Upper-left HardwareDock retains CAN recording, Gateway action and TCP lamp permanently. Menu placement leaves room for that dock. Lower-right HUD uses two independent direction crosses with four track keys above; per-action highlighting and keyboard/gamepad labels. Focused control_input_hud_test and operator_ui_test pass after this refinement.

## Restrained menu atmosphere
User requested dynamic backgrounds/animation. Added a procedural low-contrast contour field with slowly drifting warm/cool light, driven by UI time only while the menu is visible. Menu entry fades over 220 ms; page contents fade over 160 ms. Shared surfaces use translucent blue-gray, fine rim borders and soft shadows; driving HUD remains static. No textures, particles or scene blur. Operator UI headless regression passes; GPU appearance and subjective motion remain pending human review.
