# Product game menu and driving HUD

## Goal
Replace the engineering panel and keyboard diagram with a coherent, restrained charcoal/warm-white/yellow game interface.

## Requirements
- Default local gameplay starts automatically after model initialization. Remove Start/Pause buttons and UI hotkeys.
- Esc / gamepad Start toggles a modal pause menu; resume restores input only through existing neutral arming.
- Menu includes resume, model, camera, audio, controls and confirmed reset; reset returns to playable state. Engineering tools remain in Advanced.
- Machine/payload readouts live in Advanced. CAN recording, Gateway restart and TCP connection indicator stay visible in the upper-left during driving and menus.
- Lower-right controls use two side-by-side crosses with four track keys above. Each key independently highlights its action and switches keyboard/gamepad labels with the active device. No automatic blocking guide.
- Mouse, keyboard and gamepad navigation; clear focus, cancel/back and destructive confirmation.
- Responsive 720p/1080p layout, readable spacing and shared theme.

## Acceptance
- Automated: menu state, startup/reset lifecycle, input isolation, focus, device prompts and viewport bounds.
- Human: readability and gamepad interaction feel in one representative driving session.

## Scope
Godot product UI and its presentation input/lifecycle adapter. Preserve soil, physics, CAN and backend contracts. No new game modes or graphics settings.

## Approval
User approved the presented direction and explicitly authorized task creation and execution on 2026-09-09.

## Restrained menu atmosphere
User requested dynamic backgrounds/animation. Added a procedural low-contrast contour field with slowly drifting warm/cool light, driven by UI time only while the menu is visible. Menu entry fades over 220 ms; page contents fade over 160 ms. Shared surfaces use translucent blue-gray, fine rim borders and soft shadows; driving HUD remains static. No textures, particles or scene blur. Operator UI headless regression passes; GPU appearance and subjective motion remain pending human review.

User refinement: removed the persistent machine/operation/bucket DrivingHUD shown in the supplied screenshot. Session readouts remain in Advanced; upper-left HardwareDock and lower-right cross-layout control HUD remain.

## Closeout
User authorized commit, push and archive after iterative UI review on 2026-09-09. Automated evidence is recorded in result.md; no separate GPU visual test or gamepad-feel pass is claimed.
