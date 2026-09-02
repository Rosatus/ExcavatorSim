export type GatewayMode = "standalone" | "godot-managed";
export type CanChannel = "ch0" | "ch2" | "ch3";

export interface GatewayStatus {
  revision: number;
  mode: GatewayMode;
  platform: "windows" | "linux" | string;
  web_url: string;
  transport_kind: string;
  transport_state: string;
  transport_detail: string;
  recording: boolean;
  timed_can_active: boolean;
  ict_active: boolean;
  godot_connected: boolean | null;
  periodic_armed: boolean;
  tcp_host: string;
  tcp_port: number;
  can_interface: string;
  pc001_handshake: boolean;
  pc001_queued_frames: number;
  pc001_sent_frames: number;
  pc001_dropped_frames: number;
  socketcan_submitted: number;
  socketcan_sent: number;
  socketcan_congestion_dropped: number;
  socketcan_coalesced: number;
  socketcan_terminal_errors: number;
  socketcan_pending: number;
  event_sequence: number;
  event_earliest_sequence: number;
  log_dropped_records: number;
}

export interface DbcNotice {
  code: string;
  detail: string;
  source: string;
}

export interface DbcSignal {
  key: string;
  name: string;
  start: number;
  length: number;
  byte_order: string;
  is_signed: boolean;
  scale: number;
  offset: number;
  minimum: number | null;
  maximum: number | null;
  unit: string;
  is_multiplexer: boolean;
  multiplexer_signal: string | null;
  multiplexer_ids: number[];
  integer_only?: boolean;
}

export interface DbcMessageDefinition {
  key: string;
  file_sha256: string;
  name: string;
  frame_id: number;
  frame_id_hex: string;
  is_extended: boolean;
  length: number;
  channel: CanChannel;
  signals: DbcSignal[];
}

export interface DbcMessageDraft {
  message: DbcMessageDefinition;
  values: Record<string, number>;
  enabled: boolean;
  frequency_hz: number;
  generated_default: boolean;
  payload_hex: string;
}

export interface DbcPreview {
  values: Record<string, number>;
  payload_hex: string;
}

export type DbcContentEdit =
  | { values: Record<string, number>; payload_hex?: never }
  | { payload_hex: string; values?: never };

export interface DbcFile {
  sha256: string;
  sources: string[];
  messages: DbcMessageDefinition[];
  parse_error: string;
}

export interface LoadEstimate {
  bitrate: number;
  estimated_bits_per_second: number;
  percent: number;
  level: "normal" | "yellow" | "red";
  warning: boolean;
  caveat: string;
}

export interface DbcSnapshot {
  armed: boolean;
  catalog: { files: DbcFile[]; notices: DbcNotice[]; message_count: number };
  messages: DbcMessageDraft[];
  notices: DbcNotice[];
  load: LoadEstimate;
}

export interface GatewayEvent {
  sequence: number;
  timestamp: string;
  monotonic_s: number;
  kind: string;
  source: string;
  detail: Record<string, unknown>;
}

export type CanAuthority = "off" | "custom" | "simulation";

export interface CanConsoleRuntime {
  last_payload_hex: string | null;
  last_egress_monotonic_s: number | null;
  actual_frequency_hz: number | null;
  sample_count: number;
  source: string | null;
  authority: string | null;
  values: Record<string, number> | null;
}

export interface CanConsoleMessage {
  key: string;
  message: DbcMessageDefinition & {
    descriptor_fingerprint: string;
    kind: "dbc" | "native";
    dbc_key: string | null;
  };
  values: Record<string, number>;
  payload_hex: string;
  frequency_hz: number;
  authority: CanAuthority;
  expected_frequency_hz: number | null;
  simulation_capable: boolean;
  simulation_available: boolean;
  runtime: CanConsoleRuntime;
}

export interface CanConsoleSnapshot {
  catalog_fingerprint: string;
  custom_armed: boolean;
  server_monotonic_s: number;
  messages: CanConsoleMessage[];
  notices: Array<Record<string, unknown>>;
  load: LoadEstimate;
}

export interface CanConsoleProfile {
  format: "excavatorsim-can-console";
  schema_version: number;
  catalog_fingerprint: string;
  messages: Record<string, unknown>;
}

export type GatewaySocketMessage =
  | { type: "gap"; requested_after?: number; earliest_sequence?: number }
  | { type: "event"; event: GatewayEvent };

export function decodeGatewaySocketMessage(value: unknown): GatewaySocketMessage | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.type === "gap") {
    return {
      type: "gap",
      requested_after: typeof candidate.requested_after === "number" ? candidate.requested_after : undefined,
      earliest_sequence: typeof candidate.earliest_sequence === "number" ? candidate.earliest_sequence : undefined,
    };
  }
  if (candidate.type !== "event" || !candidate.event || typeof candidate.event !== "object") return null;
  const event = candidate.event as Record<string, unknown>;
  if (
    typeof event.sequence !== "number" ||
    typeof event.timestamp !== "string" ||
    typeof event.monotonic_s !== "number" ||
    typeof event.kind !== "string" ||
    typeof event.source !== "string" ||
    !event.detail || typeof event.detail !== "object"
  ) return null;
  return { type: "event", event: event as unknown as GatewayEvent };
}

export interface CanConsoleRuntimeDelta {
  server_monotonic_s: number;
  rows: Record<string, CanConsoleRuntime>;
  status: GatewayRuntimeStatusDelta | null;
}

export type GatewayRuntimeStatusDelta = Pick<GatewayStatus,
  | "transport_state"
  | "transport_detail"
  | "recording"
  | "timed_can_active"
  | "ict_active"
  | "godot_connected"
  | "periodic_armed"
  | "pc001_handshake"
  | "pc001_queued_frames"
  | "pc001_sent_frames"
  | "pc001_dropped_frames"
  | "socketcan_submitted"
  | "socketcan_sent"
  | "socketcan_congestion_dropped"
  | "socketcan_coalesced"
  | "socketcan_terminal_errors"
  | "socketcan_pending"
  | "log_dropped_records"
>;

function decodeRuntimeStatus(value: unknown): GatewayRuntimeStatusDelta | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  const stringFields = ["transport_state", "transport_detail"] as const;
  const booleanFields = ["recording", "timed_can_active", "ict_active", "periodic_armed", "pc001_handshake"] as const;
  const counterFields = [
    "pc001_queued_frames", "pc001_sent_frames", "pc001_dropped_frames",
    "socketcan_submitted", "socketcan_sent", "socketcan_congestion_dropped",
    "socketcan_coalesced", "socketcan_terminal_errors", "socketcan_pending",
    "log_dropped_records",
  ] as const;
  if (stringFields.some((key) => typeof candidate[key] !== "string")) return null;
  if (booleanFields.some((key) => typeof candidate[key] !== "boolean")) return null;
  if (!(candidate.godot_connected === null || typeof candidate.godot_connected === "boolean")) return null;
  if (counterFields.some((key) => !Number.isInteger(candidate[key]) || (candidate[key] as number) < 0)) return null;
  return {
    transport_state: candidate.transport_state as string,
    transport_detail: candidate.transport_detail as string,
    recording: candidate.recording as boolean,
    timed_can_active: candidate.timed_can_active as boolean,
    ict_active: candidate.ict_active as boolean,
    godot_connected: candidate.godot_connected as boolean | null,
    periodic_armed: candidate.periodic_armed as boolean,
    pc001_handshake: candidate.pc001_handshake as boolean,
    pc001_queued_frames: candidate.pc001_queued_frames as number,
    pc001_sent_frames: candidate.pc001_sent_frames as number,
    pc001_dropped_frames: candidate.pc001_dropped_frames as number,
    socketcan_submitted: candidate.socketcan_submitted as number,
    socketcan_sent: candidate.socketcan_sent as number,
    socketcan_congestion_dropped: candidate.socketcan_congestion_dropped as number,
    socketcan_coalesced: candidate.socketcan_coalesced as number,
    socketcan_terminal_errors: candidate.socketcan_terminal_errors as number,
    socketcan_pending: candidate.socketcan_pending as number,
    log_dropped_records: candidate.log_dropped_records as number,
  };
}

function finiteNumberOrNull(value: unknown): value is number | null {
  return value === null || (typeof value === "number" && Number.isFinite(value));
}

function decodeRuntime(value: unknown): CanConsoleRuntime | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (
    !(candidate.last_payload_hex === null || typeof candidate.last_payload_hex === "string")
    || !finiteNumberOrNull(candidate.last_egress_monotonic_s)
    || !finiteNumberOrNull(candidate.actual_frequency_hz)
    || !Number.isInteger(candidate.sample_count)
    || (candidate.sample_count as number) < 0
    || !(candidate.source === null || typeof candidate.source === "string")
    || !(candidate.authority === null || typeof candidate.authority === "string")
  ) return null;
  let values: Record<string, number> | null = null;
  if (candidate.values !== null) {
    if (!candidate.values || typeof candidate.values !== "object" || Array.isArray(candidate.values)) return null;
    values = {};
    for (const [key, item] of Object.entries(candidate.values)) {
      if (typeof item !== "number" || !Number.isFinite(item)) return null;
      values[key] = item;
    }
  }
  return {
    last_payload_hex: candidate.last_payload_hex as string | null,
    last_egress_monotonic_s: candidate.last_egress_monotonic_s as number | null,
    actual_frequency_hz: candidate.actual_frequency_hz as number | null,
    sample_count: candidate.sample_count as number,
    source: candidate.source as string | null,
    authority: candidate.authority as string | null,
    values,
  };
}

export function decodeCanConsoleRuntimeDelta(
  event: GatewayEvent,
): CanConsoleRuntimeDelta | null {
  if (event.kind !== "can_console_runtime") return null;
  const rows = event.detail.rows;
  const status = event.detail.status === undefined ? null : decodeRuntimeStatus(event.detail.status);
  const serverMonotonic = event.detail.server_monotonic_s;
  if (
    !rows
    || typeof rows !== "object"
    || Array.isArray(rows)
    || typeof serverMonotonic !== "number"
    || !Number.isFinite(serverMonotonic)
    || (event.detail.status !== undefined && !status)
  ) return null;
  const runtimeByKey: Record<string, CanConsoleRuntime> = {};
  for (const [key, value] of Object.entries(rows)) {
    const runtime = decodeRuntime(value);
    if (!runtime) return null;
    runtimeByKey[key] = runtime;
  }
  return { server_monotonic_s: serverMonotonic, rows: runtimeByKey, status };
}

export function applyGatewayRuntimeStatusDelta(
  status: GatewayStatus,
  delta: GatewayRuntimeStatusDelta,
): GatewayStatus {
  return { ...status, ...delta };
}

export function applyCanConsoleRuntimeDelta(
  snapshot: CanConsoleSnapshot,
  delta: CanConsoleRuntimeDelta,
): CanConsoleSnapshot {
  return {
    ...snapshot,
    server_monotonic_s: delta.server_monotonic_s,
    messages: snapshot.messages.map((message) => (
      delta.rows[message.key] ? { ...message, runtime: delta.rows[message.key] } : message
    )),
  };
}

export interface ApiErrorBody {
  error: { code: string; message: string; request_id: string; recoverable: boolean };
}

export class GatewayApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}
