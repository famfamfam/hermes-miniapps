/** Amounts are integers in minor units (kopecks); formatting is the UI's job (ADR-003 §9). */
const rub = new Intl.NumberFormat("ru-RU", { style: "currency", currency: "RUB", maximumFractionDigits: 0 });
const month = new Intl.DateTimeFormat("ru-RU", { month: "short", year: "2-digit" });
const longMonth = new Intl.DateTimeFormat("ru-RU", { month: "long", year: "numeric" });
const day = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long", year: "numeric" });

export function money(minor: number): string {
  return rub.format(minor / 100);
}

/** "2026-09" -> "сент. 26" */
export function monthLabel(ym: string): string {
  const [y, m] = ym.split("-").map(Number);
  return month.format(new Date(y, m - 1, 1));
}

export function periodLabel(isoDate: string): string {
  const [y, m] = isoDate.split("-").map(Number);
  return longMonth.format(new Date(y, m - 1, 1));
}

/** "2026-09-30" -> "30 сентября 2026 г." */
export function dateLabel(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return day.format(new Date(y, m - 1, d));
}

export function timeLabel(iso: string): string {
  return new Date(iso).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}
