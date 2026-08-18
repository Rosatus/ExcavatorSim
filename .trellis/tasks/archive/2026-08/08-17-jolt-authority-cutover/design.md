# Design

## Product Composition

The default launcher creates Godot SimulationCore/Jolt authority plus an optional
Python gateway process. Local physics remains functional if telemetry is absent;
external-control policy may deliberately stop commands when its gateway lease
expires. `MotionPresentation` consumes Jolt body/joint snapshots only.

The explicit legacy launcher retains current Python Simulator/Pinocchio -> v3 ->
MotionPresentation behavior and legacy optional workers. It never shares an active
session or transforms with the Jolt profile.

## Removal Boundary

In Jolt mode, remove/bypass:

- direct `TrackedLocomotionState` chassis transform writes;
- bounded visual bucket-ground lift as a physical substitute;
- Python `view_state` pose application;
- heuristic contact paths superseded by the accepted contact-to-soil transaction;
- observational shadow-only diagnostics no longer needed in production.

Retain test fixtures or compatibility adapters only when their ownership is explicit.

## Release And Rollback

Release evidence records versions, model/rig/calibration hashes, Godot/Jolt build,
performance budgets, known tuning limitations, and profile-specific start commands.
Rollback selects the explicit legacy launcher and starts a fresh session/world per
the documented compatibility policy; there is no live solver-state conversion.

