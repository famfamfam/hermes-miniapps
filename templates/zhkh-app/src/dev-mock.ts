import type { Rpc, Transport } from "@hermes/mobile-sdk";

type Row = {
  id: number;
  address: string;
  provider: string | null;
  service: string | null;
  period: string | null;
  amount: number | null;
  status: "new" | "overdue" | "paid";
};

// Made-up values: the real data lives in the owning skill's database and is never bundled here.
const RECEIPTS: Row[] = [
  { id: 1, address: "Квартира", provider: "УК «Пример»", service: "Содержание", period: "2026-08", amount: 471050, status: "paid" },
  { id: 2, address: "Квартира", provider: "Энергосбыт", service: "Электричество", period: "2026-09", amount: 79025, status: "new" },
  { id: 3, address: "Дача", provider: "Газсбыт", service: "Газ", period: "2026-09", amount: 119000, status: "overdue" },
];

/** In-memory stand-in for the host so the UI can be developed in a plain browser. */
export function createMockTransport(): Transport {
  return {
    async call(rpc: Rpc) {
      if (rpc.op === "hello") return { bridgeVersion: 1, sdkMajor: 1, appId: "zhkh", revision: 1 };
      if (rpc.op === "hostState") {
        return { locale: "ru-RU", theme: "light", timezone: "Europe/Moscow", online: true, preview: false };
      }
      // Files, the picker and "ask Hermes" need the phone itself; a plain browser has none of them.
      if (rpc.op !== "query") throw new Error("this operation needs the phone app");
      const results: Record<string, { data: unknown; completeness: "complete" | "bounded" }> = {};
      const due = RECEIPTS.filter((r) => r.status !== "paid");
      for (const c of rpc.calls) {
        switch (c.name) {
          case "due_total":
            results.due_total = { data: due.reduce((s, r) => s + (r.amount ?? 0), 0), completeness: "complete" };
            break;
          case "due_count":
            results.due_count = { data: due.length, completeness: "complete" };
            break;
          case "overdue_count":
            results.overdue_count = {
              data: RECEIPTS.filter((r) => r.status === "overdue").length,
              completeness: "complete",
            };
            break;
          case "latest_period":
            results.latest_period = { data: "2026-09", completeness: "complete" };
            break;
          case "latest_total":
            results.latest_total = {
              data: RECEIPTS.filter((r) => r.period === "2026-09").reduce((s, r) => s + (r.amount ?? 0), 0),
              completeness: "complete",
            };
            break;
          case "monthly_totals":
            results.monthly_totals = {
              data: ["2026-08", "2026-09"].map((m) => ({
                month: m,
                total: RECEIPTS.filter((r) => r.period === m).reduce((s, r) => s + (r.amount ?? 0), 0),
              })),
              completeness: "bounded",
            };
            break;
          case "by_address":
            results.by_address = {
              data: ["Квартира", "Дача"].map((name, i) => ({
                id: i + 1,
                name,
                alias: null,
                receipts: RECEIPTS.filter((r) => r.address === name).length,
                due: due.filter((r) => r.address === name).reduce((s, r) => s + (r.amount ?? 0), 0),
              })),
              completeness: "bounded",
            };
            break;
          case "receipts":
            results.receipts = {
              data: RECEIPTS.filter((r) => !c.args?.status || r.status === c.args.status),
              completeness: "bounded",
            };
            break;
          case "receipt": {
            const r = RECEIPTS.find((x) => x.id === c.args?.id);
            results.receipt = {
              data: r
                ? {
                    id: r.id,
                    payer: "Иванов И. И.",
                    address: r.address,
                    provider: r.provider,
                    service: r.service,
                    period: r.period,
                    receipt_date: r.period ? `${r.period}-05` : null,
                    account_number: "0000000",
                    amount: r.amount,
                    amount_paid: r.status === "paid" ? r.amount : null,
                    status: r.status,
                    has_file: r.id === 1 ? 0 : 1,
                  }
                : null,
              completeness: "complete",
            };
            break;
          }
          case "receipt_services":
            results.receipt_services = {
              data: [
                { name: "Содержание жилья", amount: 30000, unit: "м²", volume: 52.4, tariff: 5.73 },
                { name: "Вывоз мусора", amount: 9025, unit: "чел.", volume: 2, tariff: 45.12 },
              ],
              completeness: "bounded",
            };
            break;
          default:
            throw new Error(`unknown query ${c.name}`);
        }
      }
      return { dataRev: 1, fetchedAt: new Date().toISOString(), freshness: "live", results };
    },
  };
}
