# Implementation Plan

1. Rename the primary protocol schema and update its namespace, protocol/state
   constants, version manifest, and backend path owner.
2. Update backend HTTP, RRD, and protocol-facing code plus focused tests and
   smoke fixtures for headers, MIME types, profiles, and version strings.
3. Update Godot protocol constants, handshake fixtures, and motion transport
   contract documentation.
4. Update current terrain/recording/integration docs and Trellis specs; leave
   historical provenance/migration references and the `babylon_sim` package
   unchanged.
5. Search for stale active Babylon identifiers and inspect the diff for
   accidental semantic changes.
6. Run focused backend protocol/web/RRD tests, Godot standalone protocol tests,
   `pixi run verify`, and backend smoke.

## Rollback points

- Before edits: protocol schema path and manifest are the only canonical
  version sources.
- After implementation: revert the single coherent migration commit if any
  cross-layer check fails; do not add compatibility aliases independently.
