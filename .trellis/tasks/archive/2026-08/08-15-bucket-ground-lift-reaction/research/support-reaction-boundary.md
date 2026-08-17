# Support Reaction Boundary Assessment

- The project currently has no dynamic excavator `RigidBody3D`, free-flyer Python
  chassis state, vehicle mass distribution, or hydraulic effort model.
- The visual hierarchy can accept a whole-machine parent offset, so bounded heave,
  pitch, and roll are feasible without rewriting articulated pose authority.
- Jolt terrain contact is currently a derived query over accepted terrain snapshots;
  it cannot become the owner of terrain deformation or chassis state in this task.
- A visual/kinematic support reaction therefore gives the requested cue with low
  architectural risk. Full force feedback and physically stable lifting require a
  later mobile-base dynamics task after aggregate contact telemetry is validated.
