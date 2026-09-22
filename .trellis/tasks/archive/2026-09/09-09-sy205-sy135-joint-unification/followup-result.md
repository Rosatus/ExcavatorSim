# SY205 bucket and heading follow-up

## Root causes and decisions

- The prior uniform numerical range did not check imported geometry. With logical -X bucket rotation, -45 degrees brings the teeth into the stick envelope. Use SY205-only [-20,95] degrees in the sync policy; unchanged rest, axes, input profile and SY135 limits. All 116 integer-degree samples retain linkage circle reachability and clear the tested stick envelope outside the shared pin.
- Imported PackedScene measurement confirms bucket-local bounds x[-0.650,0.661], y[-0.434,1.160], z[-1.116,0.108]. The old teeth [0,-1,-1.04] were detached. The initial research max-negative-Z candidate was also wrong: it selected curved back geometry. Actual five tips lie in the maximum-Y band, near [0.005,1.156,-0.990]. Reposition teeth, mouth, side/floor/back regions and blocking shell/rear; retain the already calibrated cavity. Opening normal points away from cavity and an attainable combined pose reaches dump orientation. Shell/rear centers checked against triangles, not just AABB.
- SY205 asset faces +Z (arm, cab, track declaration agree). Remove whole-machine spawn PI; retain +Z travel and cab PI. External camera rear/right both reverse for SY205. SY135 camera preset and calculations unchanged.
- Existing frame/pin/axis contracts and controlled imported-mesh measurements resolve the mechanical gate; no asset re-export, pivot, authority or gateway changes needed.

## Automated evidence

- sy205_bucket_geometry_test: imported teeth band, blocking bounds and triangle distance, full-range stick envelope, passive linkage reachability, attainable dump: PASS.
- camera_workflow_test: five modes for both models, actual front/rear/right, model switch/reset/cab: PASS.
- equipment_command_mapper_test: physical directions and full endpoints: PASS.
- bucket_soil_tool_test: cut, lateral cut, scrape, push, contain/dump and mutation-free classification: PASS. Contact fixtures now position the tested region at terrain, rather than assuming old absolute local Y.
- jolt_chassis_track_test: straight, braking, pivot, stale terrain and lifecycle passed for both models. First slope run used a ramp facing the old world -Z travel direction and failed. Corrected ramp to +Z; focused slope plus controller spawn/reset/model-switch rerun PASS (followup-jolt-heading.log). The first failed full log is retained.
- pixi run verify: Ruff/mypy, 195 backend tests, 23 tooling tests (1 existing symlink skip), provenance and standalone paths: PASS.
- Sync --check: PASS. Protection comparison in followup-protection.txt.

## Human manual (pending)

Restart/select SY205; inspect chase/operator/work-tool/inspection and cab, hold J/L to both endpoints, perform one scoop and dump. Confirm corrected proxy alignment in debug view and practical digging range. These headless/mesh checks do not claim final visual or contact tuning approval. Task remains in_progress, no commit/archive.

## Independent review follow-through

The reviewer identified a pre-existing compatibility heading consumer hard-coded to -Z. The generator now copies the SY205 rig forward declaration into catalog tracked_locomotion; TrackedLocomotionState handles optional +Z travel/support while preserving the -Z default. Focused compatibility lifecycle/motion tests pass, including both models and the SY205 slope. A direct comparison with HEAD proves SY135 full state snapshots identical across 1,800 ticks on flat and two slopes (followup-sy135-locomotion-parity.log). No controller/Jolt/shared-frame/gateway edits were required.

Expanded geometry assertions after review: rim endpoints, mouth midpoint/orthogonality, both side cutters, floor and side plate centers against imported triangles, and cavity corners against imported bounds all PASS. Surface approximation tolerance is 0.16 m; this is a coarse collision proxy, not an exact mesh collider or a guarantee of perfect visual contact.

## Bug retrospective

Categories: cross-layer contract, implicit axis/geometry assumptions, and coverage gap. Earlier sign/endpoint tests proved bounded q and motion direction but not shape alignment or mechanical clearance. A raw extrema label was also insufficient to identify teeth. Prevention: imported mesh landmark/surface assertions, physical camera front/right assertions, a single forward declaration propagated to both motion consumers, and explicit SY135 state parity. Human visual/contact acceptance remains pending.
