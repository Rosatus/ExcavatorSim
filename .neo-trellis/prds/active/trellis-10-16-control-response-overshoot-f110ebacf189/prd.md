# 控制系统响应与超调优化

## Goal
Make semi-automatic guided assists, automatic surface excavation (joint/Cartesian motion) and automatic waypoint driving faster and free of overshoot, without weakening existing safety/precision gates (grade +/-8cm, 1deg/5cm alignment, 3cm arrival, envelope overcut protection).

## Evidence (2026-10-16, SY135, headless 60 Hz)
- Track plant: speed step tau ~0.1 s; neutral coast 0.5 m from 3.07 m/s (decel ~9 m/s2). Yaw gain ~0.5-0.8 of ideal (slip), coast 0.2 rad from 1.88 rad/s.
- Track creep defect: recovery traction floor lifted commands 0.02..0.1 to an on/off ~0.25 m/s limit cycle (0.06 cmd -> 0.19..0.27 m/s). Fixed in track_contact_solver (floor capped by commanded speed and faded by deficit); linear now.
- Waypoint square baseline 63.5 s (aligning 29.2 s / 5 pivots, driving 32.1 s). Pivot = P law with ideal-kinematics conversion (~0.55 effective gain) -> long tails; approach = 0.9 m/s2 envelope + 0.8/s exponential crawl.
- Guided assist strict: release at 1 m/s coasts 0.35 m and leaves tooth plane by 3.2 cm (uncoordinated per-joint jerk braking after deadband zero output). rates_to_commands ignores per-joint lower reach bounds when decelerating -> per-joint clamp distorts direction.
- Surface job: Cartesian moves are saturated P laws (gain 2/3) with exponential tails and 0.2 s dwell gates; joint slew uses half-accel braking + 1.8/s tail. Normal urban run: cut 352 s, approach 166 s, sweep 133 s, dump swing/return 245 s (5.8 s per 90deg vs ~3.5 s time-optimal), dump_lift 89 s, dump_close 70 s. Simple urban baseline (this code): 233.6 s total, final grade [0,+0.049] m.

## Plan
1. Shared motion primitives (lag-aware sqrt profile; exact-plant joint positioner using the KinematicArticulationState chain).
2. Tracked WaypointDriver: time-optimal pivot with measured yaw-rate loop, coast-predicted arrival, realistic braking envelope.
3. Guided assist: coordinated feasible-scale selection in rates_to_commands; coordinated braking after release.
4. SurfaceJobExecutor: time-optimal joint slews, lag-aware Cartesian profile, velocity-aware reached gates, lift/swing overlap where safe.

## Acceptance
Existing assist/navigation/surface-job regressions pass; measured time and overshoot reported before/after. Human feel review remains user-owned.

## Progress
- Baselines recorded in logs/ (ignored). Track creep fix applied; square with old driver became slower (75.0 s) because it relied on the floor kick -> driver rework required.- Waypoint driver: lag-compensated approach (2.5 m/s2, 0.2 s) + slip-compensated PI pivot. Square 63.5 s -> 42.05 s (aligning 29.2 -> 13.25 s), error 0.026 m, max departure 0.45 deg. Lifecycle crawl check replaced by a brakeable-without-crawl check.
- Guided assist: coordinated release braking (travel ramp 3 m/s2 with full height/attitude feedback, scoped holds_at_neutral). Strict 1 m/s release plane error 3.17 cm -> 0.50 cm; 0.4 m/s 0.79 -> 0.65 cm. Coast distance unchanged (0.35 m) by design.
- Surface job: MotionProfile joint slews (90 deg 5.8 -> 4.4 s in contract plant, 0 overshoot), lag-aware Cartesian profile (2 m/s2, 0.12 s), rest-based reached() (0.02 m/s, 0.05 s). Looser gates (0.04 m/s, or dwell only) were tried and rejected: cut overshoot 4 cm / final grade 0.086 m.
- Urban simple 233.6 -> 214.8 s, final residual 0.049 -> 0.024 m (cut phase 60 -> 77 s because of the rest gate). Urban normal ~1147 -> ~1050 s, 21 dumps, residual <= 0.018 m.
- Pre-existing, unchanged: jolt_chassis_track sy205 reverse zero-crossing, slope_grade sy205 bench, assist_modes voxel simple-digging failures (all fail on HEAD).
- Not addressed: strict intent -1 stall at the arm lower joint-limit fade (pose-specific), relaxed travel reaching ~0.16 of 0.3 m/s (solver chooses boom-dominant rates); human feel review is user-owned.