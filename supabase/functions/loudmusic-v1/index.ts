import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const VERSION = "1.0.0";
const ALLOWED_ORIGINS = new Set(["https://stg.loudmusic.io", "https://loudmusic.io", "http://localhost:5175", "http://localhost:5174"]);

const legacyFeatures = [
  { name: "Release and distribution", status: "mapped", note: "DDEX Wizard + LabelGrid workflows are inventoried; provider writes stay behind a reviewed server integration." },
  { name: "Audio intelligence", status: "mapped", note: "Audio tagging, ACR Cloud recognition, and Matchering are identified; worker contracts must be reconciled before migration." },
  { name: "Artist workspace", status: "mapped", note: "Spotify onboarding, EPK profiles, private files, royalties, storage, and community/messaging are identified." },
  { name: "Commerce and verification", status: "mapped", note: "WooCommerce, Stripe, FastCredit, and Plaid are identified; raw card data will never enter LOUDmusic systems." },
  { name: "Support and CRM", status: "connected", note: "Supabase Auth and the existing marketing CRM are live behind this V1 API." },
];

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.has(origin) ? origin : "https://stg.loudmusic.io";
  return { "Access-Control-Allow-Origin": allowed, "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Allow-Credentials": "true", "Vary": "Origin" };
}

function json(request: Request, payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders(request) } });
}

async function dbFetch(path: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", `Bearer ${SERVICE_KEY}`);
  headers.set("Accept-Profile", "marketing");
  headers.set("Content-Profile", "marketing");
  headers.set("Content-Type", "application/json");
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, { ...init, headers });
}

async function readJson(request: Request) {
  try { return await request.json(); } catch { return {}; }
}

async function requireViewer(request: Request) {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return { error: "Authentication required", status: 401 } as const;
  const token = header.slice(7);
  const auth = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!auth.ok) return { error: "Invalid or expired session", status: 401 } as const;
  const user = await auth.json();
  const memberResponse = await dbFetch(`team_members?user_id=eq.${encodeURIComponent(user.id)}&select=role,email&limit=1`);
  const members = memberResponse.ok ? await memberResponse.json() : [];
  if (!members.length) return { error: "Workspace access has not been granted", status: 403 } as const;
  return { user: { id: user.id, email: user.email, name: user.user_metadata?.full_name ?? user.email, role: members[0].role } } as const;
}

async function countRows(table: string) {
  const response = await dbFetch(`${table}${table.includes("?") ? "&" : "?"}select=id&limit=1`, { headers: { Prefer: "count=exact" } });
  const range = response.headers.get("content-range") ?? "*/0";
  const total = Number(range.split("/")[1] ?? 0);
  return Number.isFinite(total) ? total : 0;
}

async function authLogin(request: Request) {
  const body = await readJson(request);
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  if (!email || !password) return json(request, { error: "Email and password are required" }, 400);
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: ANON_KEY, "Content-Type": "application/json" }, body: JSON.stringify({ email, password }) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) return json(request, { error: "Email or password was not accepted" }, 401);
  return json(request, { data: { access_token: payload.access_token, refresh_token: payload.refresh_token, user: payload.user } });
}

async function authRefresh(request: Request) {
  const body = await readJson(request);
  const refreshToken = String(body.refresh_token ?? "");
  if (!refreshToken) return json(request, { error: "Refresh token is required" }, 400);
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, { method: "POST", headers: { apikey: ANON_KEY, "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: refreshToken }) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) return json(request, { error: "Session could not be refreshed" }, 401);
  return json(request, { data: { access_token: payload.access_token, refresh_token: payload.refresh_token } });
}

async function dashboard(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const [contacts, threads, tasks, artists] = await Promise.all([countRows("crm_contacts?deleted_at=is.null"), countRows("crm_communication_threads"), countRows("crm_tasks?completed_at=is.null"), countRows("crm_artists")]);
  const contactsResponse = await dbFetch("crm_contacts?deleted_at=is.null&select=id,display_name,primary_email,primary_phone,lifecycle_stage,lead_source,last_contacted_at,next_follow_up_at,created_at&order=created_at.desc&limit=10");
  const tasksResponse = await dbFetch("crm_tasks?completed_at=is.null&select=id,title,due_at,priority&order=due_at.asc.nullslast&limit=10");
  return json(request, { data: { viewer: viewer.user, counts: { contacts, threads, tasks, artists }, recentContacts: contactsResponse.ok ? await contactsResponse.json() : [], recentTasks: tasksResponse.ok ? await tasksResponse.json() : [], legacyFeatures } });
}

async function contacts(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const query = url.searchParams.get("q")?.trim() ?? "";
  const params = new URLSearchParams({ deleted_at: "is.null", select: "id,display_name,primary_email,primary_phone,lifecycle_stage,lead_source,last_contacted_at,next_follow_up_at,created_at", order: "created_at.desc", limit: "50" });
  if (query) params.set("or", `(display_name.ilike.*${query.replace(/[^a-zA-Z0-9 @._-]/g, "")}*,primary_email.ilike.*${query.replace(/[^a-zA-Z0-9 @._-]/g, "")}*)`);
  const response = await dbFetch(`crm_contacts?${params}`);
  return json(request, { data: { contacts: response.ok ? await response.json() : [] } });
}

async function contactDetail(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const [contactResponse, notesResponse, commsResponse] = await Promise.all([
    dbFetch(`crm_contacts?id=eq.${encodeURIComponent(id)}&select=id,display_name,primary_email,primary_phone,lifecycle_stage,lead_source,last_contacted_at,next_follow_up_at,created_at&limit=1`),
    dbFetch(`crm_notes?contact_id=eq.${encodeURIComponent(id)}&select=id,body,created_at&order=created_at.desc&limit=50`),
    dbFetch(`crm_communications?contact_id=eq.${encodeURIComponent(id)}&select=id,body,channel,occurred_at&order=occurred_at.desc&limit=50`),
  ]);
  const contacts = contactResponse.ok ? await contactResponse.json() : [];
  if (!contacts.length) return json(request, { error: "Contact not found" }, 404);
  return json(request, { data: { contact: contacts[0], notes: notesResponse.ok ? await notesResponse.json() : [], communications: commsResponse.ok ? await commsResponse.json() : [] } });
}

async function lead(request: Request) {
  const body = await readJson(request);
  if (String(body.website ?? "").trim()) return json(request, { data: { accepted: true } });
  const name = String(body.name ?? "").trim().slice(0, 160);
  const email = String(body.email ?? "").trim().toLowerCase().slice(0, 240);
  const topic = String(body.topic ?? "General").trim().slice(0, 120);
  const message = String(body.message ?? "").trim().slice(0, 5000);
  if (name.length < 2 || !/^\S+@\S+\.\S+$/.test(email) || message.length < 2) return json(request, { error: "Name, valid email, and message are required" }, 400);
  const existingResponse = await dbFetch(`crm_contacts?primary_email=eq.${encodeURIComponent(email)}&deleted_at=is.null&select=id&limit=1`);
  const existing = existingResponse.ok ? await existingResponse.json() : [];
  const parts = name.split(/\s+/); const first = parts.shift() ?? name; const last = parts.join(" ") || null;
  const fields = { display_name: name, first_name: first, last_name: last, primary_email: email, emails: [{ value: email, type: "work" }], lead_source: "new-site", custom_fields: { inquiry_topic: topic, inquiry_message: message } };
  let contactId: string;
  if (existing[0]?.id) {
    contactId = existing[0].id;
    await dbFetch(`crm_contacts?id=eq.${encodeURIComponent(contactId)}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify(fields) });
  } else {
    const created = await dbFetch("crm_contacts", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(fields) });
    if (!created.ok) return json(request, { error: "Lead could not be saved" }, 500);
    const rows = await created.json(); contactId = rows[0]?.id;
  }
  if (contactId) {
    await Promise.all([
      dbFetch("crm_notes", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ contact_id: contactId, body: `Website inquiry (${topic}): ${message}`, pinned: false }) }),
      dbFetch("crm_activity_logs", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ entity_type: "contact", entity_id: contactId, action: "website_inquiry", metadata: { topic, source: "new-site" } }) }),
    ]);
  }
  return json(request, { data: { accepted: true } }, 202);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request) });
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const marker = segments.indexOf("loudmusic-v1");
  const path = "/" + (marker >= 0 ? segments.slice(marker + 1).join("/") : segments.join("/"));
  try {
    if (request.method === "GET" && path === "/health") return json(request, { data: { status: "ok", version: VERSION, service: "loudmusic-v1" } });
    if (request.method === "POST" && path === "/auth/login") return await authLogin(request);
    if (request.method === "POST" && path === "/auth/refresh") return await authRefresh(request);
    if (request.method === "GET" && path === "/auth/me") {
      const viewer = await requireViewer(request); return "error" in viewer ? json(request, { error: viewer.error }, viewer.status) : json(request, { data: viewer.user });
    }
    if (request.method === "GET" && path === "/dashboard") return await dashboard(request);
    if (request.method === "GET" && path === "/contacts") return await contacts(request);
    if (request.method === "GET" && path.startsWith("/contacts/")) return await contactDetail(request, path.split("/")[2]);
    if (request.method === "POST" && path === "/lead") return await lead(request);
    return json(request, { error: "Route not found" }, 404);
  } catch (error) {
    console.error("loudmusic-v1", error instanceof Error ? error.message : "unknown error");
    return json(request, { error: "Internal server error" }, 500);
  }
});
