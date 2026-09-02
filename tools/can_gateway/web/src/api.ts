import type { ApiErrorBody, CanAuthority, CanConsoleProfile, CanConsoleSnapshot, DbcContentEdit, DbcPreview, DbcSnapshot, GatewayStatus } from "./types";
import { GatewayApiError } from "./types";

async function decode<T>(response: Response): Promise<T> {
  const body = (await response.json()) as T | ApiErrorBody;
  if (!response.ok) {
    const error = (body as ApiErrorBody).error;
    throw new GatewayApiError(error?.code ?? "request_failed", error?.message ?? "请求失败", response.status);
  }
  return body as T;
}

async function mutation<T>(path: string, method: "POST" | "PUT", body: object, signal?: AbortSignal): Promise<T> {
  return decode<T>(
    await fetch(path, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal,
    }),
  );
}

export async function getStatus(): Promise<GatewayStatus> {
  return (await decode<{ status: GatewayStatus }>(await fetch("./api/v1/status"))).status;
}

export async function getDbc(): Promise<DbcSnapshot> {
  return (await decode<{ dbc: DbcSnapshot }>(await fetch("./api/v1/dbc"))).dbc;
}

export async function getGatewaySnapshot(): Promise<{ status: GatewayStatus; dbc: DbcSnapshot }> {
  return decode<{ status: GatewayStatus; dbc: DbcSnapshot }>(await fetch("./api/v1/dbc"));
}

export async function getCanConsoleSnapshot(): Promise<{ status: GatewayStatus; console: CanConsoleSnapshot }> {
  return decode<{ status: GatewayStatus; console: CanConsoleSnapshot }>(await fetch("./api/v1/can-console"));
}

export async function updateCanConsoleMessage(
  status: GatewayStatus,
  key: string,
  edit: DbcContentEdit,
  frequencyHz: number,
): Promise<void> {
  await mutation(`./api/v1/can-console/messages/${encodeURIComponent(key)}`, "PUT", {
    ...edit,
    frequency_hz: frequencyHz,
    expected_revision: status.revision,
  });
}

export async function previewCanConsoleMessage(
  key: string,
  edit: DbcContentEdit,
  signal?: AbortSignal,
): Promise<DbcPreview> {
  const response = await mutation<{ result: { preview: DbcPreview } }>(
    `./api/v1/can-console/messages/${encodeURIComponent(key)}/preview`,
    "POST",
    edit,
    signal,
  );
  return response.result.preview;
}

export async function updateCanAuthority(status: GatewayStatus, key: string, authority: CanAuthority): Promise<void> {
  await mutation(`./api/v1/can-console/messages/${encodeURIComponent(key)}/authority`, "PUT", {
    authority,
    expected_revision: status.revision,
  });
}

export async function updateAllCanAuthorities(
  status: GatewayStatus,
  authority: CanAuthority,
): Promise<string[]> {
  const response = await mutation<{ result: { forced_off: string[] } }>(
    "./api/v1/can-console/authority",
    "PUT",
    {
    authority,
    expected_revision: status.revision,
    },
  );
  return response.result.forced_off;
}

export async function canConsoleAction(action: "start" | "stop", status: GatewayStatus): Promise<void> {
  await mutation(`./api/v1/can-console/${action}`, "POST", { expected_revision: status.revision });
}

export async function exportCanConsoleProfile(): Promise<CanConsoleProfile> {
  const response = await mutation<{ result: { profile: CanConsoleProfile } }>(
    "./api/v1/can-console/export",
    "POST",
    {},
  );
  return response.result.profile;
}

export async function importCanConsoleProfile(status: GatewayStatus, profile: unknown): Promise<void> {
  await mutation("./api/v1/can-console/import", "POST", {
    profile,
    expected_revision: status.revision,
  });
}

export async function updateTcp(status: GatewayStatus, host: string, port: number): Promise<void> {
  await mutation("./api/v1/transport/tcp", "PUT", {
    host,
    port,
    expected_revision: status.revision,
  });
}

export async function restartCan0(status: GatewayStatus): Promise<void> {
  await mutation("./api/v1/transport/can0/restart", "POST", {
    confirm: true,
    expected_revision: status.revision,
  });
}

export async function updateDbcMessage(
  status: GatewayStatus,
  messageKey: string,
  edit: DbcContentEdit,
  enabled: boolean,
  frequencyHz: number,
): Promise<void> {
  await mutation(`./api/v1/dbc/messages/${encodeURIComponent(messageKey)}`, "PUT", {
    ...edit,
    enabled,
    frequency_hz: frequencyHz,
    expected_revision: status.revision,
  });
}

export async function previewDbcMessage(
  messageKey: string,
  edit: DbcContentEdit,
  signal?: AbortSignal,
): Promise<DbcPreview> {
  const response = await mutation<{ result: { preview: DbcPreview } }>(
    `./api/v1/dbc/messages/${encodeURIComponent(messageKey)}/preview`,
    "POST",
    edit,
    signal,
  );
  return response.result.preview;
}

export async function dbcAction(
  action: "start" | "stop" | "reload",
  status: GatewayStatus,
): Promise<void> {
  await mutation(`./api/v1/dbc/${action}`, "POST", { expected_revision: status.revision });
}

export function eventSocketUrl(sequence: number): string {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}/api/v1/events?after=${sequence}`;
}
