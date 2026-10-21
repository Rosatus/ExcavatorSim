# Cleared contact is not completed excavation — 2026-09-08

## Evidence

User again reports a narrow standing residual inside the pit. The running game
was stopped when inspected, so the screenshot's exact trajectory/SDF remains
unavailable. Two independent audits considered admission, queue cadence,
native execution and rendering. Ordinary cadence retains and coalesces paths;
there is no evidence that it simply samples the latest frame. Queue saturation,
transient failures and renderer state remain separate unproven hypotheses.

A new real VoxelTerrain experiment commits an entry at 25 degrees, y=-0.65 m,
then lifts 0.65 m while translating 0.6 m over 120 physics ticks. A second case
also curls by 25 degrees. First lift frame rejects as separating and clears
engagement. All 120 subsequent frames reject: 15/115 and 20/120 historical
interior/roof targets remain solid. Logs: `output/lift-exit-followup/continuous-probe.out`.

Counterfactual experiment retained the existing engagement each tick but left
contact/path/ledger/execution unchanged. It generated three real additional
cuts and removed all residual targets. This isolates the episode lifecycle
from path width, native receipt accounting, and rendering.

## Cause and repair

`engaged` was used for both instantaneous solid contact and the authorized
excavation episode. A brush clears its own contact probes; the next upward
frame then retires the episode, and later solid contact cannot restart a lift.
Keep the existing episode across stationary/upward rejected air frames below
the original surface. The current inner box fully exiting that surface ends
retention. Invalid data/history, discontinuity and rejected non-upward motion
also end it. Actual lift proposals still require solid SDF; empty space does
not produce cuts. No new episode is authorized by the retention rule.

## Why earlier checks missed it

Root categories: implicit state assumption and test coverage gap. Previous
fixes addressed actual geometric and credit issues, but tests used large
steps and a hold before committing the entry. That hold still saw original
soil, so it could not reproduce the self-cleared cavity. Final-pose-only
inspection also omitted soil left behind earlier in the trajectory.

`voxel_continuous_lift_test.gd` now commits entry before hold, performs actual
60 Hz submissions/20 Hz commits, keeps historical interior/roof targets, and
requires later successful lift commits, zero residuals, mass balance and
unchanged exterior ground. Both cases fail before the lifecycle change
(`episode-before.err`) and pass afterwards. It also tests retirement above
the surface. Cutter unit checks cover unengaged, invalid and sideways-air
termination. The screenshot itself remains human verification pending;
these deterministic trajectories are not a recording of the user's run.

Final checks: continuous lift, cutter unit, existing lift integration, and
cutting performance/optional-diagnostics all pass (`episode-final-*.out/.err`).
Representative native commit is 12.770 ms, with unchanged mass calibration
and frozen coverage parity. No game launch/input or commit/push was performed.
