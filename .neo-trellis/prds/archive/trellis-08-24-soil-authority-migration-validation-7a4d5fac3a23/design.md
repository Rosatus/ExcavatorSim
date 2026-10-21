# Design — soil authority migration validation

## Generation-level mode selection

ProductSession/model generation selects one immutable authority mode. A mode
controller constructs only the selected write adapters and asserts that cut,
bucket credit, release, and settle each have exactly one owner. Shadow objects
may compute candidates but receive read-only/copy interfaces.

Fallback is fail-closed within a generation: a primary-path failure pauses or
surfaces recovery, then reset creates a clean legacy generation. It never
silently resumes the old owner with live new-path material.

## Legacy parcel role

In active mode, the legacy parcel pool receives immutable visual spawn events or
is absent. Bodies have no bucket/terrain transfer callbacks and are disposable
on quality/lifecycle changes. In legacy mode, its current ownership and tests
remain intact.

## Evidence contract

Comparison manifests identify commit, mode, model, quality, hardware, checkpoint,
material totals, transaction/terrain/payload identities, response curve,
performance, error-log outcome, and screenshot/video hashes. Human review is
required for flow and pile quality; automated checks own conservation and
lifecycle truth.
