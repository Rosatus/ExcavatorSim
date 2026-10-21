# Bucket solid-ground support

User requests evaluation and a best-practice rebuild of bucket self-lifting, first on non-voxel ground/objects. All those contacts are collisions regardless of cutting angle.

Scope: preserve one authoritative dynamic chassis and bounded kinematic articulation; physical bucket shell/teeth geometry, solid filtering including ordinary objects, normal contact response at witness points, sustained/neutral support and release, opposite force on dynamic obstacles. Do not extend support to voxel soil in this round. Preserve pass-through/reset/disable and soil authority.

Plan: replace tick-displacement spring/duration cutoff with fresh same-step compliant unilateral contact solve, using point velocities and effective inertia. Finite geometric compliance permits articulated pressure while bounding penetration/force. Avoid stale next-tick contact replay.

Agent automated: real gravity-on SY135 Jolt lift/hold/retract integration; focused query, rotation, wall, dynamic reaction, voxel exclusion and lifecycle checks; existing articulation/pass-through regressions.
Human manual: SY135 on hard ground or static object, lower boom until supported, release controls then retract; assess feel and visual fit (pending, non-release subjective handoff).
