# Recording HTTP API V1

The same-origin recording API is owned by `protocol/recording-http-v1.schema.json`. JSON integer
timestamps are monotonic elapsed nanoseconds inside one `recording_epoch`; they are not Unix time.

- `GET /api/recording/series` accepts an allowlisted comma-separated `fields`, ordered `from_ns` /
  `to_ns`, and `max_points` from 1 through 4096. Results are clipped to a stable buffer snapshot and
  carry recording, buffer, and end-sample identities. Each numeric curve is a min/max envelope.
- `GET /api/recording/export` requires `X-Godot-Pinocchio-Session` and returns the finalized retained
  timeline as `application/octet-stream` with a `.rrd` attachment. Only one exchange operation runs
  at once.
- `POST /api/recording/import/validate?expected_recording_epoch=...` requires the same session
  header and streams a raw RRD body up to 256 MiB. It returns a five-minute, single-use staged token
  without changing the active timeline.
- `POST /api/recording/import/commit` accepts only `{token, expected_recording_epoch}`. Commit is the
  destructive confirmation boundary and atomically enters Imported/Paused at the first sample.
- `DELETE /api/recording/import/{token}` consumes staging without mutating the timeline.

WebSocket protocol v3 remains the owner of live `recording_status`, `view_state`, playback commands,
the aligned `terrain_view`/`terrain_patch`, and terrain apply/reset acknowledgement. RRD v1 remains
motion-only: a committed import installs a new flat read-only terrain epoch at revision zero, while
Return to Live creates fresh recording and editable terrain epochs. HTTP range and terrain snapshot
responses must be rejected by the browser when their epoch or local request generation is stale.
