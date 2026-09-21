# GB12 soil adaptation

## Request and scope
Adapt GB12 contained soil appearance and unloading conditions to its actual imported geometry. Preserve existing unrelated work and standard bucket behavior. No commits requested.

## Implemented
- Independent gb12_s50 fill profile, selected through optional soil contract fill_profile_id while keeping host model_id for authority.
- Imported GLB footprint-height bake with gusset/crown/lining coverage, proper lip-to-crown-front outlet normal (0, .538754, .842463), cavity and opening alignment. Catalog soil hash refreshed.
- Optional release_opening_down_dot selects GB12 .15 (8.63 degrees below horizontal); standard buckets retain runtime .5. Existing confirmation, cut/obstruction guards, pending stock and mass accounting preserved.
- Attachment changes invalidate fill; stale profile snapshots cannot bind to switched tools. Rigid local following retained.
- Reproducible baker: tools/bake_gb12_fill_profile.gd, execute through voxel Godot --headless --path godot/client --script ../../tools/bake_gb12_fill_profile.gd.

## Verification
Godot 4.7.2 custom voxel editor:
- gb12_soil_test: PASS (six fill amounts, imported lining containment, winding/closure to 20 microns for discarded degenerate slivers, monotonic volume, 48 curl/tilt/rotation combinations, lifecycle and native gate unchanged).
- gb12_soil_dump_test: PASS (actual terrain deposit at .2 down-dot, pending mass, closed-mouth retention, conservation).
- bucket_fill_surface_test, bucket_fill_follow_test, attachment_switch_test, bucket_soil_tool_test: PASS.
- soil_release_visual_quality_test finished with no reported errors.
- Forward+ D3D12 renders inspected: output/gb12-fill-5.png, gb12-fill-50.png, gb12-fill-100.png. Earlier wrong rear-rim bake superseded by final crown-front bake. Final full visual volume ~.20844 m3; ledger nominal capacity intentionally unchanged.
- Attempted independent subagent audit could not launch due platform model/history extension incompatibility; main agent performed exploration and checks.

## Remaining
Implementation and focused automated verification done. User-owned in-game appearance/handling acceptance pending; task retained rather than archived. Restart scene, select XTR13 + GB12, scoop and tip/tilt/rotate to confirm desired handling. No commits made; pre-existing uncommitted changes preserved.
