# Implementation plan

1. [x] Define compartments, transaction schema, residuals, ordering, and hashes.
2. [x] Implement the sole-writer fixed-tick authority in shadow mode.
3. [x] Connect full-tool candidates to conservative field ↔ patch movement.
4. [x] Implement opening flux, bucket cells/capacity, overflow, and carry settle.
5. [x] Implement ledger debit to spill/dump and patch-to-field settlement.
6. [x] Adapt Jolt payload, truth, telemetry, and optional backend observations.
7. [x] Compare legacy and shadow journeys; diagnose rather than hide mismatches.
8. [x] Add transaction fault/rejection/reset/model/profile/20-cycle tests.
9. [x] Run focused, standalone, backend, task, and diff validation.

## Risk and rollback

- Never switch primary ownership inside this child; migration owns cutover.
- Do not let active representatives or legacy parcels independently credit or
  deposit shadow material.
- If a destination cannot accept the full transaction, retain/reject the exact
  residual at the source; never silently destroy it.
