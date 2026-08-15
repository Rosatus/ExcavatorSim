# Locomotion Boundary Assessment

- Current Python state and protocol contain only swing, boom, arm, and bucket axes.
- `MotionPresentation` already writes the Python base transform, so locomotion cannot
  write that node directly.
- No current rigid-body chassis or tracked-vehicle controller exists.
- A local parent root is the smallest reversible design that keeps the terrain,
  camera, model, and bucket probes in one coordinate frame without widening the
  articulated-control protocol.
- A full Python-authoritative mobile base would require a new input/state schema,
  URDF free-flyer/chassis dynamics, reconnect/replay work, and latency handling. It
  is deferred until the local locomotion feel and contact contracts are proven.
