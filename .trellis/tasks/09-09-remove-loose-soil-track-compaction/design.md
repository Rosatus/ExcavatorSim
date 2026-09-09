# Technical design

## Product model
The authoritative soil lifecycle is cut → bucket ledger → direct stable slope deposit → later cut. A dump computes a bounded repose-angle shape and commits it immediately as stable terrain. No flight, mobile layer, compaction, or settle phase remains in the product path.

## Boundaries
Primary changes are under `godot/client/scripts` and `godot/client/tests`. Preserve voxel geometry, volume/mass accounting, bucket interaction, terrain commits, and re-cutting of deposited terrain.

## Approach
1. Trace call sites and schemas for `LooseSoilFluxSolver`, active/mobile soil, settle scheduling, and `submit_track_compaction`.
2. Replace dump landing lifecycle with one stable slope commit using existing repose geometry helpers where possible.
3. Remove producers/consumers of mobile, compaction, and settle state; simplify queue/transaction branches without changing cut/deposit accounting.
4. Keep legacy entry points as deterministic no-op/rejection when needed for old scenes.
5. Rewrite tests around immediate stable deposition, re-digging, and conservation; delete obsolete process tests and fixtures.

## Risks
The soil authority intertwines cut, deposit, settle, and compaction branches. Verify that removing process state does not remove material accounting or make deposited geometry non-diggable.
