import type { Rpc, Transport } from "@hermes/mobile-sdk";

type Row = { id: number; supplier: string; period: string; amount: number; status: "paid" | "unpaid" };

let BILLS: Row[] = [
  { id: 1, supplier: "Water", period: "2026-08-01", amount: 130000, status: "paid" },
  { id: 2, supplier: "Electricity", period: "2026-09-01", amount: 471000, status: "unpaid" },
  { id: 3, supplier: "Water", period: "2026-10-01", amount: 119000, status: "unpaid" },
];

/** In-memory stand-in for the host so the UI can be developed in a plain browser. */
export function createMockTransport(): Transport {
  return {
    async call(rpc: Rpc) {
      if (rpc.op === "hello") return { bridgeVersion: 1, sdkMajor: 1, appId: "utilities", revision: 1 };
      if (rpc.op === "hostState") {
        return { locale: "en-US", theme: "light", timezone: "UTC", online: true, preview: false };
      }
      // The buttons that write work here on this list, like on the phone (which also asks before a delete).
      if (rpc.op === "mutate") return mutate(rpc.name, rpc.args ?? {});
      // Files, the picker and "ask Hermes" need the phone itself; a plain browser has none of them.
      if (rpc.op !== "query") throw new Error("this operation needs the phone app");
      const results: Record<string, { data: unknown; completeness: "complete" | "bounded" }> = {};
      for (const c of rpc.calls) {
        const unpaid = BILLS.filter((b) => b.status === "unpaid");
        switch (c.name) {
          case "bills":
            results.bills = {
              data: BILLS.filter((b) => !c.args?.status || b.status === c.args.status),
              completeness: "bounded",
            };
            break;
          case "month_total":
            results.month_total = { data: 119000, completeness: "complete" };
            break;
          case "unpaid_total":
            results.unpaid_total = { data: unpaid.reduce((s, b) => s + b.amount, 0), completeness: "complete" };
            break;
          case "unpaid_count":
            results.unpaid_count = { data: unpaid.length, completeness: "complete" };
            break;
          case "monthly_totals":
            results.monthly_totals = {
              data: BILLS.map((b) => ({ month: b.period.slice(0, 7), total: b.amount })),
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

type Args = Record<string, string | number | boolean | null>;

function mutate(name: string, args: Args) {
  const done = (rowsAffected: number, lastInsertId: number | null = null) => ({
    done: true as const,
    rowsAffected,
    lastInsertId,
    replayed: false,
  });
  switch (name) {
    case "add_bill": {
      const id = Math.max(0, ...BILLS.map((b) => b.id)) + 1;
      BILLS = [
        ...BILLS,
        {
          id,
          supplier: String(args.supplier),
          period: String(args.period),
          amount: Number(args.amount),
          status: args.status === "paid" ? "paid" : "unpaid",
        },
      ];
      return done(1, id);
    }
    case "mark_paid": {
      const hit = BILLS.filter((b) => b.id === args.id);
      BILLS = BILLS.map((b) => (b.id === args.id ? { ...b, status: "paid" as const } : b));
      return done(hit.length);
    }
    case "delete_bill": {
      if (!window.confirm("Delete the bill? This cannot be undone.")) return { done: false as const };
      const before = BILLS.length;
      BILLS = BILLS.filter((b) => b.id !== args.id);
      return done(before - BILLS.length);
    }
    default:
      throw Object.assign(new Error(`unknown mutation ${name}`), { code: "unknown_mutation" });
  }
}