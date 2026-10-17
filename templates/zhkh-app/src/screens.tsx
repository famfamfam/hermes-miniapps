import { useState, type ReactNode } from "react";
import { useQueryGroup } from "@hermes/mobile-sdk";
import { BarChart, DataMeta, DownloadButton, Tile, type MonthRow } from "./components";
import { money, periodLabel, dateLabel } from "./format";

type Status = "new" | "overdue" | "paid";

interface Receipt {
  id: number;
  address: string;
  provider: string | null;
  service: string | null;
  period: string | null;
  amount: number | null;
  status: string;
}

interface AddressRow {
  id: number;
  name: string;
  alias: string | null;
  receipts: number;
  due: number;
}

interface ReceiptDetailData {
  id: number;
  payer: string | null;
  address: string | null;
  provider: string | null;
  service: string | null;
  period: string | null;
  receipt_date: string | null;
  account_number: string | null;
  amount: number | null;
  amount_paid: number | null;
  status: string;
  has_file: number;
}

interface ServiceLine {
  name: string | null;
  amount: number | null;
  unit: string | null;
  volume: number | string | null;
  tariff: number | string | null;
}

/** The owning skill writes free-form statuses; unknown ones are shown as they are. */
const STATUS_LABEL: Record<string, string> = { new: "к оплате", overdue: "просрочено", paid: "оплачено" };
const statusLabel = (s: string) => STATUS_LABEL[s] ?? s;

export function Overview() {
  const state = useQueryGroup([
    { name: "due_total" },
    { name: "due_count" },
    { name: "overdue_count" },
    { name: "latest_period" },
    { name: "latest_total" },
    { name: "monthly_totals" },
    { name: "by_address" },
  ]);
  const r = state.group?.results;
  const overdue = (r?.overdue_count.data as number | undefined) ?? 0;
  const latest = r?.latest_period.data as string | null | undefined;
  const addresses = (r?.by_address.data as AddressRow[] | undefined) ?? [];
  return (
    <section>
      <h1>Обзор</h1>
      <div className="tiles">
        <Tile
          label={`К оплате${r ? ` · ${r.due_count.data as number} шт.` : ""}`}
          value={r ? money(r.due_total.data as number) : "…"}
          tone="warn"
        />
        <Tile
          label={latest ? `Начислено · ${periodLabel(latest)}` : "Последний период"}
          value={r ? money(r.latest_total.data as number) : "…"}
        />
      </div>
      {overdue > 0 && (
        <p className="error" role="status">
          Просрочено квитанций: {overdue}
        </p>
      )}
      <h2>Начислено по месяцам</h2>
      <BarChart rows={(r?.monthly_totals.data as MonthRow[] | undefined) ?? []} />
      <h2>По адресам</h2>
      <ul className="list">
        {addresses.map((a) => (
          <li key={a.id} className="card">
            <div>
              <div className="card-title">{a.name}</div>
              <div className="muted">
                квитанций: {a.receipts}
                {a.alias ? ` · ${a.alias}` : ""}
              </div>
            </div>
            <div className="card-side">
              <div className="card-amount">{money(a.due)}</div>
              <span className="muted">к оплате</span>
            </div>
          </li>
        ))}
      </ul>
      <DataMeta state={state} />
    </section>
  );
}

const FILTERS: { label: string; status: Status | null }[] = [
  { label: "Все", status: null },
  { label: "К оплате", status: "new" },
  { label: "Просрочено", status: "overdue" },
  { label: "Оплачено", status: "paid" },
];

export function Receipts() {
  const [status, setStatus] = useState<Status | null>(null);
  const state = useQueryGroup([{ name: "receipts", args: { status } }]);
  const items = (state.group?.results.receipts.data as Receipt[] | undefined) ?? [];
  return (
    <section>
      <h1>Квитанции</h1>
      <div className="chips" role="group" aria-label="Фильтр по статусу">
        {FILTERS.map((f) => (
          <button
            key={f.label}
            type="button"
            className={`chip${f.status === status ? " chip-on" : ""}`}
            aria-pressed={f.status === status}
            onClick={() => setStatus(f.status)}
          >
            {f.label}
          </button>
        ))}
      </div>
      <ul className="list">
        {items.map((it) => (
          <li key={it.id}>
            <a href={`#/receipt/${it.id}`} className="card card-link">
              <div>
                <div className="card-title">{it.provider ?? it.service ?? "Квитанция"}</div>
                <div className="muted">
                  {it.address}
                  {it.period ? ` · ${periodLabel(it.period)}` : ""}
                </div>
              </div>
              <div className="card-side">
                <div className="card-amount">{it.amount == null ? "—" : money(it.amount)}</div>
                <span className={`badge badge-${it.status}`}>{statusLabel(it.status)}</span>
              </div>
            </a>
          </li>
        ))}
      </ul>
      {state.group && items.length === 0 && <p className="muted">Нет квитанций с таким статусом</p>}
      <DataMeta state={state} />
    </section>
  );
}

function DetailRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <li className="detail-row">
      <span className="muted">{label}</span>
      <span className="detail-value">{value}</span>
    </li>
  );
}

export function ReceiptDetail({ id }: { id: number }) {
  const state = useQueryGroup([
    { name: "receipt", args: { id } },
    { name: "receipt_services", args: { id } },
  ]);
  const r = state.group?.results;
  const rec = r?.receipt.data as ReceiptDetailData | undefined;
  const services = (r?.receipt_services.data as ServiceLine[] | undefined) ?? [];
  return (
    <section>
      <a className="back" href="#/receipts">
        ← К списку
      </a>
      <h1>{rec ? (rec.provider ?? rec.service ?? "Квитанция") : "Квитанция"}</h1>
      {rec ? (
        <>
          <div className="tiles">
            <Tile
              label={rec.period ? `Сумма · ${periodLabel(rec.period)}` : "Сумма"}
              value={rec.amount == null ? "—" : money(rec.amount)}
              tone={rec.status === "overdue" ? "warn" : undefined}
            />
          </div>
          <ul className="detail">
            <DetailRow
              label="Статус"
              value={<span className={`badge badge-${rec.status}`}>{statusLabel(rec.status)}</span>}
            />
            {rec.payer && <DetailRow label="Плательщик" value={rec.payer} />}
            {rec.address && <DetailRow label="Адрес" value={rec.address} />}
            {rec.provider && <DetailRow label="Поставщик" value={rec.provider} />}
            {rec.service && <DetailRow label="Тип услуги" value={rec.service} />}
            {rec.period && <DetailRow label="Период" value={periodLabel(rec.period)} />}
            {rec.receipt_date && <DetailRow label="Дата квитанции" value={dateLabel(rec.receipt_date)} />}
            {rec.account_number && <DetailRow label="Лицевой счёт" value={rec.account_number} />}
            {rec.amount_paid != null && <DetailRow label="Оплачено" value={money(rec.amount_paid)} />}
          </ul>
          {rec.has_file === 1 && (
            <DownloadButton label="Скачать PDF квитанции" source={{ name: "receipt_file", args: { id: rec.id } }} />
          )}
          {services.length > 0 && (
            <>
              <h2>Начисления по услугам</h2>
              <ul className="list">
                {services.map((s, i) => (
                  <li key={i} className="card">
                    <div>
                      <div className="card-title">{s.name ?? "Услуга"}</div>
                      <div className="muted">
                        {s.volume != null && s.tariff != null
                          ? `${s.volume} × ${s.tariff}${s.unit ? ` ${s.unit}` : ""}`
                          : (s.unit ?? "")}
                      </div>
                    </div>
                    <div className="card-side">
                      <div className="card-amount">{s.amount == null ? "—" : money(s.amount)}</div>
                    </div>
                  </li>
                ))}
              </ul>
            </>
          )}
        </>
      ) : (
        <p className="muted">Загрузка…</p>
      )}
      <DataMeta state={state} />
    </section>
  );
}
