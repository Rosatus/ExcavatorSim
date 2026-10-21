# Market and architecture research — visual-first excavation

Research date: 2026-08-31.

## Evidence boundary

Commercial games generally do not publish their proprietary terrain data
structures or digging algorithms. Marketing pages can establish product intent
and visible features, not internal implementation. The recommendations below
combine verified public statements with clearly labeled architectural inference.

## Public evidence

- Construction Simulator's official updates state that earthworks terrain is
  simulated locally for the client because this makes work smoother, and that
  terrain construction-view updates were optimized to near real time. This is
  direct support for local immediate response, not evidence of its exact data
  structure:
  https://www.construction-simulator.com/en/updates.php
- DIG VR officially calls itself a light simulation with a casual arcade twist.
  This supports authentic machine controls combined with simplified digging as
  a legitimate product target, but reveals no terrain algorithm:
  https://wiredproductions.com/games/dig-vr/
- Spintires creator Pavel Zagrebelnyy publicly described a block-local height
  offset/deformation texture. Penetrating objects render extrude primitives with
  MIN blending; material pushed ahead uses MAX blending. This is a concrete
  example of local stamp-based deformation optimized for readable real-time
  feedback:
  https://www.gamedeveloper.com/programming/rendering-and-simulation-in-offroad-driving-game
- Excavator-simulator research has used GPU digging offset maps for terrain
  deformation and separately simplified the changing soil profile inside the
  bucket. That separation is more relevant to this product than a coupled
  particle continuum:
  https://www.scientific.net/AMR.382.16
  https://www.sciencedirect.com/science/article/pii/S0045790613001705
- Terrain3D 1.0.2 documentation warns that collision generation can be slow and
  consume substantial memory, and recommends querying height directly when X/Z
  is already known. This reinforces avoiding native collision rebuilds and
  per-physics-tick derivative refresh:
  https://terrain3d.readthedocs.io/en/stable/docs/collision.html

## Project findings

- The rejected v2 hot path executes semantic classification, sweep raster,
  material reservation, forced synchronous patch commit, derivative refresh,
  active aggregates, bucket cells and loose-soil flux. Focused headless timings
  did not represent sustained Forward+ terrain presentation work.
- Product terrain spacing is 0.5 m while v2 capped one cell cut at 0.08 m and
  could legally reject a tick through multiple semantic/identity gates. These
  choices structurally favor tiny intermittent marks.
- Existing code already supplies all seams needed for a replacement:
  `MotionPresentation.sample_bucket_pose_fixed`, `TerrainCommitScheduler`,
  `TerrainState`, `TerrainCollider`, `TerrainWorld` and `SoilEffects`.

## Recommended best practice for ExcavatorSim

The best fit is not a claim about how every commercial game works. It is the
simplest architecture supported by the evidence and current product priorities:

1. Keep authentic Jolt machine motion and stable model proxy transforms.
2. Turn the cutting edge's local swept path into an aggressive, gap-filled
   heightfield stamp.
3. Coalesce stamps and update authoritative terrain/collision/presentation at a
   fixed low rate rather than every physics tick.
4. Give immediate dust/grain feedback and maintain only a scalar bucket visual
   load derived from accepted terrain changes.
5. Treat dumping as a pooled visual-only mound in the MVP: readable spoil at the
   release point, but no heightfield addition, collision or authoritative mass.
6. Retain the old solver only as rollback until human acceptance, then remove the
   rejected simulation lifecycle in a separate cleanup.

This trades physical fidelity and conservation for the requested clean cut,
bounded work and much smaller failure surface.
