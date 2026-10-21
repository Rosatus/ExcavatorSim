# SY80U native bucket soil and cutting

User request: fix protruding contained-soil slab and cutting/collision geometry on 80U ordinary bucket.

Root causes: stale rim coordinates in legacy fill profile; cavity axes along mouth length; native cutter excludes SY80U.

Implement: measured inner-mouth + lining via shared baker (native catalog support), aligned contact regions, native cutting. Preserve original GLB, joint frames, capacities, authority ledger and unrelated gateway edits.

Agent automated: deterministic bake, mesh containment at low/full stock, cutter deep/exit/negative checks and relevant shared regressions.
Human manual: switch SY80U + ordinary bucket, dig/curl/carry/dump; verify soil remains inside shell and continuous cuts leave no thin wall. Pending.
