// English first, Spanish underneath (Francisco, 2026-11-10). Display only.
// Loads the English and Spanish names of categories, ingredients and your products once, then looks them up by id.
import { useEffect, useState } from "react";
import { supabase } from "./supabase";

export type Names = { en: string; es: string | null };
type Prod = { en: string | null; es: string; ing: string | null };
let cats = new Map<string, Names>();
let ings = new Map<string, Names>();
let prods = new Map<string, Prod>();
let loaded = false;
let inflight: Promise<void> | null = null;
const subs = new Set<() => void>();

export function loadNames(force = false): Promise<void> {
  if (inflight) return inflight;
  if (loaded && !force) return Promise.resolve();
  inflight = (async () => {
    const [c, i, p] = await Promise.all([
      supabase.from("categories").select("id,name_es,name_en"),
      supabase.from("ingredients").select("id,name_es,name_en"),
      supabase.from("products").select("id,name,name_en,ingredient_id"),
    ]);
    if (!c.error) cats = new Map((c.data as { id: string; name_es: string; name_en: string | null }[]).map((x) => [x.id, { en: x.name_en ?? x.name_es, es: x.name_es }]));
    if (!i.error) ings = new Map((i.data as { id: string; name_es: string; name_en: string }[]).map((x) => [x.id, { en: x.name_en, es: x.name_es }]));
    if (!p.error) prods = new Map((p.data as { id: string; name: string; name_en: string | null; ingredient_id: string | null }[]).map((x) => [x.id, { en: x.name_en, es: x.name, ing: x.ingredient_id }]));
    loaded = true;
    subs.forEach((f) => f());
  })().finally(() => { inflight = null; });
  return inflight;
}

const cap = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);
export const catName = (id: string | null | undefined): Names =>
  (id && cats.get(id)) || { en: id === "discounts" ? "Discounts" : id === "unclassified" ? "Unclassified" : cap(id ?? ""), es: null };
export const ingName = (id: string | null | undefined): Names | null => (id ? ings.get(id) ?? null : null);
// A product: its English name, else its ingredient's, else the receipt name.
export function prodName(id: string | null | undefined, fallback: string): Names {
  const p = id ? prods.get(id) : undefined;
  if (!p) return { en: fallback, es: null };
  return { en: p.en ?? (p.ing ? ings.get(p.ing)?.en : undefined) ?? p.es, es: p.es };
}
// What a shopping-list row is: product, else ingredient, else the typed label.
export function itemName(productId: string | null, ingredientId: string | null, label: string): Names {
  if (productId && prods.has(productId)) return prodName(productId, label);
  const i = ingName(ingredientId);
  return i ? { en: i.en, es: i.es } : { en: label, es: null };
}
export const allIngredients = () => [...ings.entries()];
export const allProducts = () => [...prods.entries()];

// Re-render a component when names arrive.
export function useNames() {
  const [, bump] = useState(0);
  useEffect(() => { const f = () => bump((n) => n + 1); subs.add(f); void loadNames(); return () => { subs.delete(f); }; }, []);
}

const norm = (s: string) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").trim();
// English on top; the Spanish name small underneath when it says something different.
export function Name({ n, strong = true }: { n: Names; strong?: boolean }) {
  const show = n.es && norm(n.es) !== norm(n.en);
  return <>{strong ? <strong>{n.en}</strong> : <span>{n.en}</span>}{show && <span className="es">{n.es}</span>}</>;
}
