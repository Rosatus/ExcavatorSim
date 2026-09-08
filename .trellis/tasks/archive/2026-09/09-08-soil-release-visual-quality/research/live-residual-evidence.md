# Live residual evidence, 2026-09-08

The user restarted and reproduced after the earlier temporary eval indentation
error disrupted the debugger bridge. New run was live; the loaded cutter has
`_within_lift_exit_envelope`, confirming the latest episode fix is present.
Data, mesh and collision revisions were 77, queue empty, no refresh timeout,
no queue saturation. 77 successful native cuts and 8 `no_sdf_change` rejections.

Screen rays into the visible strip hit the actual VoxelTerrain collider at
world (-0.8066,0.0025,19.3940) and (-1.2055,0.0025,19.4420).
Native SDF at x=-0.875 shows air at z=19.125/19.25 and 19.625,
but solid at z=19.375/19.5 from approximately y=-0.625 up to zero.
This is actual residual SDF, not merely a stale render or Terrain3D overlay.

Snapshot: `output/lift-exit-followup/live-residual-snapshot.bin` stores
7,680 native samples, pose, journal and status. A later larger snapshot
`live-residual-after-trace.bin` stores 94,208 samples after further user cuts.
No live terrain data was modified by these reads.

Independent source audit identified an uncovered tooth-to-floor interval.
At product scale, the point bucket-local (0,0.184,-1.104) is outside the
inner cavity, between the tooth and floor front. `lip_gap_probe.gd` checks all
combined native path segments, including connector segments. At pitch
-45/0/45/180 degrees, clearance to the nearest brush is positive, about
0.118–0.128 m, while tooth/floor control points are covered. At 90/135 degrees
vertical roof cleanup happens to cover this location. Results: `lip-gap.out`.
This proves a geometry omission, but not yet correspondence with the user's
actual motion. Do not claim the screenshot's cause has been established.

A temporary runtime Node `ResidualTraceCapture` records existing pose caches,
cutter result and transaction per tick without sampling/mutating pose history.
Its source was checked headlessly before attaching. The initial recording
started after the user's second action and contained 2,044 stationary frames
at revision 227; it is not a usable motion recording. A fresh capture was
explicitly armed and user asked to perform one action after arming. It is
still waiting on movement as of the latest inspection. It auto-saves at
36,000 frames; `finish()` saves `live-motion-trace.bin`. Root should inspect
counts before accepting a recording as valid.

## Valid user recording and causal reproduction

After explicit re-arming at the user's request, capture contains 6,318 frames:
324 accepted, 554 above-ground, 6 separating, remainder stationary. Data revision
227 -> 453. Extracted ticks 58300–58720 (421 frames) into
`tests/fixtures/sy135_live_residual_trajectory.json`. They are real bucket-link
poses, not interpolated invented controls. Replay uses the normal 60 Hz submit
and 20 Hz commit loop in a fresh native zone.

Five actual underside points remain solid before the patch, matching observed
SDF: (-38,-6,-86)=-0.030519, (-37,-6,-88)=-0.091556,
(-37,-5,-87)=-0.335704, (-36,-5,-89)=-0.381481,
(-35,-5,-91)=-0.152593. All lie outside the union of even the potential native
paths throughout the real trajectory. The suspected lip omission is therefore
present in the recorded action, not just a contrived geometric fixture.

The working-lip surface and roof fix clears these five plus three surface
targets (-35,0,-86), (-34,0,-88), (-33,0,-90). All eight are positive SDF
after replay. Other peripheral roof samples outside the working width are
not treated as proof of required deletion. No global island-removal claim.

## Review and final verification

Independent review caught a possible extra diagonal connector caused by
combining the new lip with old floor lanes. Preserve its native path boundary,
alternate per-transform traversal and discard consecutive duplicate points.
Additional unit checks cover yaw/roll, the working span, exterior side points,
and nondegenerate final native paths. The fixture checks its count/tick bounds,
actual submissions, mass balance and exterior ground.

Five final checks pass: cutter, recorded live residual, existing lift exit,
continuous lift and performance/optional diagnostics (`lip-final-*.out/.err`).
Representative commit is 16.110 ms vs previous 12.770 ms; added coverage
increases work and credited cells, while the fixed sparse stencil/calibration
and conservation remain unchanged. Native path count is six. This cost is a
known tradeoff; perceived smoothness and fresh-game visual acceptance remain
user verification, not inferred from headless tests.

Temporary runtime recorder removed after saving. Current live soil was never
mutated by diagnostic reads or directly erased by the repair. Existing residual
geometry is not retroactively cleaned. No commit/push requested or performed.
