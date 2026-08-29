# Design — Snapshot lifecycle and presentation failover

Model presentation as explicit configured/active states instead of equating
adapter availability with ownership. The latest accepted snapshot is always
retained. Visibility changes only after successful native materialization or a
hard failure with a fully synchronized fallback.

Keep the existing full/patch decision rules and make recovery observable. A
patch may retry once as full. If full fails, roll queue gates back to the last
applied identity, synchronize fallback from the latest accepted snapshot, and
publish a typed fallback reason. Test Grid is a presentation override layered
above backend selection, not a mutation of the configured backend.
