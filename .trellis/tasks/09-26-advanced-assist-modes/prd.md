# PRD — Advanced assist modes

User request: two opt-in advanced settings.

1. **Relaxed assist control** (宽松辅助控制): guided assists must not hard-bind
   bucket attitude forever. When the pose reaches a point where surface
   following and the held bucket angle cannot both be satisfied, progressively
   release the angle constraint and keep riding the surface instead of
   stalling.
2. **Simple digging** (简易挖掘/只切不卸): soil must never leave the bucket
   under any circumstance, and a full bucket must never block cutting — the
   bucket is a cut-only "black hole".

## Contracts

- Strict attitude hold remains the default; relaxed releases only on
  BLOCKED_KINEMATIC and re-latches the attitude reference each relaxed tick.
- Simple digging suppresses the dump gate entirely (no deposit can stage);
  cutting keeps committing geometry with over-capacity mass routed to
  `discarded_cut_mass_q` — the overflow sink already exists, no capacity
  override needed.
- Both options persist in the operator config file and survive pipeline and
  authority rebuilds (model switches included).

## Validation

`assist_modes_test.gd`: strict stall vs relaxed continuation at a kinematic
corner (infeasible vs relaxed flag, measurable extra travel, bounded
per-tick attitude drift); dump gate held closed in all opening poses, cut
commit past capacity, gate restored on disable.
