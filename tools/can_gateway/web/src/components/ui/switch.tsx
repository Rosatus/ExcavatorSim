import { cn } from "@/lib/utils";

export function Switch({ checked, onChange, label }: { checked: boolean; onChange: (value: boolean) => void; label: string }) {
  return (
    <label className="inline-flex cursor-pointer items-center gap-2 text-sm">
      <input className="sr-only" type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      <span className={cn("relative h-6 w-11 rounded-full border border-border transition", checked ? "bg-primary" : "bg-muted")}>
        <span className={cn("absolute top-0.5 h-4 w-4 rounded-full bg-white transition-all", checked ? "left-6" : "left-1")} />
      </span>
      {label}
    </label>
  );
}
