# Design

## Diagnostic ownership
ExcavationWorld owns the process-local default-off preference and reapplies it to new voxel authorities after reset/model changes. Advanced uses the existing CheckButton pattern. VoxelExcavationAuthority keeps gameplay/status fields and transaction evidence available, gates expensive readiness/statistics/timing/allocation projections, and exposes a dedicated detached visual projection. Visual pulls never call get_status_snapshot, even when diagnostics are on.

Optional timing reads and records are gated. Readiness latency windows are controlled without clearing tickets or blocks; in-flight tickets from older diagnostic sessions do not contaminate new latency measurements. Operational clocks/physics-frame timeout logic remain unchanged. Native transaction SDF diagnostic sampling is skipped while disabled (digest fields are empty); exact-path digests remain because they gate no-op rejection. Identity, mass and rejection evidence remain available. Tests independently hash the complete edited SDF window to compare on/off outcomes.

## Coverage
Precompute per-axis ranks of the legacy decimal coordinate strings once per authority configuration. The packed integer rank key is injective over the bounded zone and sorts in exactly the previous `x,y,z` lexical order, including negative and prefix coordinates. This avoids formatting a string and allocating a coordinate array at every candidate visit.

After dedupe, copy only the bounding box of valid candidate coordinates into an authority-owned scratch VoxelBuffer. Reuse its allocation for equal dimensions, overwrite every sample on each call and drop it at generation teardown. No persistent SDF cache or material approximation change is introduced. Return early for an empty candidate set. Preserve the 16,384 probe admission order and 4,096 solid result cap.

## Validation / risks
Compare the old reference algorithm and new one on actual SDF buffers, including repeated reads after edits, clipping, duplicates and caps. Compare native coalesced cut identity/mass/digests with diagnostics enabled/disabled. Timing evidence is a focused headless measurement, not a promise about Forward+ FPS. Keep the change reversible by reverting only this task's files.
