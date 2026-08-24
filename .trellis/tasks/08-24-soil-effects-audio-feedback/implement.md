# Implementation plan

1. [x] Extend the selected soil visual snapshot with immutable transaction,
       ledger, bucket, and interaction identities for presentation dedupe.
2. [x] Upgrade bucket fill, grains, clods, and contact dust with bounded pools,
       shaded irregular geometry, lifecycle cleanup, and quality budgets.
3. [x] Add procedural engine/track/work loops and pooled lifecycle/soil/impact
       cues derived from normalized gameplay state, not hydraulic simulation.
4. [x] Add runtime Machine/Effects mix buses, config defaults, HUD mute/state,
       graceful dummy-device behavior, and reset/focus/model teardown.
5. [x] Add focused non-listening audio/effect contracts for caps, rate limits,
       clamps, dedupe, mute, lifecycle cleanup, and authority invariance.
6. [x] Run focused visual/offline regression and one completion gate, update the
       frontend boundary, commit, and archive. Defer subjective mix/effect
       approval to final human product-experience validation.

## Risk and rollback

- Generators and voices are allocated once; physics ticks update scalar targets
  only. No per-event player/resource allocation is allowed.
- Audio failure or mute cannot disable state information or visual feedback.
- Every soil cue requires selected-ledger or accepted batch/transaction identity;
  visible clods and sound voices never become material representation.
