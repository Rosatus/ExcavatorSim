export type GatewayMode = "standalone" | "godot-managed";

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
}

export interface DbcMessageDefinition {
  key: string;
  file_sha256: string;
  name: string;
  frame_id: number;
  frame_id_hex: string;
  is_extended: boolean;
  length: number;
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
