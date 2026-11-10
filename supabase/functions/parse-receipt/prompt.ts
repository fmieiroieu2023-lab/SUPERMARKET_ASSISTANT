// Prompt, output schema and the Claude call for reading a receipt. Kept apart from index.ts so the
// receipt-eval tool (tools/receipt-eval) can reuse exactly the same prompt.
// Output is forced through a tool call ("record_receipt"): the model must return JSON matching the schema.

export const SMALL_MODEL = "claude-haiku-5-5";   // ~$0.001 per receipt
export const LARGE_MODEL = "claude-sonnet-5-5";  // retry once with this when the lines don't add up (~$0.02)

export type Refs = { categories: { id: string; name_es: string; is_food: boolean }[]; ingredients: { id: string; name_es: string }[] };
export type Line = {
  raw_text: string; name_guess: string; name_en: string; category_guess: string | null; ingredient_guess: string | null;
  printed_qty: number; printed_unit: "pack" | "g" | "ml"; line_total_cents: number; kind: "item" | "discount" | "refund";
};
export type Parsed = {
  chain: string; store_label: string | null; purchased_at: string | null; ticket_number: string | null;
  lines: Line[]; total_cents: number;
};

export const SCHEMA = {
  type: "object",
  properties: {
    chain: { type: "string", enum: ["mercadona", "carrefour", "supercor", "other"] },
    store_label: { type: ["string", "null"], description: "Store address or name as printed" },
    purchased_at: { type: ["string", "null"], description: "Local time printed on the ticket, YYYY-MM-DDTHH:MM" },
    ticket_number: { type: ["string", "null"], description: "Ticket / factura simplificada number, as printed" },
    lines: {
      type: "array",
      items: {
        type: "object",
        properties: {
          raw_text: { type: "string", description: "The line's product text exactly as printed" },
          name_guess: { type: "string", description: "Plain Spanish product name, e.g. 'Leche semidesnatada'" },
          name_en: { type: "string", description: "The same product in plain English, e.g. 'Semi-skimmed milk'" },
          category_guess: { type: ["string", "null"], description: "One category id from the list, or null" },
          ingredient_guess: { type: ["string", "null"], description: "One ingredient id from the list, or null for non-food" },
          printed_qty: { type: "number", description: "Packs as printed (2 x LECHE -> 2), or grams for weighed lines" },
          printed_unit: { type: "string", enum: ["pack", "g", "ml"] },
          line_total_cents: { type: "integer", description: "Line total in cents; negative for discounts and refunds" },
          kind: { type: "string", enum: ["item", "discount", "refund"] },
        },
        required: ["raw_text", "name_guess", "name_en", "category_guess", "ingredient_guess", "printed_qty", "printed_unit", "line_total_cents", "kind"],
      },
    },
    total_cents: { type: "integer", description: "The ticket's TOTAL in cents" },
  },
  required: ["chain", "store_label", "purchased_at", "ticket_number", "lines", "total_cents"],
};

export function systemPrompt(refs: Refs): string {
  const cats = refs.categories.map((c) => `${c.id} (${c.name_es}${c.is_food ? "" : ", non-food"})`).join("; ");
  const ings = refs.ingredients.map((i) => `${i.id}=${i.name_es}`).join("; ");
  return `You read Spanish supermarket receipts (Mercadona, Carrefour, Supercor and others) from photos and record them with the record_receipt tool.

Rules:
- Money is integer cents. Spanish decimal commas: "2,33" -> 233. Never invent amounts.
- Counted items are packs as printed: "2 x LECHE SEMI" or a quantity column of 2 -> printed_qty 2, printed_unit "pack", line_total_cents = the line's total (not the unit price). Never multiply by pack size.
- Weighed lines ("1,234 kg x 1,89 €/kg") -> printed_qty in grams (1234), printed_unit "g", line_total_cents = the line total.
- Multi-buy or promo discounts ("2ª ud. 70%", "DESCUENTO", "AHORRO") -> a separate line with kind "discount" and a negative amount. Returns -> kind "refund", negative.
- If photos overlap, output each line once. Skip subtotal, VAT breakdown, payment, change and card lines.
- Never output card numbers, loyalty ids or personal data.
- name_guess is the product in plain Spanish; name_en is the same product in plain English (no brand unless it matters).
- total_cents is the TOTAL the customer paid. The lines (with discounts) should add up to it; read again carefully if they don't.
- purchased_at: the date and time printed on the ticket, as local time "YYYY-MM-DDTHH:MM"; null if not readable.
- category_guess must be one id from this list, or null: ${cats}
- ingredient_guess must be one id from this list, or null for non-food or when nothing fits: ${ings}`;
}

export type CallResult = { parsed: Parsed; model: string; usage: unknown };

export async function callClaude(apiKey: string, model: string, refs: Refs, files: { media_type: string; data: string }[]): Promise<CallResult> {
  const content: unknown[] = files.map((f) =>
    f.media_type === "application/pdf"
      ? { type: "document", source: { type: "base64", media_type: f.media_type, data: f.data } }
      : { type: "image", source: { type: "base64", media_type: f.media_type, data: f.data } });
  content.push({ type: "text", text: files.length > 1
    ? `These ${files.length} photos are sections of one receipt, top to bottom. Record it.`
    : "Record this receipt." });

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model,
      max_tokens: 8000,
      system: [{ type: "text", text: systemPrompt(refs), cache_control: { type: "ephemeral" } }],
      tools: [{ name: "record_receipt", description: "Record the receipt's lines and total.", input_schema: SCHEMA }],
      tool_choice: { type: "tool", name: "record_receipt" },
      messages: [{ role: "user", content }],
    }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`CLAUDE_${res.status}: ${body?.error?.message ?? "request failed"}`);
  const tool = (body?.content ?? []).find((b: { type: string }) => b.type === "tool_use");
  if (!tool?.input) throw new Error("CLAUDE_NO_OUTPUT");
  return { parsed: tool.input as Parsed, model, usage: body.usage };
}

// Only used to decide whether to retry with the larger model. The binding sum check is confirm_purchase (SQL).
export const linesAddUp = (p: Parsed) =>
  Array.isArray(p.lines) && p.lines.reduce((s, l) => s + (Number(l.line_total_cents) || 0) * (l.kind === "item" ? 1 : l.line_total_cents < 0 ? 1 : -1), 0) === p.total_cents;
