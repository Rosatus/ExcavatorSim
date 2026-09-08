# Implementation Result

## Final acceptance — 2026-09-08

User verified the final working-lip repair in the game and reported the issue
fully resolved, then explicitly requested commit, push and task archive.
This supersedes earlier pending manual acceptance notes below. No claim is
made that the user separately executed every suggested visual test matrix.

Final residual diagnosis used recorded user motion and live native SDF. The
tooth-to-floor working span was absent from cutting geometry. A ruled lip
surface plus matching roof/contact coverage removes all eight observed
regression targets in the recorded replay. Separate native path boundaries
avoid unintended diagonal cuts. Final five focused checks passed; representative
commit cost is 16.110 ms (previous episode-only implementation 12.770 ms).
See `research/live-residual-evidence.md` for final evidence and tradeoffs.

Delivered scope also includes delayed soil landing with conserved flight mass,
empty-dump completion, improved soil meshes/materials, residual geometry-only
recuts, and continuous-lift episode retention. Earlier results below record
the incremental development history, not the final performance measurement.

## Delivered

- Explicit bucket/in-flight/terrain mass lifecycle under the existing material authority. Committed release precedes ground edits; bounded flights arrive using shared timing. Closing the bucket does not cancel released soil. Failed or clipped landing restores the unrepresented amount to retained stock.
- One terrain transaction per cadence, including arrival when background settle work exists. Release events trigger an immediate world snapshot signal and are not replayed at landing.
- Cached irregular 32-triangle grain/clod meshes, unchanged particle counts, coordinated clod/particle gravity, and a soft dust alpha texture.
- Shared Ground037 soil material for voxel surface and bucket fill, triplanar mapping, normal and roughness detail. Moving fill uses local texture coordinates. Existing Terrain3D material policy and voxel resolution are retained.
- VFX toggling consumes/cancels old release presentation without replay.

## Agent automated

- Godot editor import/parser check passed (exit 0). Existing duplicate texture UID and editor-exit resource warnings were recorded in `output/soil-import.stderr.log`.
- Focused `soil_release_visual_quality_test.gd`: passed high/low release timing, actual SDF unchanged before arrival, gate closure, single transaction, failure return, conservation, reset, resource reuse, projection, dust mask, TTL, and toggle behavior. Final logs: `output/soil-quality-final.stdout.log` and `output/soil-quality-final.stderr.log`.
- `voxel_soil_material_field_test.gd`: passed.
- `voxel_excavation_world_test.gd`: passed; existing Terrain3D interpolation deprecation warning remains.
- `voxel_cutting_performance_test.gd`: passed; representative CPU commit 6.424 ms, compared with previous task's 6.569 ms. Coverage output and final SDF parity pass. This does not measure added material GPU cost.
- Independent read-only authority and visual reviews completed. Fixed the foreground/background double-commit guard and coordinated hero-clod gravity; added no-replay VFX toggle coverage.
- The initial new visual fixture crashed because it omitted the existing standalone convention `excavation_world_path = NodePath()` and entered deferred connection retries. Corrected the fixture; rerun passed. No runtime connection behavior was changed.

No broad suite pass is claimed: the prior task documented baseline failures in older authority/deposit and soil-effects fixtures. This task uses focused regression plus material/world/cutting checks rather than treating those old assertions as current visual acceptance.

## Human manual — pending

Run the usual SY135 main scene: scoop, dump near the ground, then repeat from a high bucket. Expect falling soil before ground growth, irregular grains, and visible surface detail. Close/move the bucket mid-release, reset, and re-excavate the deposited soil. Inspect the bucket fill and terrain from near/far views, checking texture scale, continuity and smoothness. Aesthetic quality and GPU cost require this runtime review.

## Limits

Flights use one predicted endpoint and representative arrival time per short batch. Terrain changed during flight is re-read for deposition, but existing particles do not retarget. Continuous cutting can postpone arrivals while preserving escrow. Rejected/unrepresented mass returns to the bucket and may visibly restore fill; capture capacity reserves room for this case. These are declared bounded approximations, not a granular simulation.

Task remains open for human visual acceptance. No commit, push, or archive was performed.

## Follow-up fixes after user review

User reported ongoing airborne effects after emptying the bucket and a surface remnant at the end of a lift. Both were diagnosed and repaired; see `research/followup-diagnosis.md`.

- Continuous unloading exposed milligram-scale returned residue cycling indefinitely through flight, amplified by the 5% minimum emitter intensity. Preserve stock below 0.01 voxel loose volume without releasing it; scale effects by real volume. Final flight completion explicitly retires remaining GPU flow and clods. Voxel snapshots cannot use stale legacy flow or replay already completed events.
- A previously engaged upward SY135 cut can complete its trailing shallow roof sweep, including while teeth admission still succeeds. Continuation requires actual remaining surface, retains no-contact negative cases, uses overlapping depth strips and rotation-aware bounded transform sampling.

Final checks all passed: `voxel_bucket_cutter_test.gd`, `voxel_lift_exit_test.gd`, `soil_dump_completion_test.gd`, `soil_release_visual_quality_test.gd`, `voxel_excavation_world_test.gd`, `voxel_cutting_performance_test.gd`. Logs use `output/followup-<test>.*.log`. World integration retains the existing Terrain3D interpolation deprecation warning. Representative cutting CPU commit was 6.535 ms; final coverage/SDF parity passes.

Dump regression: 20 simulated seconds, 0 releases in last two seconds, flight mass 0, retained residue 8.44 mg, exact balance 0. Native lift regression: residual surface SDF 0 -> 0.80874 (air), exactly one exit terrain revision. Tests cover empty/stale flow, late subscription, small-event strength, safe unengaged rejection, and surface points between depth strips.

Human follow-up: hold dump until empty and wait for the final falling soil to land; expect no continuing stream or stranded clods. Scoop and lift/curl through the final shallow surface section; expect the trailing surface remnant to be cut. Already airborne soil may still fall briefly after bucket inventory becomes empty; no new persistent flow should follow completion. Task remains in progress pending this observation.
