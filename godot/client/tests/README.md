# Godot tests

Deterministic fixtures and focused Godot-side checks belong here. Tests should cover scene contracts, motion decoding, generation guards and world-state repeatability as those milestones land.

Run the foundation scene contract from `godot/client/`:

```powershell
godot --headless --path . --script res://tests/foundation_scene_test.gd
```
