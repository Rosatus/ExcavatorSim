# Lift volume follow-up — 2026-09-08

User screenshots showed remaining columns/ridges after the prior lift-gate fix.

## Diagnosis

Root causes: an implicit geometric assumption (overlap on each axis implies full circular coverage) and a test coverage gap. Fixed width/height brush lanes left diagonal interior holes; the new independent dense section failed 184/1425 points on the old implementation. Roof paths also skipped the first above-cutoff sample instead of retaining the intersection. The previous single roof-point test could not detect either whole-volume omission.

Change: derive centered lanes from box dimensions and brush radius (spacing <= 1.2 radii), align lift contact to roof lanes, and retain cutoff crossings. Keep native radii, floor lane layout, depth endpoint inset and sampling cap. A duplicate crossing point discovered during real SDF testing was removed; the unit regression explicitly prohibits zero-length crossing segments.

## Agent automated

Final logs: `output/lift-exit-followup/final-*.out` and `.err`.

- `voxel_bucket_cutter_test.gd`: 0/1425 uncovered points; existing entry/rejection cases, cutoff crossing and nondegenerate paths pass.
- `voxel_lift_exit_test.gd`: entry 140, first lift 84, subsequent exit 70/63/49/28/28 interior voxel checks all report zero solids. Surface probe changes 0 to 0.8545; fully clear motion rejects; conservation holds.
- `voxel_cutting_performance_test.gd`: passes coverage, optional-diagnostics and cadence invariants; commit 9.892 ms, 3 combined native paths, zero conservation error. Earlier single-scenario measurement was about 6.5 ms; additional coverage costs time.

## Human manual — pending

Repeat the screenshot's SY135 dig and slow lift/curl through the last segment; inspect the pit bottom and trailing surface across its width. Check perceived cutting smoothness. Headless geometry evidence does not establish that the exact unrecorded operator trajectory is resolved.

## Prevention

Document circular diagonal coverage and cutoff segment continuity in the frontend boundary contract. Retain full-volume and native SDF regressions alongside admission tests. No shader masking, visual mound removal or global floating-component deletion was introduced.

## Second manual failure: continuous thin surface wall

User provided another screenshot after the above patch; manual acceptance failed. Earlier claims only proved those fixtures, not the screenshot trajectory.

The missed geometric assumption was that local +Y could serve as the world lower edge. `BucketSoilTool` aligns box Y with the contract outward normal, and the actual rotated bottom can remain submerged after that face is airborne. Both cleanup and admission inherited this same error; therefore more lane samples could not fix it.

New geometry uses vertical ray/slab intersections with the oriented inner box on a world X/Z grid. The same lower-envelope helper serves cleanup and engaged-lift contact. Radius, sampling cap, world edit bounds and original-surface ceiling remain bounded. The helper returns only real intersections; it does not clear an entire bounding box.

Agent evidence (current files):

- `roof-before.out/.err`: real SY135 shallow 25-degree fixture rejected continuation and missed all 27 independent submerged-volume roof projections.
- `roof-after.out/.err`: the same fixture accepts and misses zero of 27; earlier 1425-point coverage and negative gates still pass.
- `roof-native-final.out/.err`: actual leading entry followed by 12 small lift steps; all 18 unique roof SDF coordinates are positive, exterior ground control remains solid. Previous inner-volume and full-clear checks pass.
- `roof-voxel_cutting_performance_test.out/.err`: performance/diagnostic regression passes, 11.944 ms single commit, 4 native role paths, zero conservation error. This is higher than the earlier 9.892 ms measurement; not a subjective smoothness pass.

Logs are under `output/lift-exit-followup/`. No current-run stderr errors. Human repetition of the screenshot action remains pending; no claim of exact trajectory reproduction. Prevention is now explicit in the frontend spec: test surface projection above the rotated submerged cavity, rather than equating clean interior with clean roof.
