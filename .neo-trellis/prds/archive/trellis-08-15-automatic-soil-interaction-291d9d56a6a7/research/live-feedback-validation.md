# Live Optional Feedback Validation

Captured with the Godot AI MCP on 2026-08-15.

- Godot session: `client@c72d`, Godot 4.7.1, backend `127.0.0.1:8765`.
- `/api/capabilities` advertised protocol v3 and `bucket_load_feedback_v1`.
- Godot completed the unchanged required handshake and negotiated the optional
  capability only after HTTP preflight.
- Enabling `ExcavationWorld.backend_feedback_enabled` produced a backend health
  mirror with matching session, simulation epoch, model id/version,
  world/authority generations, monotonic client sequence, payload mass, center
  of mass, fill ratio, resistance, and quality.
- A synthetic automatic cut increased the mirrored payload to approximately
  `58.55 kg` and fill `0.03285`; disabling the feature clears the client sample
  and the server expires the latest value within the bounded `0.5 s` timeout.
- No terrain, replay, or articulation authority was changed by the feedback
  sample. Old hello clients remain on the required capability shape.

The server process and Godot editor were stopped after validation.
