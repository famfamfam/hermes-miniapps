/**
 * The phone's language decides the kit's own words and the number and date formats: Russian on a Russian phone,
 * English everywhere else. The texts of the screens you write yourself follow the language of the user.
 */
const lang = (typeof navigator !== "undefined" && navigator.language) || "en";
export const isRussian = lang.toLowerCase().startsWith("ru");

/** `tr("по-русски", "in English")`: the kit's own words, by the phone's language. */
export const tr = (russian: string, english: string): string => (isRussian ? russian : english);

/**
 * Amounts are integers in minor units (kopecks, cents); formatting is the UI's job. The default currency follows the
 * language (RUB, USD): pass the data's own code ("EUR", "UAH", ...) when it differs.
 */
export function money(minor: number, currency: string = isRussian ? "RUB" : "USD"): string {
  return new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits: 0 }).format(minor / 100);
}

const month = new Intl.DateTimeFormat(lang, { month: "short", year: "2-digit" });
const longMonth = new Intl.DateTimeFormat(lang, { month: "long", year: "numeric" });

/** What the user typed ("47.10", "47,10", "47") as an amount in minor units (4710); null when it is not an amount. */
export function toMinor(text: string): number | null {
  const m = /^\s*(\d{1,9})(?:[.,](\d{1,2}))?\s*$/.exec(text);
  return m ? Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0")) : null;
}

/** "2026-09" -> "Sep 26" (or "сент. 26"). */
export function monthLabel(ym: string): string {
  const [y, m] = ym.split("-").map(Number);
  return month.format(new Date(y, m - 1, 1));
}

export function periodLabel(isoDate: string): string {
  const [y, m] = isoDate.split("-").map(Number);
  return longMonth.format(new Date(y, m - 1, 1));
}

export function timeLabel(iso: string): string {
  return new Date(iso).toLocaleTimeString(lang, { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}
