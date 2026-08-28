import type { ApiErrorBody, DbcSnapshot, GatewayStatus } from "./types";
import { GatewayApiError } from "./types";

async function decode<T>(response: Response): Promise<T> {
  const body = (await response.json()) as T | ApiErrorBody;
  if (!response.ok) {
    const error = (body as ApiErrorBody).error;
    throw new GatewayApiError(error?.code ?? "request_failed", error?.message ?? "请求失败", response.status);
  }
  return body as T;
}

async function mutation<T>(path: string, method: "POST" | "PUT", body: object): Promise<T> {
  return decode<T>(
    await fetch(path, {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
  );
}

export async function getStatus(): Promise<GatewayStatus> {
  return (await decode<{ status: GatewayStatus }>(await fetch("./api/v1/status"))).status;
}

export async function getDbc(): Promise<DbcSnapshot> {
  return (await decode<{ dbc: DbcSnapshot }>(await fetch("./api/v1/dbc"))).dbc;
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
  values: Record<string, number>,
  enabled: boolean,
  frequencyHz: number,
): Promise<void> {
  await mutation(`./api/v1/dbc/messages/${encodeURIComponent(messageKey)}`, "PUT", {
    values,
    enabled,
    frequency_hz: frequencyHz,
    expected_revision: status.revision,
  });
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
