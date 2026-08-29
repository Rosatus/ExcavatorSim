# Design — DBC decoding and bidirectional payload editing

## 1. Boundaries and data flow

The Gateway owner loop remains the only mutation and send authority. Neither
the aiohttp thread nor React performs CAN encoding as an authority.

```text
embedded/adjacent/--dbc-dir bytes
    -> SHA-256 dedup
    -> strict UTF-8-sig | strict CP1252 decode
    -> cantools load_string(strict=True)
    -> immutable catalog/native codec

React values or payload input
    -> local syntax/completeness check
    -> side-effect-free preview command
    -> owner-loop codec normalization
    -> preview response (payload + active values)
    -> explicit Save
    -> revision check + normalize + atomic persistence
    -> canonical draft payload
    -> scheduler entry -> existing Gateway send core -> TCP / SocketCAN
```

Godot telemetry continues using the separately constructed hash-bound protocol
codec. Operator reload may rebuild the mutable catalog but cannot replace the
already approved protocol authority.

## 2. DBC discovery and text decoding

Keep current raw-byte SHA-256 grouping and source sorting. Remove only creation
of the `dbc_duplicate_collapsed` notice; retain the complete `sources` tuple on
the single `DbcFileDefinition`.

Add one strict byte-to-text helper:

1. Decode with `utf-8-sig`, strict errors. This accepts UTF-8 with or without a
   BOM and strips only a leading BOM.
2. On `UnicodeDecodeError`, decode with `cp1252`, strict errors.
3. If CP1252 succeeds, attach one `dbc_encoding_fallback` notice to the file.
4. If both fail, raise a bounded parse error naming the attempted encodings and
   byte offset, without embedding file contents.
5. Parse through `cantools.database.load_string(text,
   database_format="dbc", strict=True)` so cantools cannot silently replace
   invalid bytes.

The helper consumes the same bytes already hashed, avoiding a second mutable
file read between identity calculation and parsing. Hash validation for the
approved protocol DBC remains before codec use.

## 3. Canonical draft representation

Change `DbcDraft` to own exact `payload: bytes`, `enabled`, `frequency_hz`, and
the existing generated/migration metadata. `values` is decoded from `payload`
when normalizing a command or building a snapshot; it is not a second persisted
authority.

Add codec operations with stable errors:

- `decode(message_key, payload) -> dict[str, float]`: enforce exact DLC, decode
  with scaling and numeric choices disabled, expose only the active mux branch,
  and reject non-finite results as `dbc_decode_failed`.
- `preview_payload(message_key, text)`: parse strict hex, decode, and return
  normalized uppercase spaced hex plus physical values.
- `preview_values(message_key, base_payload, values)`: validate/merge active
  values, encode through cantools, merge modeled bits into `base_payload`, then
  decode the result and return both views.

For a values edit, compile masks from DBC signal start, length, and byte order
using one tested utility. With an unchanged multiplexor, write only the common
and active-branch signal bits so inactive branch bytes from a raw payload remain
intact. When a multiplexor changes, include the complete signal union controlled
by that selector so stale old-branch bits are cleared. Merge as:

```text
result = (base_payload & ~selected_signal_mask) |
         (fresh_encoded_payload & selected_signal_mask)
```

The switch mask covers the multiplexor and all of its branch signals. A fresh
strict encode therefore clears stale modeled bits only when the selected branch
changes, while inactive-branch bits survive unrelated edits and bits outside the
union always retain the exact operator-authored value. Intel and Motorola mask
construction receive byte-level golden tests; no private cantools codec fields
become a runtime dependency.

## 4. Mutation and preview API

Keep `PUT /api/v1/dbc/messages/{message_key}`. Its body may contain either
`values` or `payload_hex`, plus `enabled`, `frequency_hz`, `expected_revision`,
and `request_id`. Supplying both edit forms returns
`dbc_edit_source_conflict`. Omitting both is valid for a control-only update.

Add `POST /api/v1/dbc/messages/{message_key}/preview` with:

```json
{
  "values": {"VelE": 1.25}
}
```

or:

```json
{
  "payload_hex": "7D 00 00 00 00 00 00 00"
}
```

It accepts exactly one edit source, requires standalone mode, runs through the
owner-loop codec command without a mutation revision check, and returns the
normalized payload and values. It does not save, update the scheduler, mutate
revision, emit configuration/send events, or change armed state. Request rate is
bounded by frontend debounce and normal Web command-queue limits.

The Save path stages a complete candidate, atomically persists it, then swaps
the in-memory draft and scheduler entry before publishing one new revision.
Every parse/decode/encode/config-write failure leaves all prior state intact.

## 5. Persistence and migration

Advance the DBC config schema and persist uppercase compact `payload_hex` (the
storage form need not preserve UI whitespace), `enabled`, and `frequency_hz`.
On schema-1 input:

- resolve only an unchanged message key/layout;
- validate and encode its stored values against a zero/default base;
- use the resulting payload as the canonical migrated draft;
- retain enabled/frequency only if the full candidate validates;
- otherwise use generated defaults and emit `dbc_restore_ignored`.

Armed state remains absent from storage. Reload still disarms first and rebuilds
drafts against the new catalog. Raw payload is never truncated, padded, or
carried across a changed layout/DLC.

## 6. React interaction

The message editor keeps separate local text state for signal fields and the
payload field plus an explicit selected edit source. Payload accepts compact
hex or whitespace-separated byte pairs and displays normalized uppercase pairs
after preview/save.

Local validation prevents requests for incomplete/non-hex/wrong-length input.
Once complete, a short debounce submits a preview. A generation token or abort
controller ensures late responses cannot replace a newer edit. Values preview
uses the same endpoint so payload generation and reserved-bit behavior are not
reimplemented in TypeScript.

Preview updates the opposite view but never invokes Save automatically. Save
sends only the selected edit source with the current expected revision.
Background refreshes use the atomic status+DBC endpoint and do not overwrite
unsaved local text; preview generations prevent late responses from replacing a
newer edit. Managed mode continues rendering status/catalog without any editing
or preview controls.

## 7. Compatibility and observability

- No frame ID, DLC, byte order, scale, EFF packing, rate, or transport changes.
- Periodic entries continue holding immutable bytes; rate-only updates reuse the
  canonical payload without re-encoding values.
- Duplicate collapse becomes silent, but source paths remain visible in the
  catalog for diagnostics.
- CP1252 fallback is a bounded per-file notice; successful UTF-8 creates none.
- Validation errors use stable 4xx codes and bounded details; no raw DBC content
  or traceback is returned.
- Existing event aggregation remains unchanged. Preview does not enter the
  operational/send log stream.

## 8. Rollback and risk controls

The primary risk is incorrect Motorola/multiplexed signal masking. Keep mask
logic isolated behind byte-level tests and compare normal value encoding against
cantools golden output before enabling payload preservation. If the new draft
schema fails validation, the runtime must ignore it rather than partially load.

Rollback is code-only: the old values-only schema remains readable during the
migration release, and neither DBC files nor CAN wire contracts are rewritten.
Rebuilding Windows and Linux packages is required because Python and Web bundle
contents change; the DBC copies themselves remain byte-identical.
