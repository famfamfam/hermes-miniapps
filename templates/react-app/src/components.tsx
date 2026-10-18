import { useState, type ReactNode } from "react";
import { hermes, useMutation } from "@hermes/mobile-sdk";
import type { FileInfo, FileSource, GroupState, MutationResult, QueryCall } from "@hermes/mobile-sdk";
import { monthLabel, money, timeLabel, tr } from "./format";

export interface MonthRow {
  month: string;
  total: number;
}

export function Tile({ label, value, tone }: { label: string; value: string; tone?: "warn" }) {
  return (
    <div className={`tile${tone ? ` tile-${tone}` : ""}`}>
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
    </div>
  );
}

/** Filter chips: `value` null means "all". The caller keeps the selection and passes it to a query. */
export function Chips<T extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { label: string; value: T | null }[];
  value: T | null;
  onChange: (value: T | null) => void;
}) {
  return (
    <div className="chips" role="group" aria-label={label}>
      {options.map((o) => (
        <button
          key={o.label}
          type="button"
          className={`chip${o.value === value ? " chip-on" : ""}`}
          aria-pressed={o.value === value}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

/** One row of a list: title and subtitle on the left (with `actions`, e.g. ActionButtons), amount and an optional badge on the right. */
export function ListCard({
  title,
  subtitle,
  amount,
  badge,
  actions,
}: {
  title: string;
  subtitle?: string;
  amount?: string;
  badge?: { text: string; tone?: "ok" | "warn" | "danger" };
  actions?: ReactNode;
}) {
  const toneClass = badge?.tone === "ok" ? "badge-paid" : badge?.tone === "danger" ? "badge-overdue" : "badge-unpaid";
  return (
    <li className="card">
      <div>
        <div className="card-title">{title}</div>
        {subtitle && <div className="muted">{subtitle}</div>}
        {actions && <div className="card-actions">{actions}</div>}
      </div>
      <div className="card-side">
        {amount && <div className="card-amount">{amount}</div>}
        {badge && <span className={`badge ${toneClass}`}>{badge.text}</span>}
      </div>
    </li>
  );
}

/** Dependency-free SVG chart. A charting library variant must be measured separately (S0-2). */
export function BarChart({ rows }: { rows: MonthRow[] }) {
  const data = [...rows].sort((a, b) => a.month.localeCompare(b.month));
  if (data.length === 0) return <p className="muted">{tr("Нет данных для графика", "No data for the chart")}</p>;
  const max = Math.max(...data.map((r) => r.total), 1);
  const W = 320;
  const H = 160;
  const pad = { l: 4, r: 4, t: 8, b: 22 };
  const bw = (W - pad.l - pad.r) / data.length;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={tr("Расходы по месяцам", "Monthly totals")} className="chart">
      {data.map((r, i) => {
        const h = ((H - pad.t - pad.b) * r.total) / max;
        const x = pad.l + i * bw + bw * 0.15;
        return (
          <g key={r.month}>
            <rect x={x} y={H - pad.b - h} width={bw * 0.7} height={h} rx={3} className="bar">
              <title>{`${monthLabel(r.month)}: ${money(r.total)}`}</title>
            </rect>
            <text x={x + bw * 0.35} y={H - 6} textAnchor="middle" className="axis">
              {monthLabel(r.month).split(" ")[0]}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

/** Freshness line: when data was fetched, from where, and whether the set is partial. */
export function DataMeta({ state }: { state: GroupState }) {
  const g = state.group;
  if (state.error) {
    return (
      <p className="error" role="alert">
        {tr("Не удалось загрузить данные", "Could not load the data")}: {state.error}{" "}
        <button type="button" className="link" onClick={state.refetch}>
          {tr("Повторить", "Retry")}
        </button>
      </p>
    );
  }
  if (!g) return <p className="muted">{tr("Загрузка…", "Loading…")}</p>;
  const bounded = Object.values(g.results).some((r) => r.completeness === "bounded");
  return (
    <p className="muted meta">
      {g.freshness === "cached" ? tr("Из кеша", "From cache") : tr("Обновлено", "Updated")} {timeLabel(g.fetchedAt)} ·{" "}
      {tr("ревизия данных", "data revision")} {g.dataRev}
      {bounded ? ` · ${tr("показана часть данных", "showing part of the data")}` : ""}{" "}
      <button type="button" className="link" onClick={state.refetch} disabled={state.loading}>
        {tr("Обновить", "Refresh")}
      </button>
    </p>
  );
}

/**
 * "Choose a file": opens the phone's own picker, stores the file for this app and hands it to `onPicked`.
 * `accept` limits the picker (media types, e.g. ["image/*"] or ["application/pdf"]). The page never sees the bytes.
 * A refusal (too large, wrong type, no connection) is shown in the user's language as the host worded it.
 */
export function FilePicker({
  label,
  accept,
  onPicked,
}: {
  label: string;
  accept?: string[];
  onPicked: (file: FileInfo) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const pick = () => {
    setBusy(true);
    setError(null);
    hermes
      .pickFile({ accept })
      .then((file) => file && onPicked(file))
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setBusy(false));
  };
  return (
    <div className="file-action">
      <button type="button" className="chip" onClick={pick} disabled={busy}>
        {busy ? tr("Загрузка…", "Loading…") : label}
      </button>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

/**
 * "Download": the phone offers to save, open or share the file; nothing is saved until the user chooses.
 * `source` is a stored file ({ fileId }) or a file locator of definitions.json ({ name, args }).
 */
export function DownloadButton({ label, source }: { label: string; source: FileSource }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run = () => {
    setBusy(true);
    setError(null);
    hermes
      .saveFile(source)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => setBusy(false));
  };
  return (
    <span className="file-action">
      <button type="button" className="link" onClick={run} disabled={busy}>
        {busy ? tr("Загрузка…", "Loading…") : label}
      </button>
      {error && (
        <span className="error" role="alert">
          {" "}
          {error}
        </span>
      )}
    </span>
  );
}

/**
 * A button that writes: runs a mutation of definitions.json by name (see `useMutation`). The phone asks the user first
 * when the mutation deletes, and the lists on screen are read again once it is saved. `onDone` runs only when the change
 * was saved, not when the user declined. A failure is shown in the user's language as the host worded it.
 */
export function ActionButton({
  label,
  mutation,
  args,
  onDone,
  tone,
}: {
  label: string;
  mutation: string;
  args?: QueryCall["args"];
  onDone?: (result: Extract<MutationResult, { done: true }>) => void;
  tone?: "danger";
}) {
  const action = useMutation(mutation);
  const run = () => {
    void action.run(args).then((result) => {
      if (result?.done) onDone?.(result);
    });
  };
  return (
    <span className="file-action">
      <button type="button" className={`link${tone === "danger" ? " link-danger" : ""}`} onClick={run} disabled={action.pending}>
        {action.pending ? tr("Сохранение…", "Saving…") : label}
      </button>
      {action.error && (
        <span className="error" role="alert">
          {" "}
          {action.error.message}
        </span>
      )}
    </span>
  );
}

/** A small preview of a stored picture (png, jpg, webp, gif); other files show their name only. */
export function FileThumb({ file }: { file: FileInfo }) {
  const isPicture = /^image\/(png|jpeg|webp|gif)$/.test(file.mime);
  return (
    <figure className="file-thumb">
      {isPicture ? <img src={hermes.fileUrl(file.fileId)} alt={file.name} /> : null}
      <figcaption className="muted">{file.name}</figcaption>
    </figure>
  );
}
