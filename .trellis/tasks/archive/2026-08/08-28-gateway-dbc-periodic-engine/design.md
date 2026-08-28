# Design — Gateway DBC codec and periodic scheduler

## Catalog and identity

`DbcCatalog` resolves bundled, adjacent, and explicit roots, scans direct files,
normalizes paths, hashes bytes, and parses each unique content item through
`cantools.database.load_file(..., strict=True)`. A file DTO retains every source
location, SHA-256, parse notices, messages, and schema fingerprint. Exact byte
duplicates collapse; content-distinct files do not shadow each other.

Message keys combine the DBC content/schema fingerprint, normalized raw CAN ID,
extended flag, message name, DLC, and signal layout. Signal keys include name,
start, length, byte order, signedness, scale, and offset. These keys prevent
stale persistence from silently attaching to a changed layout.

Build a hash-bound `ProtocolDbcCatalog` from the approved bundled can3/can4
resources during Gateway startup. It is immutable for the process lifetime and
is the only catalog Godot semantic adapters may use. The operator catalog uses
the same parser/codec types but may be reloaded from bundled, adjacent, and
explicit roots; its reload disarms Web schedules without mutating the protocol
catalog.

## Drafts, persistence, and encoding

`DbcCodec` owns cached parsed messages and exposes metadata plus
`encode_message(key, physical_values)`. It rejects missing/non-finite/range
violations and performs strict `cantools` encoding. Generated drafts choose zero
when valid, else the finite bound nearest zero.

The persisted document is schema-versioned and atomically replaced in the
platform-standard user config directory. Restore is fail-closed: each key and
value is revalidated, incompatible records are ignored with notices, CAN-ID
conflicts restore disabled, and active sending is always false.

## Scheduler and load

`PeriodicDbcScheduler` lives inside `GatewayCore`. For each enabled message it
stores frequency, period, and next due monotonic timestamp. Start validates all
enabled drafts and platform readiness, seeds independent due times, and arms.
Each core tick emits at most once per due message and advances from current time
when late, preventing catch-up bursts. A rate change updates only that entry.

The load estimator uses normalized identifier type, DLC, frequency, frame
overhead, CRC/intermission, and documented worst-case stuffing assumptions at
250 kbit/s. It returns the numerical estimate, threshold category, and caveat;
it never participates in scheduler validation.

## Godot protocol adapters

The existing QML/Godot mapping continues deriving all physical semantics and
cadence. A `GodotRtkSignalAdapter` converts the existing RTK state into DBC
signal dictionaries for A000-A900, including gateway-provided time/status and
fixed zero undulation/padding values. A000-A700/A900 must reproduce current
manual payloads; A800 removes the QML-only big-endian override and follows the
DBC's little-endian definition.

A `GodotImuSignalAdapter` converts each reported `(roll, pitch, yaw)` into the
sensor-slot contract `Pitch_Angle=-pitch`, `Roll_Angle=roll`,
`Yaw_Angle=yaw`, plus reserved values that preserve current bytes. It retains
the existing protection against a raw all-zero triple. This adapter is specific
to Godot/reference-parser semantics; generic Web values are already expressed
as DBC physical signals and do not pass through it.

Both adapters call the same cached `DbcCodec.encode_message` used by Web DBC
transmission, then hand raw frames back to `GatewayCore`. Slew, travel, fixed
timed frames, and DBC messages without a Godot value source keep their existing
paths.

## API integration

Catalog, draft, conflict, persistence, scheduler, and load state are projected
into immutable core snapshots. Web mutation commands are atomic at message
granularity and revision checked. Start/stop/reload are core commands. Emission
returns structured success/failure into the shared one-second aggregation log.
