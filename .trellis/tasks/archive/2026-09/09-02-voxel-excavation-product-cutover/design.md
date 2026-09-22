# Design - product cutover

This child does not invent new soil algorithms. It integrates the accepted
parent/child contracts, proves the complete product flow, then removes the old
authority surface.

Before deletion, the voxel implementation remains behind a temporary
generation-bound development selection so the last working legacy commit is a
clear rollback point. Runtime hot-switching with a loaded bucket is forbidden;
model/profile/reset transitions create clean generations.

Jolt uses voxel collision only inside the zone and masked hard collision outside.
Track approach into dirty/unready blocks is bounded or disarmed; a ready support
footprint continues normally. Bucket cutting uses SDF truth independently of
collider lag. UI reports aggregate readiness/backlog rather than raw per-block
spam.

Once the focused gates and explicit human checklist pass, make voxel authority
unconditional and remove the old heightfield excavation writer, active patch,
loose flux, parcel material, old cell-patch/collider ownership, solver toggles,
and tests that assert obsolete behavior. Retain hard-site/Terrain3D presentation,
machine descriptors, Jolt runtime, and reusable effects.

Rollback after deletion is Git-level at the recorded pre-cutover commit.

