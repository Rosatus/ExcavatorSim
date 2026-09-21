# Reusable attachment soil adaptation

## Objective
User approved both modular runtime/tooling and an adaptation skill, following GB12 work. New compatible soil-holding tools should be integrated through data and generated resources without tool-name branches in runtime code.

## Delivered
- bucket_soil_geometry.gd: one convex planar tool-local mouth polygon defines local opening/cavity frames; validates source/profile hashes and all generated compatibility projections.
- bucket_soil_release.gd: shared threshold/orientation policy, uses transformed mouth +Y for geometry-backed tools; authority keeps transaction ownership and guards.
- BucketFillSurface.configure_contract: direct pinned profile loading. Native compatibility map unchanged; GB12 removed from registry. Generated profiles and triangle clipping honor actual mouth polygon.
- MotionPresentation and BucketSoilTool use common frames and actual polygon sample points. Attachment loader checks geometry source against selected catalog GLB.
- Generic bake_bucket_soil.gd plus gb12_s50_soil_bake.json replaces dedicated GB12 baker. Exact mesh/anchor selectors, hash pin, footprint sampling, validation before writes, catalog last, read-only --check.
- Generic Forward+ preview tool emits 5/50/100% images.
- Existing godot-excavator-attachment-import skill extended with focused contained-soil reference; corrected host model identity guidance.

## Verification (final affected state)
PASS: bucket_soil_geometry_test, gb12_soil_test, gb12_soil_dump_test, bucket_fill_surface_test, bucket_soil_tool_test, attachment_switch_test. bucket_fill_follow_test passed earlier in this change; later edits did not change its native follow path.
PASS: tools/tests/bucket_soil_bake_test.gd (deterministic outputs; source hash/missing mesh/moved or crossed anchors/output aliases fail without writes).
PASS: generic bake --check on final GB12 resources.
PASS: skill quick_validate via uv run --no-project --with pyyaml python -X utf8.
Forward+ preview generated and inspected under output/gb12-modular-preview. Unrelated CAN gateway port warning during preview does not affect rendering. Native fill volumes unchanged. GB12 full visual volume .20299269 m3 after polygon containment (nominal ledger capacity remains unchanged).

## Limits / handoff
Supports one convex planar mouth and lining represented by a height field; no multi-outlet/articulated cavity or physical repose-dependent unloading inference. Release threshold remains explicit behavior tuning. First bake validates in memory before writing; interrupted multi-file write can be repaired by rerunning the recipe. No commits/pushes performed; unrelated workspace edits preserved.
Original GB12 human in-game handling acceptance remains in 09-18-gb12-soil-adaptation; this reusable tooling/workflow task is implemented and verified independently.
