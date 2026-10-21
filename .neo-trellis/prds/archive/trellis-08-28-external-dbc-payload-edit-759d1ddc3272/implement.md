# Implementation plan — DBC decoding and bidirectional payload editing

## 1. DBC parsing and duplicate hygiene

- Add strict UTF-8-sig/CP1252 byte decoding and parse via cantools
  `load_string`; retain per-file isolation and raw-byte hashes.
- Stop emitting exact-duplicate notices while retaining all source paths.
- Add focused UTF-8 Chinese, CP1252 fallback, undecodable-byte, exact-duplicate,
  same-name-different-content, hash-bound protocol, and parse-isolation tests.

## 2. Codec and canonical payload draft

- Add strict raw-hex parsing, payload decode, finite-value validation, and
  stable error codes.
- Add tested Intel/Motorola signal masks and mux-aware values-over-base-payload
  merge: preserve inactive branches until selector change, then clear the old
  branch union.
- Change drafts, snapshots, scheduler updates, load estimate inputs, and config
  persistence to canonical payload bytes with derived active values.
- Implement schema-1 values migration and new payload schema restore behavior.
- Cover exact round trips, unmodeled bits, mux branch switching, invalid DLC,
  invalid mux/decode, rate-only updates, active scheduler updates, reload, and
  restart persistence.

## 3. Owner-loop and HTTP contracts

- Extend the existing message update command with mutually exclusive `values`
  and `payload_hex` content edits while preserving control-only updates.
- Add a side-effect-free, owner-serialized preview command and standalone-only
  HTTP endpoint without mutation revision coupling and with bounded stable errors.
- Prove preview has no revision/persistence/scheduler/log side effects and that
  failed Save operations cannot partially mutate state.
- Extend request-ID, stale-revision, managed-mode, JSON/type validation, and
  process-level PC001 payload tests.

## 4. React synchronized editor

- Extend shared API/DTO types and fixtures for canonical/normalized payload and
  preview responses.
- Add fixed-width payload input, local completeness/DLC validation, debounced
  cancellable preview, selected edit source, opposite-view synchronization,
  explicit Save, and stale refresh behavior.
- Keep managed mode read-only and retain existing enable/rate/start/stop/load
  controls.
- Run lint, TypeScript checks, component tests, and rebuild production assets.

## 5. Documentation, packaging, and full verification

- Update Gateway README and backend CAN Gateway spec with strict DBC encoding,
  silent exact deduplication, canonical payload, preview, Save, and persistence
  contracts.
- Rebuild Windows and Linux distributions; verify both still embed approved DBC
  resources and include byte-identical adjacent copies plus the current Web
  bundle.
- Run focused Gateway tests, full `unittest`/pytest suites, Web lint/typecheck/
  tests/build, `pixi run verify`, provenance/standalone checks, and packaged
  smoke tests on both executable formats.
- Inspect final diff for accidental CAN byte, transport, scheduler, Godot, CSV,
  or timed-frame changes before commit.

## Risk and rollback points

- Land parser/dedup changes independently from draft/API/UI changes so failures
  are bisectable.
- Treat signal-mask golden failures as a stop condition; do not weaken reserved-
  bit or Motorola assertions.
- Preserve user-owned unrelated dirty paths and do not add generated build
  scratch directories to Git.
