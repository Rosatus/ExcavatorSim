import {
  ChevronDown,
  ChevronRight,
  Download,
  Edit3,
  Play,
  Save,
  Search,
  Square,
  Upload,
  X,
} from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import {
  canConsoleAction,
  exportCanConsoleProfile,
  importCanConsoleProfile,
  previewCanConsoleMessage,
  updateCanAuthority,
  updateCanConsoleMessage,
} from "../api";
import type {
  CanAuthority,
  CanConsoleMessage,
  CanConsoleSnapshot,
  DbcContentEdit,
  GatewayStatus,
} from "../types";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { Input } from "./ui/input";

type Mutate = (action: () => Promise<void>) => void;

function parseValues(values: Record<string, string>): Record<string, number> {
  return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, Number(value)]));
}

function payloadError(payload: string, length: number): string {
  const stripped = payload.trim();
  if (!stripped) return "payload 不能为空";
  if (stripped.toLowerCase().includes("0x")) return "payload 不使用 0x 前缀";
  const tokens = stripped.includes(" ") ? stripped.split(/\s+/) : stripped.match(/.{1,2}/g) ?? [];
  if (tokens.length !== length || tokens.some((token) => !/^[0-9a-fA-F]{2}$/.test(token))) {
    return `payload 必须恰好包含 ${length} 个十六进制字节`;
  }
  return "";
}

function MessageDialog({
  row,
  status,
  busy,
  mutate,
  onClose,
}: {
  row: CanConsoleMessage;
  status: GatewayStatus;
  busy: boolean;
  mutate: Mutate;
  onClose: () => void;
}) {
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(Object.entries(row.values).map(([key, value]) => [key, String(value)])),
  );
  const [payload, setPayload] = useState(row.payload_hex);
  const [frequency, setFrequency] = useState(String(row.frequency_hz));
  const [source, setSource] = useState<"values" | "payload">("values");
  const [previewError, setPreviewError] = useState("");
  const [pending, setPending] = useState(false);
  const generation = useRef(0);
  const normalization = useRef<string | null>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;

  const parsed = parseValues(values);
  const valuesValid = row.message.signals.every((signal) => {
    const input = values[signal.name];
    if (input === undefined) return true;
    const value = parsed[signal.name];
    return input.trim() !== "" && Number.isFinite(value)
      && (!signal.integer_only || Number.isInteger(value))
      && (signal.minimum === null || value >= signal.minimum)
      && (signal.maximum === null || value <= signal.maximum);
  });
  const rawError = payloadError(payload, row.message.length);
  const hz = Number(frequency);
  const valid = (source === "values" ? valuesValid : !rawError)
    && Number.isInteger(hz) && hz >= 1 && hz <= 100;

  useEffect(() => {
    const previousFocus = document.activeElement;
    const dialog = dialogRef.current;
    const focusable = () => Array.from(
      dialog?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ) ?? [],
    ).filter((element) => !element.hasAttribute("hidden"));
    focusable()[0]?.focus();
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusable();
      if (items.length === 0) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      if (previousFocus instanceof HTMLElement) previousFocus.focus();
    };
  }, []);

  useEffect(() => {
    const current = ++generation.current;
    if (source === "values" && !valuesValid) return;
    if (source === "payload" && rawError) return;
    if (source === "payload" && normalization.current === payload) {
      normalization.current = null;
      setPending(false);
      return;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      setPending(true);
      const edit: DbcContentEdit = source === "values" ? { values: parseValues(values) } : { payload_hex: payload };
      void previewCanConsoleMessage(row.key, edit, controller.signal)
        .then((preview) => {
          if (current !== generation.current) return;
          if (source === "values") setPayload(preview.payload_hex);
          else {
            if (preview.payload_hex !== payload) normalization.current = preview.payload_hex;
            setPayload(preview.payload_hex);
            setValues(Object.fromEntries(Object.entries(preview.values).map(([key, value]) => [key, String(value)])));
          }
          setPreviewError("");
        })
        .catch((reason: unknown) => {
          if (current === generation.current && !(reason instanceof DOMException && reason.name === "AbortError")) {
            setPreviewError(reason instanceof Error ? reason.message : "预览失败");
          }
        })
        .finally(() => {
          if (current === generation.current && !controller.signal.aborted) setPending(false);
        });
    }, 250);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [payload, rawError, row.key, source, values, valuesValid]);

  const save = () => {
    const edit: DbcContentEdit = source === "values" ? { values: parsed } : { payload_hex: payload };
    mutate(async () => {
      await updateCanConsoleMessage(status, row.key, edit, hz);
      onClose();
    });
  };

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-slate-950/70 p-4" role="presentation" onMouseDown={onClose}>
      <section
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="message-dialog-title"
        className="max-h-[92vh] w-full max-w-4xl overflow-auto rounded-xl border bg-card p-5 text-card-foreground shadow-2xl"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 id="message-dialog-title" className="text-lg font-semibold">编辑 {row.message.frame_id_hex}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{row.message.name} · DLC {row.message.length}</p>
          </div>
          <Button variant="ghost" size="icon" onClick={onClose} aria-label="关闭编辑窗口"><X className="h-4 w-4" /></Button>
        </div>

        <div className="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {row.message.signals.filter((signal) => signal.name in values).map((signal) => (
            <label key={signal.key} className="text-xs text-muted-foreground">
              <span className="flex justify-between gap-2"><strong className="text-foreground">{signal.name}</strong><span>{signal.unit || "—"}</span></span>
              <Input
                className="mt-1 font-mono"
                type="number"
                step={signal.integer_only ? 1 : "any"}
                value={values[signal.name]}
                onChange={(event) => {
                  setSource("values");
                  setValues((current) => ({ ...current, [signal.name]: event.target.value }));
                }}
              />
              <span className="mt-1 block">{signal.minimum ?? "−∞"} … {signal.maximum ?? "+∞"}</span>
            </label>
          ))}
        </div>

        <div className="mt-6 grid gap-4 border-t pt-5 sm:grid-cols-[1fr_150px]">
          <label className="text-xs text-muted-foreground">Payload
            <Input
              className="mt-1 font-mono uppercase tracking-wider"
              value={payload}
              aria-invalid={source === "payload" && Boolean(rawError || previewError)}
              onChange={(event) => { setSource("payload"); setPayload(event.target.value); }}
            />
          </label>
          <label className="text-xs text-muted-foreground">发送频率 (Hz)
            <Input className="mt-1" type="number" min={1} max={100} step={1} value={frequency} onChange={(event) => setFrequency(event.target.value)} />
          </label>
        </div>
        <div className="mt-2 min-h-5 text-xs text-muted-foreground" aria-live="polite">
          {rawError && source === "payload" ? <span className="text-red-500">{rawError}</span>
            : previewError ? <span className="text-red-500">{previewError}</span>
              : pending ? "正在预览…" : "物理值与 payload 可双向编辑；只有保存才会生效。"}
        </div>
        <div className="mt-5 flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>取消</Button>
          <Button disabled={!valid || busy || pending || Boolean(previewError)} onClick={save}><Save className="h-4 w-4" /> 保存</Button>
        </div>
      </section>
    </div>
  );
}

function AuthorityControl({ row, status, busy, mutate }: { row: CanConsoleMessage; status: GatewayStatus; busy: boolean; mutate: Mutate }) {
  const labels: Record<CanAuthority, string> = { off: "关闭", custom: "自定义", simulation: "仿真" };
  return (
    <div className="inline-flex rounded-lg border bg-muted/45 p-0.5" role="radiogroup" aria-label={`${row.message.frame_id_hex} 发送权威`}>
      {(["off", "custom", "simulation"] as const).map((authority) => {
        const disabled = busy || (authority === "simulation" && !row.simulation_available);
        return (
          <button
            type="button"
            role="radio"
            aria-checked={row.authority === authority}
            title={authority === "simulation" && !row.simulation_available ? "当前模式没有仿真生产者" : labels[authority]}
            disabled={disabled}
            onClick={() => mutate(() => updateCanAuthority(status, row.key, authority))}
            className={`rounded-md px-2 py-1 text-xs transition ${row.authority === authority ? "bg-primary text-primary-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"} disabled:cursor-not-allowed disabled:opacity-35`}
          >
            {labels[authority]}
          </button>
        );
      })}
    </div>
  );
}

function formatFrequency(value: number | null): string {
  return value === null ? "—" : `${value.toFixed(3)} Hz`;
}

function freshness(row: CanConsoleMessage, serverNow: number): { text: string; tone: string } {
  const sentAt = row.runtime.last_egress_monotonic_s;
  if (sentAt === null) return { text: "—", tone: "text-muted-foreground" };
  const ageMs = Math.max(0, (serverNow - sentAt) * 1000);
  if (ageMs > 999_000) return { text: ">999s", tone: "text-red-500" };
  const text = ageMs < 1000 ? `${ageMs.toFixed(3)} ms` : `${(ageMs / 1000).toFixed(3)} s`;
  return { text, tone: ageMs < 100 ? "text-emerald-500" : ageMs < 1000 ? "text-amber-500" : "text-red-500" };
}

export function CanConsole({
  status,
  consoleSnapshot,
  busy,
  mutate,
}: {
  status: GatewayStatus;
  consoleSnapshot: CanConsoleSnapshot;
  busy: boolean;
  mutate: Mutate;
}) {
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [editing, setEditing] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [tick, setTick] = useState(0);
  const anchor = useRef({ server: consoleSnapshot.server_monotonic_s, client: performance.now() });
  const fileInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    anchor.current = { server: consoleSnapshot.server_monotonic_s, client: performance.now() };
  }, [consoleSnapshot.server_monotonic_s]);
  useEffect(() => {
    const timer = window.setInterval(() => setTick((value) => value + 1), 50);
    return () => window.clearInterval(timer);
  }, []);
  const serverNow = anchor.current.server + (performance.now() - anchor.current.client) / 1000 + tick * 0;
  const rows = useMemo(() => consoleSnapshot.messages.filter((row) => {
    const haystack = `${row.message.frame_id_hex} ${row.message.name} ${row.message.signals.map((signal) => signal.name).join(" ")}`.toLowerCase();
    return haystack.includes(query.trim().toLowerCase());
  }), [consoleSnapshot.messages, query]);
  const editingRow = consoleSnapshot.messages.find((row) => row.key === editing) ?? null;

  const exportProfile = async () => {
    const profile = await exportCanConsoleProfile();
    const blob = new Blob([`${JSON.stringify(profile, null, 2)}\n`], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const anchorElement = document.createElement("a");
    anchorElement.href = url;
    anchorElement.download = "excavatorsim-can-console.json";
    anchorElement.click();
    URL.revokeObjectURL(url);
  };
  const importProfile = (file: File) => {
    mutate(async () => {
      const profile = JSON.parse(await file.text()) as unknown;
      await importCanConsoleProfile(status, profile);
    });
  };

  return (
    <section className="overflow-hidden rounded-xl border bg-card shadow-panel">
      <div className="flex flex-col gap-4 border-b p-4 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h2 className="font-semibold">CAN 报文控制台</h2>
          <p className="mt-1 text-xs text-muted-foreground">实际频率与新鲜度基于 Gateway transport egress，不代表物理总线 ACK。</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <label className="relative min-w-56 flex-1 lg:flex-none"><Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" /><Input className="pl-8" placeholder="搜索 CAN ID / 报文 / 信号" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
          {status.mode === "standalone" && <>
            {consoleSnapshot.custom_armed
              ? <Button variant="destructive" disabled={busy} onClick={() => mutate(() => canConsoleAction("stop", status))}><Square className="h-4 w-4" /> 停止自定义发送</Button>
              : <Button disabled={busy || !rows.some((row) => row.authority === "custom")} onClick={() => mutate(() => canConsoleAction("start", status))}><Play className="h-4 w-4" /> 开始自定义发送</Button>}
            <Button variant="outline" disabled={busy} onClick={() => mutate(exportProfile)}><Download className="h-4 w-4" /> 导出</Button>
            <Button variant="outline" disabled={busy} onClick={() => fileInput.current?.click()}><Upload className="h-4 w-4" /> 导入</Button>
            <input ref={fileInput} className="hidden" type="file" accept="application/json,.json" onChange={(event) => { const file = event.target.files?.[0]; if (file) importProfile(file); event.target.value = ""; }} />
          </>}
        </div>
      </div>

      {consoleSnapshot.load.warning && <div className="border-b border-amber-500/30 bg-amber-500/10 px-4 py-2 text-xs text-amber-700 dark:text-amber-200">估算总线负载 {consoleSnapshot.load.percent.toFixed(2)}%，负载较高但不会阻止发送。</div>}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[1180px] border-collapse text-sm">
          <thead className="sticky top-0 z-10 bg-muted/90 text-left text-[11px] uppercase tracking-wider text-muted-foreground backdrop-blur">
            <tr><th className="w-10 px-3 py-3" /><th className="px-3 py-3">CAN ID</th><th className="px-3 py-3">最近发送 Payload</th><th className="px-3 py-3">编辑</th><th className="px-3 py-3">发送权威</th><th className="px-3 py-3">预期频率</th><th className="px-3 py-3">实际频率</th><th className="px-3 py-3">新鲜度</th></tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const open = expanded.has(row.key);
              const fresh = freshness(row, serverNow);
              const physical = row.runtime.values ?? null;
              return [
                <tr key={row.key} className="border-t hover:bg-muted/25">
                  <td className="px-3 py-3"><button className="rounded p-1 hover:bg-muted" aria-label={open ? "收起物理量" : "展开物理量"} onClick={() => setExpanded((current) => { const next = new Set(current); if (next.has(row.key)) next.delete(row.key); else next.add(row.key); return next; })}>{open ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}</button></td>
                  <td className="px-3 py-3"><div className="font-mono font-semibold">{row.message.frame_id_hex}</div><div className="mt-1 max-w-52 truncate text-xs text-muted-foreground">{row.message.name}</div></td>
                  <td className="px-3 py-3"><code className="whitespace-nowrap rounded bg-muted px-2 py-1 text-xs">{row.runtime.last_payload_hex ? row.runtime.last_payload_hex.match(/.{2}/g)?.join(" ") : "尚未发送"}</code></td>
                  <td className="px-3 py-3"><Button variant="outline" size="sm" disabled={row.authority !== "custom"} onClick={() => setEditing(row.key)}><Edit3 className="h-3.5 w-3.5" /> 编辑</Button></td>
                  <td className="px-3 py-3"><AuthorityControl row={row} status={status} busy={busy} mutate={mutate} /></td>
                  <td className="px-3 py-3 font-mono">{row.expected_frequency_hz ? `${row.expected_frequency_hz} Hz` : "关闭"}</td>
                  <td className="px-3 py-3 font-mono">{formatFrequency(row.runtime.actual_frequency_hz)}</td>
                  <td className={`px-3 py-3 font-mono font-semibold ${fresh.tone}`}>{fresh.text}</td>
                </tr>,
                open && <tr key={`${row.key}-detail`} className="border-t bg-muted/15"><td /><td colSpan={7} className="px-3 py-4">
                  {physical ? <div className="flex flex-wrap gap-2">{Object.entries(physical).map(([name, value]) => <Badge key={name} className="font-normal"><span className="mr-2 text-muted-foreground">{name}</span><span className="font-mono">{Number(value).toFixed(6)}</span></Badge>)}</div> : <span className="text-xs text-muted-foreground">尚无成功发送，暂无真实 payload 对应的物理量。</span>}
                </td></tr>,
              ];
            })}
          </tbody>
        </table>
      </div>
      {rows.length === 0 && <div className="p-10 text-center text-sm text-muted-foreground">没有匹配的 CAN 报文</div>}
      {editingRow && <MessageDialog row={editingRow} status={status} busy={busy} mutate={mutate} onClose={() => setEditing(null)} />}
    </section>
  );
}
