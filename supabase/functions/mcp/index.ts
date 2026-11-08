// Claude connector (MCP over Streamable HTTP). Step 2: read tools only.
// Why a hand-written JSON-RPC loop: it is ~100 lines and avoids an MCP SDK dependency.
// The one dependency, supabase-js, is needed to verify the token and to call the database as the user.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const RESOURCE = `${SUPABASE_URL}/functions/v1/mcp`;
const METADATA_URL = `${RESOURCE}/.well-known/oauth-protected-resource`;
const VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version, mcp-session-id",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Expose-Headers": "WWW-Authenticate",
};
const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json", ...extra } });
const unauthorized = () =>
  json({ error: "unauthorized" }, 401, { "WWW-Authenticate": `Bearer resource_metadata="${METADATA_URL}"` });

const TOOLS = [
  {
    name: "get_overview",
    description:
      "One-call snapshot of the pantry: how many items are expired, expiring within 3 days, need a check, or are unconfirmed, plus today's date (Madrid). Call this first.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_pantry",
    description:
      "Lots in the pantry with quantity left, effective expiry date, days left (computed on the server) and state. Default: items that are in date or to be checked, soonest expiry first.",
    inputSchema: {
      type: "object",
      properties: {
        location: { type: "string", enum: ["fridge", "freezer", "pantry"] },
        category: { type: "string", description: "Category id, e.g. fresh_meat, dairy_chilled, dry_goods" },
        state: { type: "string", enum: ["ok", "check", "expired", "unconfirmed", "finished"] },
        expiring_within_days: { type: "integer", minimum: 0 },
        limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
];

type Db = ReturnType<typeof createClient>;

async function callTool(db: Db, name: string, args: Record<string, unknown>) {
  if (name === "get_overview") return await db.rpc("get_overview");
  if (name === "list_pantry") {
    return await db.rpc("list_pantry", {
      p_location: args.location ?? null,
      p_category: args.category ?? null,
      p_state: args.state ?? null,
      p_expiring_within_days: args.expiring_within_days ?? null,
      p_limit: args.limit ?? 50,
    });
  }
  return { data: null, error: { message: `Unknown tool: ${name}` } };
}

async function handle(db: Db, msg: any) {
  const id = msg.id;
  const ok = (result: unknown) => ({ jsonrpc: "2.0", id, result });
  const fail = (code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });
  if (id === undefined) return null; // notification: no reply
  switch (msg.method) {
    case "initialize": {
      const asked = msg.params?.protocolVersion;
      return ok({
        protocolVersion: VERSIONS.includes(asked) ? asked : VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name: "supermarket-assistant", version: "0.1.0" },
      });
    }
    case "ping": return ok({});
    case "tools/list": return ok({ tools: TOOLS });
    case "tools/call": {
      const name = msg.params?.name as string;
      const args = (msg.params?.arguments ?? {}) as Record<string, unknown>;
      const { data, error } = await callTool(db, name, args);
      // One audit row per call. Works even when Claude's writes are switched off.
      const { data: hh } = await db.from("household_members").select("household_id").limit(1).maybeSingle();
      if (hh?.household_id) {
        await db.rpc("log_mcp_call", {
          p_household: hh.household_id, p_tool: name, p_request: crypto.randomUUID(), p_args: args, p_ok: !error,
        });
      }
      if (error) return ok({ isError: true, content: [{ type: "text", text: `Error: ${error.message}` }] });
      return ok({ content: [{ type: "text", text: JSON.stringify(data) }] });
    }
    default: return fail(-32601, `Method not found: ${msg.method}`);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);

  if (url.pathname.endsWith("/.well-known/oauth-protected-resource")) {
    return json({
      resource: RESOURCE,
      authorization_servers: [`${SUPABASE_URL}/auth/v1`],
      bearer_methods_supported: ["header"],
    });
  }

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer /i, "");
  if (!token) return unauthorized();
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: claims, error } = await db.auth.getClaims(token);
  if (error || !claims?.claims?.sub) return unauthorized();

  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, { Allow: "POST" });
  let body: any;
  try { body = await req.json(); } catch { return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400); }

  if (Array.isArray(body)) {
    const out = (await Promise.all(body.map((m) => handle(db, m)))).filter((r) => r !== null);
    return out.length ? json(out) : new Response(null, { status: 202, headers: CORS });
  }
  const reply = await handle(db, body);
  return reply ? json(reply) : new Response(null, { status: 202, headers: CORS });
});
