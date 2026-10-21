# Checkpoint

Implementation and automated verification complete on 2026-09-28. Request:
optimize SY80U ordinary bucket contained soil and cutting/collision geometry;
user screenshot showed a long protruding soil slab.

## Delivered
- Replaced stale cavity/rim profile with measured imported inner lip and rear rim,
  shared geometry-backed cavity frame and clipped lining profile. Added reproducible
  native-model recipe and native catalog support to the existing bucket baker.
- Corrected side segments, sloped front wear plate, rear shell/support and tooth
  direction from source mesh. Preserved GLB, articulation, ledger capacity and
  ordinary .5 release threshold.
- Enabled SY80U native swept cutting with cavity, floor/lip and lift-exit cleanup.
- Added mesh-containment/contact and actual terrain cut/dump regression tests;
  included native SY80U in shared cutter/fill-follow coverage and native recipe
  in shared deterministic bake validation.

## Agent automated — PASS
Using verified C:/apps/godot_voxel/godot.windows.editor.x86_64.exe, headless
project C:/code/ExcavatorSim/godot/client:
- res://tests/sy80u_bucket_soil_test.gd — imported vertices, independent ray
  lining contacts, closed/clockwise fill at 0.5–100% stock, monotonic volume,
  measured mouth bounds, contact alignment, rotated release axis. Full visual
  volume ~0.09423 m3 (approximation, does not recalibrate rated capacity).
- res://tests/voxel_bucket_cutter_test.gd — includes SY80U ordinary slow/fast/
  rotated strokes, deep cut, lift exit, stationary/air/withdrawal/back-brush
  negatives; existing SY135/SY205/GB12 coverage also passed.
- res://tests/bucket_fill_follow_test.gd — SY80U joins existing model switch,
  stale snapshot, between-tick rigid follow, reset and teardown checks.
- ../../tools/tests/bucket_soil_bake_test.gd — both GB12 and native SY80U
  deterministic/current outputs; bad source, missing mesh, moved/crossed anchors
  and output alias rejection without writes.
- res://tests/sy80u_soil_transaction_test.gd — actual native cut captures stock,
  shallow carry retains it, confirmed open-mouth release deposits terrain,
  closed mouth retains remainder, ledger conserved throughout.
- All exit codes 0; stderr reviewed and empty. Logs are in the user's TEMP:
  sy80u_bucket_soil_test.*, voxel_bucket_cutter_test.*, bucket_fill_follow_test.*,
  bucket_soil_bake_test.*, sy80txn.*. git diff --check clean.
- Read-only peer review found no actionable issue. Old physics-rig bucket box
  is not production cutting/obstacle collider; actual solver uses updated soil
  semantic regions. Preserve unrelated work (gateway edits existed at start;
  another workspace workflow committed files during this task).

## Human manual — pending
Reload the scene, choose SY80U + ordinary bucket, dig/curl/lift/carry/dump.
Check that soil stays inside the bowl, follows the bucket without a long slab,
cuts continuously and leaves no thin wall on lift exit. Appearance/control feel
was not inferred from headless tests. No game launch or screenshot matrix run.

Next: hand off implemented changes and ask user to report any remaining visual
or contact issue from that short scenario. No further automatic checks needed
unless relevant code changes or new evidence appears.

## Commit audit requested by user
Reviewed cd1c10f, 0315f3b, 6513068, 0e9af98, 33b4666 and ac1f4e2.
No severe cumulative defect or lost work found. Retain history as requested for
minor issues: CAN capture helper landed in the bucket feature commit, and two
intermediate test commits were incomplete until ac1f4e2. UID sidecars are benign.
Verified committed contract/profile bytes match current files and catalog hashes;
existing five soil test passes remain valid. Preserve source DBC/calibration bytes
including their original CRLF/whitespace because provenance hashes pin them.
User authorized committing remaining workspace test/documentation. Visual review
remains pending; no history rewrite or push performed.
