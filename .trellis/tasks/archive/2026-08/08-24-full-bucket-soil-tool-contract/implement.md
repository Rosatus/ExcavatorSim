# Implementation plan

1. [x] Add versioned descriptor schema and SY205/SY135 region data.
2. [x] Add strict load-time validation and model-contract fixtures.
3. [x] Compose current/previous semantic regions from accepted bucket poses.
4. [x] Implement bounded swept primitives and deterministic candidate ordering.
5. [x] Implement read-only interaction classification and compact telemetry.
6. [x] Add opt-in non-colliding debug visualization and lifecycle cleanup.
7. [x] Prove shadow invariance against terrain, ledger, parcels, and motion.
8. [x] Run focused tests, standalone matrix, task validation, and diff check.

## Risk and rollback

- Keep all outputs behind the new descriptor/shadow feature flag.
- Do not add new Jolt collision layers or allow debug nodes into support queries.
- Invalid model data must disable the new classifier, not approximate another
  model's geometry.
