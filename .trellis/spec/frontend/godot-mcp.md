# Godot MCP Development Tool

Godot MCP is an optional development-time adapter for inspecting and authoring the Godot client. It is not a runtime dependency and must never become an alternate source of simulator authority.

## Scope / Trigger

Use this guide when a task edits or validates `godot/client/` through the connected Godot editor. Read-only inspection should happen before scene or script edits.

## Connection Check

Call the editor state operation:

```json
{"op":"state"}
```

through `mcp__godot_ai__editor_manage`. A successful connection returns a structured result containing at least `godot_version`, `project_name`, `readiness`, `current_scene`, and `game_status`. Record the observed project name/version when reporting a connection test. `readiness: "no_scene"` means the MCP connection works; it only indicates that no scene is open.

## Tool Boundaries

- Prefer read operations first: editor state, scene hierarchy, node properties, filesystem/resource inspection, and logs.
- Use scene/node/script/resource/UI tools only for an explicitly scoped implementation task.
- Keep scene paths project-relative (`res://...`) and target the active session unless a specific `session_id` is required.
- Use undoable authoring operations where available; inspect the result and the working-tree diff after writes.
- Treat `editor_reload_plugin`, editor quit, game launch, and other lifecycle operations as explicit user-authorized actions.

### Project settings gotcha

Some startup-sensitive settings, including `application/run/main_scene`, are intentionally rejected by the MCP `project_manage(settings_set)` safety guard. When a scoped task must change one, edit `project.godot` through the normal project change path, then validate with a headless Godot import/run or restart the editor before relying on the live settings cache. A stale live setting read is not evidence that the file change failed.

## Cross-Layer Contract

The MCP edits only the Godot presentation client. Python remains authoritative for joint state, terrain layers, bucket inventory, events, recording, replay, and lifecycle. MCP-assisted Godot code may consume HTTP/WebSocket snapshots and patches, but must not write authoritative transforms, terrain heights, bucket volume, or replay cursors back to Python.

## Validation & Error Matrix

| Condition | Required response |
|---|---|
| MCP call returns a transport/tool error | Stop authoring, report the error, and retry only after connection state is rechecked. |
| `readiness: "no_scene"` | Connection is healthy; open or create the intended scene before scene-specific operations. |
| No active Godot session | Do not guess a session; ask for the editor to be opened/reconnected. |
| Game helper is not ready | Do not use game evaluation; inspect editor state or stop/relaunch the game. |
| Stale terrain/replay generation | Discard the derived client update; never overwrite newer state. |
| Backend/protocol files changed | Run the backend `pixi run verify` gate and inspect protocol compatibility. |

## Good / Base / Bad Cases

- Good: call `editor_manage(state)`, confirm the project/session, inspect the scene, make one scoped undoable change, then verify the resulting file/diff.
- Base: use MCP only for read-only inspection while the Godot scene is still being designed.
- Bad: use MCP to make Godot physics authoritative, create a second terrain store, or launch broad destructive editor operations without explicit scope.

## Tests Required

- Connection smoke: `editor_manage(state)` succeeds and reports `project_name == "ExcavatorSim"`.
- Scene authoring: reopen/inspect the edited scene and verify the expected node paths and properties through MCP.
- Client lifecycle changes: exercise missing scene, reconnect, stale generation, reset, seek, and Return Live transitions where applicable.
- Cross-layer changes: run `pixi run verify`; preserve protocol schema/version and deterministic backend tests.

## Wrong vs Correct

### Wrong

Use Godot MCP to write a locally simulated pose or terrain height back into the Python service as if it were authoritative.

### Correct

Use MCP to create or inspect the Godot presentation nodes, consume the Python snapshot/patch, and discard or rebuild derived state when the authority generation changes.

## Design Decision

Godot MCP is documented as a development tool rather than a product dependency. This keeps editor automation replaceable while preserving the Python authority and the existing HTTP/WebSocket compatibility boundary.
