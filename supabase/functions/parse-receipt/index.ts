// parse-receipt: photos in Storage -> Claude reads them -> a draft purchase the review screen shows.
// Called by the app with the user's own token, so every database call runs under RLS as that user.
// Business rules (validation, matching, duplicate check, confirm) live in SQL: save_receipt_draft / receipt_review.
import { createClient } from "npm:@supabase/supabase-js@2";
import { callClaude, LARGE_MODEL, linesAddUp, SMALL_MODEL, type CallResult, type Refs } from "./prompt.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (status: number, error: string, message = error) => json({ error, message }, status);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_FILES = 4;
// Bytes -> base64 in chunks (a whole photo at once would overflow the argument list).
function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return fail(405, "METHOD_NOT_ALLOWED");

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer /i, "");
  if (!token) return fail(401, "UNAUTHORIZED");
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claims, error: authErr } = await db.auth.getClaims(token);
  if (authErr || !claims?.claims?.sub) return fail(401, "UNAUTHORIZED");

  let body: { purchase_id?: string; paths?: string[] };
  try { body = await req.json(); } catch { return fail(400, "BAD_REQUEST", "Body must be JSON"); }
  const purchaseId = body.purchase_id ?? "";
  const paths = Array.isArray(body.paths) ? body.paths : [];
  if (!UUID.test(purchaseId) || paths.length < 1 || paths.length > MAX_FILES) return fail(400, "BAD_REQUEST", "purchase_id and 1-4 paths are required");
  // Every path must be {household}/{purchase_id}/{file}; Storage RLS checks the household on download.
  const household = paths[0].split("/")[0];
  if (!UUID.test(household) || !paths.every((p) => p.split("/")[0] === household && p.split("/")[1] === purchaseId)) {
    return fail(400, "BAD_REQUEST", "paths must be {household}/{purchase_id}/{file}");
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return fail(500, "NO_API_KEY", "The ANTHROPIC_API_KEY secret is not set on this project");

  // Quota first (also checks membership): a bad day can't run up the API bill.
  const quota = await db.rpc("take_receipt_quota", { p_household: household });
  if (quota.error) return fail(quota.error.message === "QUOTA_EXCEEDED" ? 429 : 403, quota.error.message, quota.error.details ?? quota.error.message);

  // Files, as the user (RLS on storage.objects).
  const files: { media_type: string; data: string }[] = [];
  for (const p of paths) {
    const { data: blob, error } = await db.storage.from("receipts").download(p);
    if (error || !blob) return fail(404, "FILE_NOT_FOUND", p);
    const type = blob.type && blob.type !== "application/octet-stream" ? blob.type
      : p.endsWith(".pdf") ? "application/pdf" : p.endsWith(".png") ? "image/png" : "image/jpeg";
    files.push({ media_type: type, data: toBase64(new Uint8Array(await blob.arrayBuffer())) });
  }

  const [cats, ings] = await Promise.all([
    db.from("categories").select("id,name_es,is_food").order("id"),
    db.from("ingredients").select("id,name_es").order("id"),
  ]);
  if (cats.error || ings.error) return fail(500, "REFS_FAILED", (cats.error ?? ings.error)!.message);
  const refs: Refs = { categories: cats.data, ingredients: ings.data };

  // Small model first; one retry with the larger model if the lines don't add up to the total.
  // If the small model errors, the large one still gets a go.
  let result: CallResult | null = null;
  const attempts: string[] = [];
  let lastErr = "Could not read the receipt";
  try { result = await callClaude(apiKey, SMALL_MODEL, refs, files); attempts.push(SMALL_MODEL); }
  catch (e) { lastErr = e instanceof Error ? e.message : lastErr; attempts.push(`${SMALL_MODEL} failed`); }
  if (!result || !linesAddUp(result.parsed)) {
    try {
      const big = await callClaude(apiKey, LARGE_MODEL, refs, files); attempts.push(LARGE_MODEL);
      if (!result || linesAddUp(big.parsed)) result = big;   // else keep the small answer; review shows what's missing
    } catch (e) { lastErr = e instanceof Error ? e.message : lastErr; }
  }
  if (!result) return fail(502, "PARSE_FAILED", lastErr);

  const parse = { ...result.parsed, _meta: { model: result.model, attempts, usage: result.usage, files: paths.length } };
  const saved = await db.rpc("save_receipt_draft", {
    p_purchase: purchaseId, p_household: household, p_paths: paths, p_parse: parse,
    p_source: files.some((f) => f.media_type === "application/pdf") ? "receipt_file" : "receipt_photo",
  });
  if (saved.error) return fail(400, saved.error.message, saved.error.details ?? saved.error.message);
  return json({ review: saved.data, quota_left: quota.data });
});
