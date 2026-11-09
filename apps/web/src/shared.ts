// Small helpers shared by the screens. Display only: no business rule lives here (those are SQL functions).
import { supabase } from "./supabase";

// Raw database errors mean nothing to a shopper; show a short human sentence instead.
const MESSAGES: Record<string, string> = {
  QUOTA_EXCEEDED: "That's the receipt limit for today (20). Try again tomorrow.",
  ALREADY_LOGGED: "This receipt is already logged.",
  SUM_MISMATCH: "The lines don't add up to the ticket total.",
  NEEDS_PACK_SIZE: "One product needs its pack size (for example 1 L). Mark that line as spend only or set it as counted items.",
  UNIT_MISMATCH: "A weighed line doesn't fit a product counted in items. Mark it as spend only, or add how much one weighs.",
  PARSE_FAILED: "Couldn't read the receipt. Try a sharper photo with the whole ticket in view.",
  NO_API_KEY: "Receipt reading isn't set up yet (the API key is missing on the server).",
  FILE_NOT_FOUND: "The photo didn't upload. Please try again.",
  NOT_A_DRAFT: "This receipt was already saved or discarded.",
  DRAFT_HAS_LOTS: "This draft already has pantry items, so it can't be discarded.",
  BAD_CATEGORY: "Choose a type for every new item.",
};
export function friendly(m: string): string {
  const code = Object.keys(MESSAGES).find((k) => m.includes(k));
  if (code) return MESSAGES[code];
  if (/could not find the function|PGRST202|does not exist/i.test(m)) return "This part isn't switched on yet. The database update for receipts still needs to be applied.";
  if (/fetch|network|load failed/i.test(m)) return "No connection. Check your internet and try again.";
  if (/jwt|auth/i.test(m)) return "Your session ended. Please sign in again.";
  return "Something went wrong. Please try again.";
}

export const euro = (cents: number | null | undefined) =>
  cents == null ? "–" : (cents / 100).toLocaleString("en-IE", { style: "currency", currency: "EUR" });

// "2026-11-07" -> "Sat 7 Nov" (and "today" / "yesterday")
export function dayLabel(iso: string): string {
  const today = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Madrid" });
  const y = new Date(Date.now() - 864e5).toLocaleDateString("sv-SE", { timeZone: "Europe/Madrid" });
  if (iso === today) return "today";
  if (iso === y) return "yesterday";
  return new Date(`${iso}T12:00:00`).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
}
export const monthLabel = (ym: string) => new Date(`${ym}-15T12:00:00`).toLocaleDateString("en-GB", { month: "long", year: "numeric" });

export const CHAINS: { id: string; name: string }[] = [
  { id: "mercadona", name: "Mercadona" }, { id: "carrefour", name: "Carrefour" }, { id: "supercor", name: "Supercor" }, { id: "other", name: "Other shop" },
];
export const chainName = (id: string) => CHAINS.find((c) => c.id === id)?.name ?? id;

export async function householdId(): Promise<string> {
  const { data, error } = await supabase.from("household_members").select("household_id").limit(1).single();
  if (error || !data) throw new Error(error?.message ?? "NO_HOUSEHOLD");
  return data.household_id as string;
}

// Edge Function errors arrive as a Response inside error.context; pull out our {error, message}.
export async function invokeError(e: unknown): Promise<string> {
  const ctx = (e as { context?: Response })?.context;
  if (ctx && typeof ctx.json === "function") {
    try { const b = await ctx.json(); return `${b.error ?? ""} ${b.message ?? ""}`; } catch { /* fall through */ }
  }
  return e instanceof Error ? e.message : String(e);
}
