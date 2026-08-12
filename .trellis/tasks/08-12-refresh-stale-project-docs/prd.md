# Refresh stale project documentation

## Goal

Synchronize the project's active documentation with the implemented Godot M1–M7
vertical slice so that a new contributor is not told that the Godot client is
still deferred or that the repository contains only a migration bootstrap.

The user value is an accurate, low-friction project entry point that preserves
the established Python-motion/Godot-local-world boundary and distinguishes
legacy compatibility capabilities from the current Godot-first client.

## Requirements

- R1 — Update `README.md` to describe the current Windows Godot Forward+ client,
  the Python motion/input authority, the Godot-owned local world/presentation
  responsibilities, the retained legacy Python terrain/recording/replay
  profile, the current repository map, and the principal verification entry
  points. The stale bootstrap claims are evidenced at `README.md:3-7,24-26`.
- R2 — Update `.trellis/spec/frontend/index.md` so its maturity wording matches
  the implemented client and its integration-document reference points to the
  existing `docs/godot-integration.md`, not the removed task-local path at
  `.trellis/spec/frontend/index.md:3,11`.
- R3 — Update `docs/godot-integration.md` from future-tense planning language to
  current implementation language where the described motion, local terrain,
  and presentation behavior is already implemented. Preserve explicit
  deferred items and the compatibility/authority boundaries; do not redesign
  the protocol or change historical asset/provenance terminology.
- R4 — Keep historical records, provenance notices, backend module/package
  names, and third-party addon/demo content out of scope unless a sentence is
  directly asserting that the current client does not exist.
- R5 — Keep the changes documentation-only and Markdown-valid; do not modify
  source code, schemas, generated Godot metadata, or unrelated dirty files.

## Acceptance Criteria

- [x] `README.md` no longer describes the Godot client as intentionally deferred
      or `godot/` as reserved for a future client.
- [x] The frontend spec index names the current client state and links to the
      existing integration document path.
- [x] The integration document accurately describes implemented motion and
      Godot-first local-world behavior while retaining genuinely deferred
      production-grade physics/authority work.
- [x] A repository search confirms no stale future/bootstrap wording remains in
      the three in-scope documents, apart from intentionally historical or
      compatibility-scoped language.
- [x] `git diff --check` passes, and no files outside the three documents plus
      this task's PRD are changed by the implementation.

## Validation Record

- `pixi run verify` passed: Ruff, mypy, 145 backend tests, provenance
  verification, and standalone-path verification.
- `git diff --check` passed; the only output was the repository's existing
  LF-to-CRLF warning on touched tracked files.
- Scoped stale-wording search returned no matches, and
  `docs/godot-integration.md` exists while the obsolete task-local path does
  not.

## Confirmed Evidence

- The archived realistic-client task records the split-authority architecture
  and completed acceptance gates in
  `.trellis/tasks/archive/2026-08/08-10-godot-realistic-client/prd.md:3-5,91-95`.
- The current Godot scene contains the SY205 instance, motion scripts, terrain
  world, excavation world, and operator UI at
  `godot/client/scenes/main.tscn:57-118`.
- The latest journal records the completed terrain-winding fix and current
  session status at `.trellis/workspace/rosatus/journal-1.md:556-586`.

## Out of Scope

- No source, protocol schema, runtime behavior, asset bytes, or generated UID
  changes.
- No cleanup or rewrite of intentional BabylonSim provenance/history text.
- No new product requirements, architecture changes, or new Trellis child
  tasks.

## Planning Status

- Lightweight task; PRD-only planning is sufficient.
- Blocking open questions: none.
