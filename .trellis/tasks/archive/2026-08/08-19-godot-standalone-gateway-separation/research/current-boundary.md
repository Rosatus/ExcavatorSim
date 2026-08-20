# Current boundary evidence

## Confirmed facts
- `project.godot` already selects Jolt and `jolt_authoritative`; product motion/world implementation is local.
- `MotionClient` defaults auto-connect/reconnect, starts HTTP capability preflight, and uses port 8765.
- `OperatorUI` sends lifecycle/model commands through `MotionClient` and displays `Authority: waiting for Python` when transport identity is empty.
- `TrackedChassisController` steps Jolt locally but obtains equipment axes from `MotionClient`; motion is not consistently gated by displayed remote lifecycle.
- `MotionPresentation` already loads both packaged model contracts locally; tests activate them without backend assets.
- `SimulationTruthPublisher` builds local authoritative truth, but transport identity/sensor forwarding are tied to `MotionClient`.
- `pixi run start` starts Python gateway-only; gateway does not construct Pinocchio, but `pinocchio` remains unconditional in the Pixi environment.

## Conclusion
The missing unit is a Godot-local control plane, not a second motion solver. Making the socket optional without moving lifecycle/model/identity ownership leaves contradictory UI and unsafe stopped/pause behavior. The design inserts `ProductSession` above authority modes, keeps transport as an adapter, and separates Python launch/dependency surfaces.

## Prior non-goals
- Do not restore Python as product pose authority.
- Do not make Jolt own terrain deformation or bucket inventory.
- Do not replace bounded equipment kinematics with hydraulic dynamics.
- Do not delete legacy compatibility until a later explicit removal decision.

