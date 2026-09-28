# SY80U model-aware CAN output

User scope: ExcavatorSim + tools/can_gateway sender only.135 sends135 frames,80U sends80 frames; reverse GuideSystem parser/calibration/renderer for matching joint orientations and movement directions. PC001 receiver and can_replay excluded.

Complete: telemetry model identity, separate codecs/profiles, side swing, runtime switching, console/persistence isolation, roundtrip and actual Godot/source/frozen integration checks. See implement.md for evidence.

Reference: ICT_MACHINE_MODEL=SY80U selects SY80C6Y5LU; existing database calibration overrides factory defaults. Bundled80 calibration snapshots current x86-linux-debug runtime; receiver length values differ native80 geometry. Orientation/direction parity delivered, no claim of identical geometry/tip positions. No GuideSystem/replay edits, no commit/client export.
