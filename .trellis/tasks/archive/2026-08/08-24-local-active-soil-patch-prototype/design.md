# Design — local active soil patch prototype

## Stable contract

The persistent side exposes logical material cells and conservative
activate/settle transactions through `TerrainCommitScheduler`. The active side
owns only generation-scoped temporary representatives. Aggregate volume and
material preset accompany every representative batch; visual count is free to
change with quality.

## Candidate implementations

Start with a fixed-grid/particle CPU reference because it is inspectable and can
serve low/fallback. Measure it before adding compute complexity. If it misses the
balanced budget or cannot produce convincing flow, implement the same patch
contract with a Godot `RenderingDevice` compute path and retain coarse CPU
behavior for unsupported hardware. GPU readback may publish aggregate reductions,
not per-particle state, to avoid fixed-step stalls.

## Shadow safety

Prototype activation uses copied/synthetic transfer inputs. It must never call
legacy bucket credit, release, or deposit methods. Comparison hashes confirm
that enabling it does not alter `TerrainState`, `BucketSoilState`, parcel pool,
or accepted equipment state.
