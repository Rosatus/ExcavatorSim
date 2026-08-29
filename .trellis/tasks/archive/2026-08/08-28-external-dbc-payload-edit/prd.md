# Embedded DBC hygiene and bidirectional payload editing

## Goal

Keep the approved embedded DBC as the protected protocol fallback while
silently collapsing byte-identical external copies, decode human-readable DBC
metadata without mojibake, and let a standalone operator edit either physical
signal values or the raw CAN payload while both representations stay
synchronized and only explicitly saved data reaches periodic transmission.

## Background

- Packaged Windows and Linux Gateways intentionally contain approved DBC files
  twice: embedded under `resources/dbc` for the hash-bound Godot protocol codec,
  and beside the executable under `dbc/` for operator discovery and replacement.
  Exact duplicates are already collapsed by SHA-256, but currently emit a noisy
  `dbc_duplicate_collapsed` notice (`tools/can_gateway/dbc_engine.py:198-265`).
- The approved DBC files are UTF-8. cantools 40.7.1 defaults `.dbc` input to
  CP1252 and reads with replacement error handling, so the current unqualified
  `load_file(..., strict=True)` corrupts Chinese units such as
  `g/重力加速度` (`tools/can_gateway/dbc_engine.py:239`).
- The current operator draft persists physical `values`; `payload_hex` is
  re-encoded only for snapshots (`tools/can_gateway/dbc_engine.py:371-417,
  633-649`). That representation cannot preserve nonzero DBC-unmodeled bits
  after accepting an operator-authored raw payload.
- Web mutations already run through one Gateway owner loop with request-ID
  idempotency and optimistic configuration revisions. Periodic scheduling uses
  immutable payload bytes, so a validated canonical payload can extend the
  existing path without creating another sender.

## Requirements

### DBC sources and diagnostics

- Retain both approved embedded DBC files and the byte-identical copies placed
  in each distribution's executable-adjacent `dbc/` directory.
- Continue non-recursive discovery of embedded, adjacent, and explicit
  `--dbc-dir` roots. Collapse byte-identical SHA-256 content into one catalog
  definition and retain every source path, but do not emit a duplicate notice.
- Files that share a name but differ in bytes remain distinct. Existing parse
  isolation and normalized CAN-ID conflict handling remain visible.
- Keep the embedded hash-bound protocol codec independent from mutable operator
  reloads so external files cannot silently change Godot telemetry encoding.

### Character decoding

- Decode DBC bytes strictly as UTF-8 with optional BOM first. If that fails,
  decode strictly as CP1252 and emit one non-blocking encoding-fallback notice
  for that file.
- Parse the successfully decoded text through cantools strict DBC parsing.
  Never rely on cantools replacement-character decoding.
- If neither UTF-8 nor CP1252 can decode the bytes, report an isolated
  `dbc_parse_failed` diagnostic describing the attempted encodings; other valid
  catalog files remain usable.
- Raw bytes remain the SHA-256 identity, so encoding selection must not change
  deduplication, protocol hashes, message keys, or persisted-layout isolation.

### Canonical payload and synchronized editors

- Apply bidirectional editing only to DBC catalog messages in standalone mode.
  Dedicated non-DBC slew, travel, and timed frames remain outside this editor.
  Godot-managed mode remains read-only in both the UI and API.
- Store the exact payload bytes as the canonical per-message draft and derive
  displayed physical values by strict DBC decode.
- A physical-values edit encodes the selected values according to the DBC and
  updates only DBC-modeled bits in the canonical payload. Preserve all bits not
  modeled by any signal. When a multiplexor branch changes, clear stale modeled
  bits from inactive branches while preserving bits outside the complete signal
  union.
- A raw-payload edit replaces the canonical payload exactly after validation,
  then decodes and displays the active physical signal values.
- A content mutation may contain `values` or `payload_hex`, never both. Pure
  enablement/frequency updates may omit both. Continue using expected revision,
  request-ID idempotency, one owner-loop transaction, atomic persistence, and a
  single revision increment.
- Require an exact-DLC payload. Accept compact hexadecimal or whitespace-
  separated byte pairs, normalize display to uppercase space-separated bytes,
  and reject prefixes, odd digits, non-hex text, truncation, and excess bytes.
- Reject a payload that cantools cannot strictly decode, selects an invalid
  multiplexor, or yields a non-finite physical value. A rejected edit changes
  neither memory, persistence, scheduler payload, armed state, nor revision.
- Persist canonical `payload_hex`, enabled state, and frequency in a new config
  schema. Migrate a valid legacy values-only draft by encoding it once; ignore
  incompatible legacy entries with the existing restore notice behavior.

### Web interaction

- Show a fixed-width hexadecimal payload editor alongside the physical signal
  editor for each DBC message.
- While either editor contains a complete locally valid input, request a
  debounced server-side preview using the same codec. Preview is serialized by
  the owner loop but is independent from mutation revisions.
  Preview never persists, schedules, logs a send, or increments revision.
- A valid payload preview updates the displayed physical values; a valid values
  preview updates the displayed payload. Partial or invalid input shows a local
  actionable error and leaves the last valid preview visible.
- Only the existing explicit Save action commits the selected editor's content.
  The successful owner-loop snapshot becomes the authoritative displayed state.
- Enabling, frequency changes, start/stop behavior, estimated bus load, and
  transport readiness remain unchanged.

## Acceptance Criteria

- [x] Windows and Linux packages retain approved embedded DBC resources and
  byte-identical executable-adjacent DBC copies.
- [x] Exact duplicates from any discovered roots collapse to one definition
  with all `sources` retained and no `dbc_duplicate_collapsed` notice; differing
  bytes remain independently visible.
- [x] Representative approved Chinese units render exactly as UTF-8 text, a
  valid CP1252 fixture loads with one fallback notice, and undecodable bytes
  fail only their file without replacement characters.
- [x] Protocol hashes, 27 approved messages, source identity, parse isolation,
  and Godot/Web byte authority remain unchanged by the decoding fix.
- [x] Editing valid physical values previews and saves the exact DBC payload;
  editing a valid exact-DLC payload previews and saves matching physical values.
- [x] Preview is server-authoritative but side-effect free; incomplete input is
  never submitted and Save is the only operation that mutates the draft.
- [x] Compact and spaced hexadecimal are accepted and displayed as normalized
  uppercase byte pairs; malformed or wrong-length input is rejected atomically.
- [x] Repeated value/payload edits have deterministic last-valid-save-wins
  behavior, preserve unmodeled bits, and correctly clear inactive multiplexed
  branch bits.
- [x] A raw payload with nonzero unmodeled bits survives save, rate-only updates,
  scheduler transmission, Gateway restart, and snapshot round trips unchanged.
- [x] Legacy values-only configuration migrates without changing valid encoded
  bytes; incompatible entries remain disabled/defaulted with a notice, and
  armed state is still never restored.
- [x] API authorization, stale revision, request replay/conflict, validation,
  persistence failure, and active-scheduler update tests prove failed mutations
  cannot partially commit.
- [x] React tests cover live preview, local validation, explicit Save, stale
  refresh, managed-mode read-only rendering, and values/payload synchronization.
- [x] Existing DBC encoding, CAN IDs/DLC/EFF packing, periodic cadence, bus-load
  estimate, Godot telemetry, timed frames, CSV, Windows PC001, Linux SocketCAN,
  Web logs, and transport lifecycle retain their established semantics.

## Out of Scope

- Editing or writing DBC schema definitions.
- Raw editing for dedicated non-DBC slew, travel, or timed frames.
- CAN receive/decode monitoring.
- Changing CAN IDs, DLC, signal layout, scaling, byte order, frequency limits,
  transport selection, or Godot semantic adapters.
- Adding configurable GBK/Shift-JIS/system-locale decoding. Additional legacy
  encodings require a future explicit allowlist and diagnostics contract.

## Key Decisions

- Embedded DBC remains the protected protocol fallback; only exact-duplicate
  notification noise is removed.
- DBC text decoding is strict UTF-8-first with strict CP1252 fallback.
- Payload bytes, not physical values, become the canonical persisted draft.
- DBC-modeled value edits preserve unmodeled payload bits.
- Both editing directions use side-effect-free server previews and explicit
  Save; no per-keystroke runtime mutation or client-side DBC codec is added.
