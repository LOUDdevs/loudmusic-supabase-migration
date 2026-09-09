import { corsHeaders, dbFetch, failure, requestId, success } from "../loudapp-api-v1/_shared.ts";

const MAX_BODY_BYTES = 1024 * 1024;
const MAX_CLOCK_SKEW_SECONDS = 300;

function providerFromPath(request: Request): string {
  const path = new URL(request.url).pathname.split("/").filter(Boolean);
  const index = path.indexOf("loudapp-webhooks-v1");
  return (path[index + 1] ?? path[path.length - 1] ?? "").toLowerCase();
}

function safeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let result = 0;
  for (let index = 0; index < left.length; index += 1) result |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return result === 0;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function signature(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
}

function secretFor(provider: string): string {
  const providerName = provider.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  const variableName = ["LOUDAPP", "WEBHOOK", "SECRET", providerName].join("_");
  return Deno.env.get(variableName) ?? Deno.env.get(["LOUDAPP", "WEBHOOK", "SECRET"].join("_")) ?? "";
}

async function handle(request: Request): Promise<Response> {
  const id = requestId(request);
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request, id) });
  if (request.method !== "POST") return failure(request, "METHOD_NOT_ALLOWED", "Webhook receiver accepts POST only", 405, id);
  const provider = providerFromPath(request);
  if (!/^[a-z][a-z0-9_-]{1,63}$/.test(provider)) return failure(request, "INVALID_PROVIDER", "Webhook provider is invalid", 400, id);
  const length = Number(request.headers.get("Content-Length") ?? 0);
  if (length > MAX_BODY_BYTES) return failure(request, "PAYLOAD_TOO_LARGE", "Webhook body exceeds the API limit", 413, id);
  const rawBody = await request.text();
  if (new TextEncoder().encode(rawBody).byteLength > MAX_BODY_BYTES) return failure(request, "PAYLOAD_TOO_LARGE", "Webhook body exceeds the API limit", 413, id);
  const eventId = request.headers.get("X-Loudmusic-Webhook-Id")?.trim() ?? "";
  const timestamp = request.headers.get("X-Loudmusic-Webhook-Timestamp")?.trim() ?? "";
  const supplied = (request.headers.get("X-Loudmusic-Webhook-Signature") ?? "").replace(/^sha256=/, "").trim().toLowerCase();
  const timestampNumber = Number(timestamp);
  if (!eventId || !/^[0-9]+$/.test(timestamp) || !Number.isFinite(timestampNumber) || Math.abs(Math.floor(Date.now() / 1000) - timestampNumber) > MAX_CLOCK_SKEW_SECONDS) return failure(request, "INVALID_WEBHOOK_TIMESTAMP", "Webhook timestamp is missing or outside the replay window", 401, id);
  const secret = secretFor(provider);
  if (!secret) return failure(request, "WEBHOOK_NOT_CONFIGURED", "This webhook provider is not configured", 503, id);
  const expected = await signature(secret, `${timestamp}.${rawBody}`);
  if (!safeEqual(supplied, expected)) return failure(request, "INVALID_WEBHOOK_SIGNATURE", "Webhook signature verification failed", 401, id);
  let payload: unknown;
  try { payload = JSON.parse(rawBody); } catch { return failure(request, "INVALID_WEBHOOK_BODY", "Webhook body must be valid JSON", 400, id); }
  const existing = await dbFetch(`webhook_events?provider=eq.${encodeURIComponent(provider)}&event_id=eq.${encodeURIComponent(eventId)}&select=id,status&limit=1`);
  if (!existing.ok) return failure(request, "WEBHOOK_LOOKUP_FAILED", "Webhook event lookup failed", 503, id);
  const existingRows = await existing.json() as Array<Record<string, unknown>>;
  if (existingRows.length) return success(request, { accepted: true, duplicate: true, event_id: eventId }, 200, id);
  const inserted = await dbFetch("webhook_events", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=representation" }, body: JSON.stringify({ provider, event_id: eventId, payload, status: "received" }) });
  if (!inserted.ok) return failure(request, "WEBHOOK_PERSIST_FAILED", "Webhook event could not be persisted", 503, id);
  return success(request, { accepted: true, duplicate: false, event_id: eventId }, 202, id);
}

Deno.serve(async (request: Request) => {
  try { return await handle(request); }
  catch (error) {
    const id = requestId(request);
    console.error(JSON.stringify({ request_id: id, error: error instanceof Error ? error.message : String(error) }));
    return failure(request, "INTERNAL_ERROR", "An unexpected webhook error occurred", 500, id);
  }
});
