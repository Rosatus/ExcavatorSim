# Design — Gateway React console and distribution

## Frontend structure

Place the Vite project under `tools/can_gateway/web/` and keep generated output
under the Gateway resource tree consumed by `qml_profile.resource_root()` and
PyInstaller. Use a small typed API client, shared DTO definitions generated or
contract-tested against Python fixtures, and a query/state layer that treats the
server revision as authoritative.

Primary views:

- header and status cards: mode, platform, Web URL, transport/handshake/can0,
  scheduler, catalog revision, and latest error;
- standalone platform transport card: Windows endpoint apply or Linux confirmed
  restart, never both;
- DBC file/message table with source/hash/error/conflict state, enable toggle,
  integer Hz field, and estimated contribution;
- signal editor with unit/range/scaling/generated-default status and strict
  payload preview;
- global start/stop, reload, total load meter with normal/yellow/red thresholds;
- virtualized or bounded aggregate/event log with current/archive downloads.

Managed mode builds its available navigation from server capabilities and omits
all mutation routes. All mutations still handle `403`, `409` revision conflict,
validation errors, transport transitions, and reconnect refresh.

## Live updates

Load an initial status/catalog snapshot, then attach the WebSocket with the last
seen sequence. Apply only ordered events and refresh snapshots after a revision
change or detected sequence gap. Reconnection uses bounded backoff and clearly
marks stale/offline state. Rendering never assumes one event per physical frame.

## Build and packaging

Use `npm` with a committed lockfile. Development/release build scripts run
`npm ci` and `vite build`, then fail if the expected `index.html` and hashed
assets are absent. PyInstaller includes the resulting resources; Node modules
and the Node runtime are not included.

Copy the approved DBC files byte-for-byte into `tools/can_gateway/resources/dbc`
and each distribution's adjacent `dbc/` folder. Add entries to
`assets/provenance.json` as user-supplied approved assets with source paths,
sizes, raw SHA-256 hashes, destinations, and import date.

The Windows package remains a Gateway executable plus adjacent DBC directory.
The Linux package retains gateway, can0 helper, installer/uninstaller, and adds
the adjacent DBC directory. Static Web assets may be internal to onefile, but
adjacent DBCs remain operator-visible as explicitly requested.
