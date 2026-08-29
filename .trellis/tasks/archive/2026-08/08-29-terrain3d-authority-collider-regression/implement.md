# Implementation plan — Authority/collider regression

1. Define native-vs-fallback deterministic scenario/checkpoint schema.
2. Add terrain layer/digest, ledger, payload, truth, and query provenance capture.
3. Run both models through full soil, motion, lifecycle, and failure sequences.
4. Assert project collider/heightfield exclusivity with native collision disabled.
5. Investigate any divergence at the authority boundary; never adjust truth for
   visual parity.
6. Run complete terrain/collider/Jolt/soil/model/offline/release suites and
   repository verification.
7. Publish equivalence evidence required by the Phase 4 cutover gate.
