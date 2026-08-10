# Technical Design

## Profile boundary

`RuntimeController` gains a typed `RuntimeProfile` with the default
`legacy` profile and an explicit `motion-only` profile. The profile is selected
by the CLI flag `--runtime-profile motion-only` (and a matching pixi task) or by
direct construction in tests. The default constructor path remains the current
legacy composition.

```text
legacy:      Simulator + InputRouter + recording buffer + TerrainController
             + ReplayWorker + RecordingExchange
motion-only: Simulator + InputRouter + LatestStateSlot + motion view projection
```

The motion-only projection is an in-memory adapter that presents the existing
schema-required `view_state` fields from the latest `RuntimeSnapshot`. Its
`recording_epoch`, view revision and cursor fields are diagnostics only. It does
not append samples, schedule terrain edits, create a replay thread, or stage RRD
imports.

## Runtime lifecycle

- Initialize the profile and optional services before the first publish.
- `_publish` always updates `latest`; legacy additionally appends to recording
  and submits the existing terrain edit stride. Motion-only instead publishes a
  schema-compatible `AuthoritativeViewState` into a local slot with
  `source_mode=live` and `playback_state=following`.
- `start` and `stop` operate on the fixed-rate runtime thread in both profiles.
  Legacy starts/stops replay and closes exchange/terrain; motion-only has no
  such calls. Both paths fail pending lifecycle futures with the same stable
  shutdown code.
- Reset changes `simulation_epoch` in both profiles. Disconnect clears input and
  command-cache state; legacy also cancels terrain/exchange session work.

## Web boundary

`web.py` derives server capabilities from the runtime profile. The hello
response intersects the client's requested capabilities with that set. The
state sender always emits `view_state`; it emits `terrain_view`/patch only for
legacy sessions. The status sender emits `recording_status` only when recording
is enabled. HTTP routes and WebSocket playback/terrain branches fail with
`capability_unavailable` before touching optional services.

All existing legacy route behavior and payload bytes remain unchanged. The
motion-only payload retains the existing protocol identifiers and required
fields so the M2 Godot reducer can consume it without a profile-specific wire
branch.

## CLI and compatibility

`cli.build_parser` accepts `--runtime-profile {legacy,motion-only}`. The default
is `legacy`; `pixi run start-motion-only` is an explicit convenience task. The
frontend directory requirement and loopback binding rules are unchanged.

## Rollback

The profile is opt-in and can be disabled by omitting the flag. If a compatibility
failure appears, the Godot client continues using the existing legacy service,
and the new profile code can be removed without changing schemas or legacy
terrain/replay modules.
