import { useState } from "react";
import { hermes } from "@hermes/mobile-sdk";
import type { FileSource, GroupState } from "@hermes/mobile-sdk";
import { monthLabel, money, timeLabel } from "./format";

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

/** Dependency-free SVG chart. A charting library variant must be measured separately (S0-2). */
export function BarChart({ rows }: { rows: MonthRow[] }) {
  const data = [...rows].sort((a, b) => a.month.localeCompare(b.month));
  if (data.length === 0) return <p className="muted">Нет данных для графика</p>;
  const max = Math.max(...data.map((r) => r.total), 1);
  const W = 320;
  const H = 160;
  const pad = { l: 4, r: 4, t: 8, b: 22 };
  const bw = (W - pad.l - pad.r) / data.length;
  return (
    <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Расходы по месяцам" className="chart">
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
        Не удалось загрузить данные: {state.error}{" "}
        <button type="button" className="link" onClick={state.refetch}>
          Повторить
        </button>
      </p>
    );
  }
  if (!g) return <p className="muted">Загрузка…</p>;
  const bounded = Object.values(g.results).some((r) => r.completeness === "bounded");
  return (
    <p className="muted meta">
      {g.freshness === "cached" ? "Из кеша" : "Обновлено"} {timeLabel(g.fetchedAt)} · ревизия данных {g.dataRev}
      {bounded ? " · показана часть данных" : ""}{" "}
      <button type="button" className="link" onClick={state.refetch} disabled={state.loading}>
        Обновить
      </button>
    </p>
  );
}

/** "Скачать": телефон предлагает сохранить, открыть или отправить файл; без выбора ничего не сохраняется. */
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
      <button type="button" className="chip" onClick={run} disabled={busy}>
        {busy ? "Загрузка…" : label}
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
