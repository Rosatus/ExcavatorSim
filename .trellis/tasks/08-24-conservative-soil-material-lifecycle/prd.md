# Conservative soil material lifecycle

## Goal and user value

Make cutting, loading, carrying, spilling, dumping, and settling one continuous
material process so visible excavation and bucket payload can no longer disagree.

## Dependencies

Requires the approved outputs of `08-24-full-bucket-soil-tool-contract` and
`08-24-local-active-soil-patch-prototype`.

## Requirements

- Introduce one generation-scoped fixed-tick authority for candidate validation,
  compartment deltas, capacity, transfer IDs, transaction journal, and snapshots.
- Track persistent stable/loose material, active patch, bucket cells, and
  released/settling material as explicit compartments with one conserved total.
- Derive cut/push/grade displacement from full-tool swept regions and the active
  field; circular tooth brushes cannot decide primary-mode material movement.
- Credit material entering the bucket through its opening in the same accepted
  transaction. Capacity, overflow, fill distribution, mass, and center of mass
  come from the one bucket ledger.
- Debit that ledger for gravity spill/dump, seed active material with bucket point
  velocity, and settle it back through the persistent-field scheduler.
- Publish immutable transactions and compact snapshots for Jolt payload,
  truth/telemetry, HUD, VFX, audio, tests, and optional backend observations.
- Retain legacy ownership unchanged behind `legacy`; implement the new chain in
  `shadow` before it can become `active_patch` at a later migration boundary.

## Acceptance criteria

- [ ] Every accepted transaction balances source and destination deltas within
      `max(1e-6 m³, 0.1% of accepted moved volume)` and has a unique stable
      generation-scoped ID.
- [ ] Real fixed-step SY205 and SY135 cut → scoop sequences reach nonzero payload
      without parcel coincidence or test-only credit.
- [ ] Partial/full capacity, rejection, overflow, carry, side spill, dump, and
      settle preserve the aggregate total and produce coherent bucket cells,
      mass, center of mass, and terrain revisions.
- [ ] Twenty repeated dig/carry/dump cycles have final unexplained drift no
      greater than `max(1e-5 m³, 0.5% of one bucket capacity)`.
- [ ] Quality profile and visual representative counts do not change accepted
      transfers, bucket payload, or final terrain within tolerance.
- [ ] Reset, disable, model/authority switch, rejection, capacity exhaustion,
      and patch allocation failure leave no open/double-applied transaction.
- [ ] Truth, Jolt applied payload, optional backend observation, and presentation
      snapshots converge on the same ledger identity without mixed old/new mass.
- [ ] Focused transaction, both-model journey, lifecycle, and full regression
      gates pass in legacy and shadow modes.

## In scope

Authority state machine, transaction journal, compartment ledger, full-tool
material displacement, bucket entry/capacity/fill, spill/dump/settle, payload and
read-only snapshot adapters, shadow comparison, tests, and specs.

## Out of scope

Game-feel speed reduction, final visual/audio polish, professional soil-force or
hydraulic calculations, removal of legacy code, or mid-scoop authority migration.
