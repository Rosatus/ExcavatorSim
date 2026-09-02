# Design - authoritative dump and soil cycle

The parent design plus accepted foundation/cutting contracts are authoritative.

Bucket mass releases at a bounded per-tick rate only when opening orientation,
position, generation, zone inset, and local support are valid. The authority
maps mass through loose bulk density to a small union of smooth ellipsoid/path
deposits. Accepted SDF material change and bucket debit form one transaction.

A sparse chunk-aligned fixed-point material field stores stable mass, mobile
mass, and mobile compaction state per touched cell, atomically beside SDF in the
same authority. It distinguishes initial stable material from loose and
compacted deposits without becoming a second writer. Deposition fills measured
free volume with mobile mass, never reclassifies overlapping stable mass, and
merges repeated mobile deposits by a deterministic weighted compaction rule.
Only dirty surface neighborhoods enter the repose queue. Each fixed iteration
makes paired subtract/add transfers from slopes above the configured repose
angle, in canonical coordinate order, under strict voxel/block/iteration
budgets. It stops with remaining work queued rather than expanding globally.

Track compaction consumes accepted contact footprints and load, operates only
on loose flags, and changes density/shape under conserved mass and bounded rate.
Its dirty blocks use the same mesh/collision tickets as cuts and deposits.

Out-of-zone proposals fail before debit. Particles/clods are pooled presentation
events keyed by committed transaction ID. Re-excavation has no special path: the
existing cutter removes deposited SDF and credits the same bucket ledger.
