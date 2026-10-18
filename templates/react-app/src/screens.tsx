import { useState } from "react";
import { useMutation, useQueryGroup } from "@hermes/mobile-sdk";
import { ActionButton, BarChart, DataMeta, Tile, type MonthRow } from "./components";
import { money, periodLabel, toMinor } from "./format";

interface Bill {
  id: number;
  supplier: string;
  period: string;
  amount: number;
  status: "paid" | "unpaid";
}

export function Overview() {
  const state = useQueryGroup([
    { name: "month_total" },
    { name: "unpaid_total" },
    { name: "unpaid_count" },
    { name: "monthly_totals" },
  ]);
  const r = state.group?.results;
  return (
    <section>
      <h1>Overview</h1>
      <div className="tiles">
        <Tile label="This month" value={r ? money(r.month_total.data as number) : "…"} />
        <Tile
          label={`Unpaid${r ? ` · ${r.unpaid_count.data as number}` : ""}`}
          value={r ? money(r.unpaid_total.data as number) : "…"}
          tone="warn"
        />
      </div>
      <h2>Monthly totals</h2>
      <BarChart rows={(r?.monthly_totals.data as MonthRow[] | undefined) ?? []} />
      <DataMeta state={state} />
    </section>
  );
}

const FILTERS: { label: string; status: "paid" | "unpaid" | null }[] = [
  { label: "All", status: null },
  { label: "Unpaid", status: "unpaid" },
  { label: "Paid", status: "paid" },
];

export function Bills() {
  const [status, setStatus] = useState<"paid" | "unpaid" | null>(null);
  const state = useQueryGroup([{ name: "bills", args: { status } }]);
  const bills = (state.group?.results.bills.data as Bill[] | undefined) ?? [];
  return (
    <section>
      <h1>Bills</h1>
      <div className="chips" role="group" aria-label="Filter by status">
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
        {bills.map((b) => (
          <li key={b.id} className="card">
            <div>
              <div className="card-title">{b.supplier}</div>
              <div className="muted">{periodLabel(b.period)}</div>
              <div className="card-actions">
                {b.status === "unpaid" && <ActionButton label="Mark paid" mutation="mark_paid" args={{ id: b.id }} />}
                <ActionButton label="Delete" mutation="delete_bill" args={{ id: b.id }} tone="danger" />
              </div>
            </div>
            <div className="card-side">
              <div className="card-amount">{money(b.amount)}</div>
              <span className={`badge badge-${b.status}`}>{b.status === "paid" ? "paid" : "unpaid"}</span>
            </div>
          </li>
        ))}
      </ul>
      {state.group && bills.length === 0 && <p className="muted">No bills with this status</p>}
      <DataMeta state={state} />
    </section>
  );
}

/** A form that saves: the "add_bill" mutation of definitions.json. The phone writes it to the app's own database. */
export function AddBill() {
  const [supplier, setSupplier] = useState("");
  const [period, setPeriod] = useState("");
  const [amount, setAmount] = useState("");
  const [status, setStatus] = useState("unpaid");
  const [saved, setSaved] = useState(false);
  const save = useMutation("add_bill");
  const minor = toMinor(amount);
  const ready = supplier.trim() !== "" && period !== "" && minor !== null && minor > 0;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    setSaved(false);
    void save.run({ supplier: supplier.trim(), period, amount: minor, status }).then((result) => {
      if (!result?.done) return; // failed (shown below) or declined: keep what was typed
      setSaved(true);
      setSupplier("");
      setPeriod("");
      setAmount("");
    });
  };

  return (
    <section>
      <h1>New bill</h1>
      <form className="form" onSubmit={submit}>
        <label>
          Supplier
          <input value={supplier} onChange={(e) => setSupplier(e.target.value)} autoComplete="off" />
        </label>
        <label>
          Period
          <input type="date" value={period} onChange={(e) => setPeriod(e.target.value)} />
        </label>
        <label>
          Amount
          <input
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value.replace(/[^\d.,]/g, ""))}
            autoComplete="off"
          />
        </label>
        <label>
          Status
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="unpaid">Unpaid</option>
            <option value="paid">Paid</option>
          </select>
        </label>
        <button type="submit" className="primary" disabled={!ready || save.pending}>
          {save.pending ? "Saving…" : "Save"}
        </button>
        {save.error && (
          <p className="error" role="alert">
            {save.error.message}
          </p>
        )}
        {saved && (
          <p className="muted" role="status">
            Saved. It is in the Bills list.
          </p>
        )}
      </form>
    </section>
  );
}