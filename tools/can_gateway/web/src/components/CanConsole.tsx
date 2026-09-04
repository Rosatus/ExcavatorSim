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
import { memo, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import {
  canConsoleAction,
  exportCanConsoleProfile,
  importCanConsoleProfile,
  previewCanConsoleMessage,
  updateCanAuthority,
  updateAllCanAuthorities,
  updateCanConsoleMessage,
} from "../api";
import { formatFreshness } from "../freshness";
import { formatSignalValue } from "../signalFormat";
import { getServerNow, setServerAnchor, subscribeServerClock } from "../serverClock";
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
    <div className="fixed inset-0 z-50 grid place-items-center bg-slate-950/70 p-4 animate-[fade-in_120ms_ease-out]" role="presentation" onMouseDown={onClose}>
      <section
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="message-dialog-title"
        className="max-h-[92vh] w-full max-w-4xl overflow-auto rounded-xl border bg-card p-5 text-card-foreground shadow-2xl animate-[dialog-in_160ms_ease-out]"
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
          {row.message.signals.length === 0 && (
            <div className="sm:col-span-2 lg:col-span-3 rounded-lg border border-dashed p-4 text-sm text-muted-foreground">
              此报文没有物理量定义，请直接编辑 Payload。
            </div>
          )}
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

function AuthorityControl({ row, busy, onAuthority }: { row: CanConsoleMessage; busy: boolean; onAuthority: (key: string, authority: CanAuthority) => void }) {
  const labels: Record<CanAuthority, string> = { off: "关闭", custom: "自定义", simulation: "仿真" };
  return (
    <div className="inline-flex rounded-lg border bg-muted/45 p-0.5" role="radiogroup" aria-label={`${row.message.frame_id_hex} 发送权威`}>
      {(["off", "custom", "simulation"] as const).map((authority) => {
        const disabled = busy || (authority === "simulation" && !row.simulation_available);
        return (
          <button
            key={authority}
            type="button"
            role="radio"
            aria-checked={row.authority === authority}
            title={authority === "simulation" && !row.simulation_available ? "当前模式没有仿真生产者" : labels[authority]}
            disabled={disabled}
            onClick={() => onAuthority(row.key, authority)}
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

function FreshnessCell({ row }: { row: CanConsoleMessage }) {
  const serverNow = useSyncExternalStore(subscribeServerClock, getServerNow);
  const fresh = formatFreshness(row, serverNow);
  return <td className={`whitespace-nowrap px-3 py-3 font-mono font-semibold tabular-nums ${fresh.tone}`}>{fresh.text}</td>;
}

function PayloadBytes({ payload }: { payload: string | null }) {
  const bytes = payload ? payload.match(/.{2}/g) ?? [] : [];
  const previous = useRef<string[]>([]);
  const changed = new Set<number>();
  bytes.forEach((byte, index) => {
    if (index < previous.current.length && previous.current[index] !== byte) changed.add(index);
  });
  useEffect(() => {
    previous.current = bytes;
  });
  if (bytes.length === 0) {
    return <code className="whitespace-nowrap rounded bg-muted px-2 py-1 text-xs">尚未发送</code>;
  }
  return (
    <code aria-label={`最近发送 payload ${bytes.join(" ")}`} className="whitespace-nowrap rounded bg-muted px-2 py-1 text-xs">
      {bytes.map((byte, index) => (
        <span key={index} className={changed.has(index) ? "rounded-sm animate-[byte-flash_0.6s_ease-out]" : undefined}>
          {byte}{index < bytes.length - 1 ? " " : ""}
        </span>
      ))}
    </code>
  );
}

const ConsoleRow = memo(function ConsoleRow({
  row,
  open,
  busy,
  onToggle,
  onEdit,
  onAuthority,
}: {
  row: CanConsoleMessage;
  open: boolean;
  busy: boolean;
  onToggle: (key: string) => void;
  onEdit: (key: string) => void;
  onAuthority: (key: string, authority: CanAuthority) => void;
}) {
  const physical = row.runtime.values ?? null;
  return <>
    <tr className="border-t transition-colors hover:bg-muted/25">
      <td className="px-3 py-3"><button className="rounded p-1 hover:bg-muted" aria-label={open ? "收起物理量" : "展开物理量"} onClick={() => onToggle(row.key)}>{open ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}</button></td>
      <td className="px-3 py-3"><div className="font-mono font-semibold">{row.message.frame_id_hex}</div><div className="mt-1 max-w-52 truncate text-xs text-muted-foreground">{row.message.name}</div></td>
      <td className="px-3 py-3"><Badge className="font-mono font-normal">{row.message.channel}</Badge></td>
      <td className="px-3 py-3"><PayloadBytes payload={row.runtime.last_payload_hex} /></td>
      <td className="px-3 py-3"><Button variant="outline" size="sm" disabled={row.authority !== "custom"} title={row.authority !== "custom" ? "切换到自定义权威后可编辑" : undefined} onClick={() => onEdit(row.key)}><Edit3 className="h-3.5 w-3.5" /> 编辑</Button></td>
      <td className="px-3 py-3"><AuthorityControl row={row} busy={busy} onAuthority={onAuthority} /></td>
      <td className="whitespace-nowrap px-3 py-3 font-mono tabular-nums">{row.expected_frequency_hz ? `${row.expected_frequency_hz} Hz` : "关闭"}</td>
      <td className="whitespace-nowrap px-3 py-3 font-mono tabular-nums">{formatFrequency(row.runtime.actual_frequency_hz)}</td>
      <FreshnessCell row={row} />
    </tr>
    {open && <tr className="border-t bg-muted/15"><td /><td colSpan={8} className="px-3 py-4">
      {row.message.signals.length === 0 ? <span className="text-xs text-muted-foreground">该报文没有可解析的物理量定义，仅显示原始数据。</span> : physical ? <div className="flex flex-wrap gap-2">{Object.entries(physical).map(([name, value]) => { const signal = row.message.signals.find((candidate) => candidate.name === name); return <Badge key={name} className="font-normal" title={`原始值 ${String(value)}`}><span className="mr-2 text-muted-foreground">{name}</span><span className="font-mono">{formatSignalValue(signal, Number(value))}</span></Badge>; })}</div> : <span className="text-xs text-muted-foreground">该报文尚未成功发送，暂无物理量数据。</span>}
    </td></tr>}
  </>;
});

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
  const [batchNotice, setBatchNotice] = useState("");
  const fileInput = useRef<HTMLInputElement>(null);
  const statusRef = useRef(status);
  statusRef.current = status;

  useEffect(() => {
    setServerAnchor(consoleSnapshot.server_monotonic_s);
  }, [consoleSnapshot.server_monotonic_s]);
  useEffect(() => {
    if (!batchNotice) return;
    const timer = window.setTimeout(() => setBatchNotice(""), 5000);
    return () => window.clearTimeout(timer);
  }, [batchNotice]);
  const toggleRow = useCallback((key: string) => {
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);
  const handleAuthority = useCallback((key: string, authority: CanAuthority) => {
    mutate(() => updateCanAuthority(statusRef.current, key, authority));
  }, [mutate]);
  const applyBatchAuthority = (authority: CanAuthority) => {
    if (authority === "simulation") {
      mutate(async () => {
        const forced = await updateAllCanAuthorities(status, "simulation");
        setBatchNotice(forced.length > 0 ? `已切换为仿真；${forced.length} 个无仿真生产者的报文自动关闭。` : "全部报文已切换为仿真。");
      });
      return;
    }
    mutate(async () => {
      await updateAllCanAuthorities(status, authority);
      setBatchNotice(authority === "off" ? "全部报文已关闭。" : "全部报文已切换为自定义。");
    });
  };
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
      <div className="flex flex-col gap-3 border-b p-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="font-semibold">CAN 报文控制台</h2>
          <p className="mt-1 text-xs text-muted-foreground">实际频率与新鲜度来自 Gateway 的发送统计，不代表总线上的真实到达情况。</p>
        </div>
        {status.mode === "standalone" && (consoleSnapshot.custom_armed
          ? <Button variant="destructive" disabled={busy} onClick={() => mutate(() => canConsoleAction("stop", status))}><Square className="h-4 w-4" /> 停止自定义发送</Button>
          : <Button disabled={busy || !rows.some((row) => row.authority === "custom")} onClick={() => mutate(() => canConsoleAction("start", status))}><Play className="h-4 w-4" /> 开始自定义发送</Button>)}
      </div>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b bg-muted/20 px-4 py-2.5">
        <label className="relative min-w-56 flex-1 sm:max-w-xs"><Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" /><Input className="pl-8 pr-8" placeholder="搜索 CAN ID / 报文 / 信号" value={query} onChange={(event) => setQuery(event.target.value)} />{query && <button type="button" aria-label="清除搜索" className="absolute right-2.5 top-2.5 rounded text-muted-foreground hover:text-foreground" onClick={() => setQuery("")}><X className="h-4 w-4" /></button>}</label>
        {query.trim() && <span className="self-center text-xs tabular-nums text-muted-foreground">{rows.length} / {consoleSnapshot.messages.length} 条</span>}
        <div className="flex flex-wrap items-center gap-2 sm:ml-auto">
          <div className="inline-flex items-center rounded-lg border bg-background p-0.5" role="group" aria-label="批量切换发送权威">
            <span className="px-2 text-xs text-muted-foreground">全部</span>
            {([
              { authority: "off" as const, label: "关闭", disabled: busy, title: "关闭所有报文的发送" },
              { authority: "custom" as const, label: "自定义", disabled: busy, title: "所有报文切换为自定义发送" },
              { authority: "simulation" as const, label: "仿真", disabled: busy || status.mode !== "godot-managed", title: status.mode === "godot-managed" ? "支持的报文切换到仿真，其余自动关闭" : "独立启动模式不提供仿真生产者" },
            ]).map((action) => (
              <button
                key={action.authority}
                type="button"
                title={action.title}
                disabled={action.disabled}
                onClick={() => applyBatchAuthority(action.authority)}
                className="rounded-md px-2.5 py-1 text-xs text-muted-foreground transition hover:bg-muted hover:text-foreground disabled:cursor-not-allowed disabled:opacity-35"
              >
                {action.label}
              </button>
            ))}
          </div>
          {status.mode === "standalone" && <>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => mutate(exportProfile)}><Download className="h-4 w-4" /> 导出</Button>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => fileInput.current?.click()}><Upload className="h-4 w-4" /> 导入</Button>
            <input ref={fileInput} className="hidden" type="file" accept="application/json,.json" onChange={(event) => { const file = event.target.files?.[0]; if (file) importProfile(file); event.target.value = ""; }} />
          </>}
        </div>
      </div>

      {batchNotice && <div className="flex items-center justify-between gap-3 border-b bg-muted/35 px-4 py-2 text-xs text-muted-foreground"><span>{batchNotice}</span><button type="button" aria-label="关闭批量操作提示" className="rounded p-0.5 hover:bg-muted" onClick={() => setBatchNotice("")}><X className="h-3.5 w-3.5" /></button></div>}

      {consoleSnapshot.load.warning && <div className="border-b border-amber-500/30 bg-amber-500/10 px-4 py-2 text-xs text-amber-700 dark:text-amber-200">估算总线负载 {consoleSnapshot.load.percent.toFixed(2)}%，负载较高但不会阻止发送。</div>}
      <div className="overflow-x-auto">
        <table className="table-fixed w-full min-w-[1326px] border-collapse text-sm">
          <colgroup data-testid="can-console-columns">
            <col className="w-[48px]" />
            <col className="w-[190px]" />
            <col className="w-[88px]" />
            <col className="w-[250px]" />
            <col className="w-[100px]" />
            <col className="w-[250px]" />
            <col className="w-[120px]" />
            <col className="w-[140px]" />
            <col className="w-[140px]" />
          </colgroup>
          <thead className="sticky top-0 z-10 bg-muted/90 text-left text-[11px] uppercase tracking-wider text-muted-foreground backdrop-blur">
            <tr><th className="w-10 px-3 py-3" /><th className="px-3 py-3">CAN ID</th><th className="px-3 py-3">Channel</th><th className="px-3 py-3">最近发送 Payload</th><th className="px-3 py-3">编辑</th><th className="px-3 py-3">发送权威</th><th className="px-3 py-3">预期频率</th><th className="px-3 py-3">实际频率</th><th className="px-3 py-3">新鲜度</th></tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <ConsoleRow
                key={row.key}
                row={row}
                open={expanded.has(row.key)}
                busy={busy}
                onToggle={toggleRow}
                onEdit={setEditing}
                onAuthority={handleAuthority}
              />
            ))}
          </tbody>
        </table>
      </div>
      {rows.length === 0 && <div className="p-10 text-center text-sm text-muted-foreground">没有匹配的 CAN 报文</div>}
      {editingRow && <MessageDialog row={editingRow} status={status} busy={busy} mutate={mutate} onClose={() => setEditing(null)} />}
    </section>
  );
}
