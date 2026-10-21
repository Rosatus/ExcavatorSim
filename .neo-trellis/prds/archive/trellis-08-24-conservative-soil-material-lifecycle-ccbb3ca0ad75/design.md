# Design — conservative soil material lifecycle

## Sole-writer transaction

`SoilInteractionAuthority.step_fixed()` consumes accepted pose/tool snapshots,
logical field/patch samples, prior bucket ledger, and generation identity. It
orders candidates deterministically, computes conservative deltas, validates all
destinations, commits atomically, and then publishes events. No presentation or
legacy callback may mutate an accepted primary-mode transaction afterward.

Each journal row records transfer ID, tick, generation, material preset, source,
destination, requested/accepted/rejected volume, world origin/velocity, and
resulting compartment identities. A residual accumulator retains sub-quantum
volume instead of dropping it.

## Bucket coupling

Opening flux comes from active material crossing the oriented opening into the
validated cavity while the semantic shell contains it. Accepted flux directly
fills coarse bucket cells. The active patch may display individual
representatives, but aggregate crossing is the authoritative measurement.
Release uses gravity-relative opening and motion conditions, debits cells first,
and produces matching active/released volume in the same transaction.

## Compatibility

Legacy and new state objects can coexist only while the new state is shadow and
read-only. Production ownership is selected once per generation. Adapters feed
existing Jolt payload and truth publishers from the selected ledger identity;
they must not combine new volume with legacy mass.
