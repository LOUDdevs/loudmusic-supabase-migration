// Conversational Fletcher Method funnel setup. Replaces the manual
// "fill in these fields" form: a short back-and-forth chat (one question at
// a time, same spirit as the workspace-kit Claude Project onboarding flow)
// collects the handful of real facts a template needs, then the caller
// (index.ts) instantiates the funnel from the extracted answers. Reuses the
// OpenAI-then-OpenRouter call pattern already established in
// artist-bio-survey/index.ts.

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const OPENAI_MODEL = Deno.env.get("FUNNEL_BUILDER_OPENAI_MODEL") || "gpt-4o-mini";
const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY") ?? "";
const OPENROUTER_MODEL = Deno.env.get("FUNNEL_BUILDER_OPENROUTER_MODEL") || "openai/gpt-4o-mini";

export type ChatMessage = { role: "system" | "user" | "assistant"; content: string };
export type FieldDef = { key: string; label: string; type: "text" | "datetime" | "number" };

export const TEMPLATE_FIELDS: Record<string, FieldDef[]> = {
  ww: [
    { key: "businessName", label: "their business or brand name", type: "text" },
    { key: "presenterName", label: "who is presenting the workshop (their name)", type: "text" },
    { key: "presenterCredLine", label: "a one-line credibility statement about the presenter — experience, results, a number worth bragging about", type: "text" },
    { key: "workshopDate", label: "the date and time of the next live workshop", type: "datetime" },
  ],
  zss: [
    { key: "businessName", label: "their business or brand name", type: "text" },
    { key: "presenterName", label: "who runs the paid strategy sessions (their name)", type: "text" },
    { key: "presenterCredLine", label: "a one-line credibility statement about the presenter — experience, results, a number worth bragging about", type: "text" },
    { key: "price", label: "the price of the paid strategy session, in US dollars (a plain number)", type: "number" },
  ],
};

const TEMPLATE_LABEL: Record<string, string> = { ww: "Winning Workshop", zss: "Zero Selling System" };

function buildSystemPrompt(templateKey: string): string {
  const fields = TEMPLATE_FIELDS[templateKey] ?? [];
  const fieldList = fields.map((f, i) => `${i + 1}. "${f.key}" (${f.type}) — ${f.label}`).join("\n");
  return [
    `You are a friendly onboarding assistant setting up a "${TEMPLATE_LABEL[templateKey] ?? templateKey}" marketing funnel for a small business owner.`,
    `Every page of the funnel — headlines, copy, layout, CTAs — is already built. You are ONLY collecting a handful of real facts so it can be personalized. Do not ask about design, page structure, or anything the funnel already has.`,
    `Ask exactly ONE short, conversational question at a time. Never list multiple questions in one message. Keep it warm and brief — one or two sentences.`,
    `You must collect these fields, in this order, skipping any the user has already answered earlier in the conversation:`,
    fieldList,
    `Respond with ONLY a single JSON object — no prose outside the JSON — in exactly one of these two shapes:`,
    `- Still collecting: {"type":"question","field":"<field key from the list above>","text":"<the next question to ask, in your own words>"}`,
    `- All fields collected: {"type":"done","variables":{"<field key>":"<value>", ...}} including every field from the list above, using those exact keys.`,
    `Rules: never invent an answer the user did not give. If an answer is unclear, ask a brief follow-up for that same field (still "type":"question"). For "datetime" fields, convert the user's answer to an ISO 8601 datetime string (assume the current year if omitted, and a reasonable time if only a date is given); for "number" fields, extract a plain number with no currency symbol or commas.`,
  ].join("\n\n");
}

async function callOpenAI(messages: ChatMessage[]): Promise<Record<string, unknown>> {
  if (!OPENAI_API_KEY) throw new Error("openai_key_missing");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${OPENAI_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: OPENAI_MODEL, messages, temperature: 0.4, max_tokens: 400, response_format: { type: "json_object" } }),
      signal: controller.signal,
    });
    const result = await res.json().catch(() => null);
    if (!res.ok) throw new Error(result?.error?.code || result?.error?.type || `openai_http_${res.status}`);
    const content = String(result?.choices?.[0]?.message?.content ?? "").trim();
    if (!content) throw new Error("openai_empty_output");
    return JSON.parse(content);
  } finally {
    clearTimeout(timeout);
  }
}

async function callOpenRouter(messages: ChatMessage[]): Promise<Record<string, unknown>> {
  if (!OPENROUTER_API_KEY) throw new Error("openrouter_key_missing");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${OPENROUTER_API_KEY}`, "Content-Type": "application/json", "HTTP-Referer": "https://loudmusic.io", "X-Title": "LOUDmusic Funnel Builder" },
      body: JSON.stringify({ model: OPENROUTER_MODEL, messages, temperature: 0.4, max_tokens: 400, response_format: { type: "json_object" } }),
      signal: controller.signal,
    });
    const result = await res.json().catch(() => null);
    if (!res.ok) throw new Error(result?.error?.code || result?.error?.message || `openrouter_http_${res.status}`);
    const content = String(result?.choices?.[0]?.message?.content ?? "").trim();
    if (!content) throw new Error("openrouter_empty_output");
    return JSON.parse(content);
  } finally {
    clearTimeout(timeout);
  }
}

export type TurnResult = { type: "question"; field?: string; text: string } | { type: "done"; variables: Record<string, unknown> };

// Runs one turn of the conversation: given the full message history (no
// system prompt included — this function prepends it), asks the LLM for
// either the next question or the final extracted variables.
export async function runFunnelBuilderTurn(templateKey: string, history: ChatMessage[]): Promise<TurnResult> {
  const messages: ChatMessage[] = [{ role: "system", content: buildSystemPrompt(templateKey) }, ...history];
  let raw: Record<string, unknown>;
  try {
    raw = await callOpenAI(messages);
  } catch (openaiError) {
    console.error("funnel_builder_openai_failed", openaiError instanceof Error ? openaiError.message : openaiError);
    raw = await callOpenRouter(messages);
  }
  if (raw?.type === "done" && raw.variables && typeof raw.variables === "object") {
    return { type: "done", variables: raw.variables as Record<string, unknown> };
  }
  const text = String(raw?.text ?? "").trim();
  if (!text) throw new Error("funnel_builder_no_question");
  return { type: "question", field: typeof raw?.field === "string" ? raw.field : undefined, text };
}

// Coerces collected variable values to the right JS type per field def
// (the LLM returns everything as JSON but numbers/dates sometimes arrive
// as strings) and fills in the template's own defaults for anything the
// model failed to collect, so a funnel is never blocked on a flaky answer.
export function normalizeCollectedVariables(templateKey: string, collected: Record<string, unknown>, defaults: Record<string, unknown>): Record<string, unknown> {
  const fields = TEMPLATE_FIELDS[templateKey] ?? [];
  const out: Record<string, unknown> = { ...defaults };
  for (const field of fields) {
    const value = collected[field.key];
    if (value === undefined || value === null || value === "") continue;
    if (field.type === "number") {
      const num = Number(String(value).replace(/[^0-9.]/g, ""));
      if (!Number.isNaN(num)) out[field.key] = num;
    } else if (field.type === "datetime") {
      const parsed = new Date(String(value));
      out[field.key] = Number.isNaN(parsed.getTime()) ? value : parsed.toISOString();
    } else {
      out[field.key] = value;
    }
  }
  return out;
}
