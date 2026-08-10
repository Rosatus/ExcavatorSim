# Godot tests

Deterministic fixtures and focused Godot-side checks belong here. Tests should cover scene contracts, motion decoding, generation guards and world-state repeatability as those milestones land.

Run focused contracts from `godot/client/` (replace `godot` with the installed
Godot 4.7 executable on Windows):

```powershell
godot --headless --path . --script res://tests/foundation_scene_test.gd
```

The release-candidate matrix is:

```text
foundation_scene_test.gd
sy205_glb_test.gd
motion_client_test.gd
terrain_state_test.gd
excavation_gameplay_test.gd
visual_pass_test.gd
release_candidate_test.gd
```

These scripts are standalone `SceneTree` checks rather than an addon test
framework. They use fake transport or local seams and never require a running
Python service; the backend contract remains covered by `pixi run verify`.
