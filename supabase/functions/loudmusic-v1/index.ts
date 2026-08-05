import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const VERSION = "1.1.0";
const ALLOWED_ORIGINS = new Set(["https://stg.loudmusic.io", "https://loudmusic.io", "http://localhost:5175", "http://localhost:5174"]);
const DEFAULT_WORKSPACE = "loudmusic";

const legacyFeatures = [
  { name: "Release and distribution", status: "mapped", note: "DDEX Wizard + LabelGrid workflows are inventoried; provider writes stay behind a reviewed server integration." },
  { name: "Audio intelligence", status: "mapped", note: "Audio tagging, ACR Cloud recognition, and Matchering are identified; worker contracts must be reconciled before migration." },
  { name: "Artist workspace", status: "mapped", note: "Spotify onboarding, EPK profiles, private files, royalties, storage, and community/messaging are identified." },
  { name: "Commerce and verification", status: "mapped", note: "WooCommerce, Stripe, FastCredit, and Plaid are identified; raw card data will never enter LOUDmusic systems." },
  { name: "Support and CRM", status: "connected", note: "Supabase Auth, tenant-safe CRM foundations, funnel events, and workflow review queues are live behind this API." },
];

type Viewer = { id: string; email: string; name: string; role: string; workspaceId: string };

type DbRow = Record<string, unknown>;

function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.has(origin) ? origin : "https://stg.loudmusic.io";
  return { "Access-Control-Allow-Origin": allowed, "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-idempotency-key", "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, OPTIONS", "Access-Control-Allow-Credentials": "true", "Vary": "Origin" };
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

async function readJson(request: Request): Promise<DbRow> {
  try { return await request.json(); } catch { return {}; }
}

function first<T extends DbRow>(rows: unknown): T | null {
  return Array.isArray(rows) && rows.length ? rows[0] as T : null;
}

async function workspaceFor(slug = DEFAULT_WORKSPACE) {
  const response = await dbFetch(`workspaces?slug=eq.${encodeURIComponent(slug)}&select=id,slug,name&limit=1`);
  return first<{ id: string; slug: string; name: string }>(response.ok ? await response.json() : []);
}

async function requireViewer(request: Request): Promise<{ user: Viewer } | { error: string; status: number }> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return { error: "Authentication required", status: 401 };
  const token = header.slice(7);
  const auth = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` } });
  if (!auth.ok) return { error: "Invalid or expired session", status: 401 };
  const user = await auth.json();
  const workspace = await workspaceFor();
  if (!workspace) return { error: "Workspace is not configured", status: 500 };
  const memberResponse = await dbFetch(`workspace_members?workspace_id=eq.${encodeURIComponent(workspace.id)}&user_id=eq.${encodeURIComponent(user.id)}&select=role&limit=1`);
  const members = memberResponse.ok ? await memberResponse.json() : [];
  if (!members.length) return { error: "Workspace access has not been granted", status: 403 };
  return { user: { id: user.id, email: user.email, name: user.user_metadata?.full_name ?? user.email, role: members[0].role, workspaceId: workspace.id } };
}

async function countRows(table: string, workspaceId?: string) {
  const [resource, rawQuery] = table.split("?", 2);
  const params = new URLSearchParams(rawQuery ?? "");
  params.set("select", "id"); params.set("limit", "1");
  if (workspaceId) params.set("workspace_id", `eq.${workspaceId}`);
  const response = await dbFetch(`${resource}?${params.toString()}`, { headers: { Prefer: "count=exact" } });
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
  const w = viewer.user.workspaceId;
  const [contacts, threads, tasks, artists, funnels, workflows, events] = await Promise.all([
    countRows("crm_contacts?deleted_at=is.null", w), countRows("crm_communication_threads"), countRows("crm_tasks?completed_at=is.null", w), countRows("crm_artists"),
    countRows("funnel_funnels", w), countRows("funnel_workflows", w), countRows("funnel_events", w),
  ]);
  const contactsResponse = await dbFetch(`crm_contacts?workspace_id=eq.${w}&deleted_at=is.null&select=id,display_name,primary_email,primary_phone,lifecycle_stage,lead_source,last_contacted_at,next_follow_up_at,created_at&order=created_at.desc&limit=10`);
  const tasksResponse = await dbFetch(`crm_tasks?workspace_id=eq.${w}&completed_at=is.null&select=id,title,due_at,priority&order=due_at.asc.nullslast&limit=10`);
  return json(request, { data: { viewer: viewer.user, counts: { contacts, threads, tasks, artists, funnels, workflows, events }, recentContacts: contactsResponse.ok ? await contactsResponse.json() : [], recentTasks: tasksResponse.ok ? await tasksResponse.json() : [], legacyFeatures } });
}

async function contacts(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const query = (url.searchParams.get("q") ?? "").trim();
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1) || 1); const perPage = Math.min(100, Math.max(10, Number(url.searchParams.get("per_page") ?? 25) || 25));
  const lifecycle = (url.searchParams.get("lifecycle") ?? "").trim(); const relationship = (url.searchParams.get("relationship") ?? "").trim();
  const sortMap: Record<string, string> = { name: "display_name", created: "created_at", follow_up: "next_follow_up_at", contacted: "last_contacted_at", lifecycle: "lifecycle_stage" };
  const sort = sortMap[url.searchParams.get("sort") ?? "created"] ?? "created_at"; const dir = url.searchParams.get("dir") === "asc" ? "asc" : "desc";
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, deleted_at: "is.null", select: "id,display_name,primary_email,primary_phone,lifecycle_stage,relationship_status,lead_source,owner_user_id,last_contacted_at,next_follow_up_at,custom_fields,created_at", order: `${sort}.${dir}.nullslast`, limit: String(perPage), offset: String((page - 1) * perPage) });
  if (query) { const safe = query.replace(/[^a-zA-Z0-9 @._+-]/g, ""); params.set("or", `(display_name.ilike.*${safe}*,primary_email.ilike.*${safe}*,primary_phone.ilike.*${safe}*)`); }
  if (lifecycle) params.set("lifecycle_stage", `eq.${encodeURIComponent(lifecycle)}`); if (relationship) params.set("relationship_status", `eq.${encodeURIComponent(relationship)}`);
  const response = await dbFetch(`crm_contacts?${params}`, { headers: { Prefer: "count=exact" } }); const rows = response.ok ? await response.json() : [];
  const range = response.headers.get("content-range") ?? "*/0"; const total = Number(range.split("/")[1] ?? rows.length) || rows.length;
  return json(request, { data: { contacts: rows, total, page, per_page: perPage, pages: Math.max(1, Math.ceil(total / perPage)) } });
}

async function updateContact(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const allowed = ["display_name", "primary_email", "primary_phone", "lifecycle_stage", "relationship_status", "lead_source", "next_follow_up_at", "owner_user_id", "custom_fields"];
  const patch: DbRow = {}; for (const key of allowed) if (body[key] !== undefined) patch[key] = body[key]; patch.updated_by = viewer.user.id; patch.updated_at = new Date().toISOString();
  if (!Object.keys(patch).length) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_contacts?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}&deleted_at=is.null`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Contact could not be updated" }, 400); const contact = first(await updated.json()); if (!contact) return json(request, { error: "Contact not found" }, 404);
  await dbFetch("crm_activity_logs", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, entity_type: "contact", entity_id: id, action: "contact_updated", actor_user_id: viewer.user.id, metadata: { fields: Object.keys(patch).filter((key) => key !== "updated_at") } }) });
  return json(request, { data: { contact } });
}

async function addContactNote(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const text = String(body.body ?? "").trim().slice(0, 10000); if (!text) return json(request, { error: "Note body is required" }, 400);
  const contact = await dbFetch(`crm_contacts?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}&deleted_at=is.null&select=id&limit=1`); if (!first(contact.ok ? await contact.json() : [])) return json(request, { error: "Contact not found" }, 404);
  const created = await dbFetch("crm_notes", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ contact_id: id, workspace_id: viewer.user.workspaceId, body: text, created_by: viewer.user.id }) });
  if (!created.ok) return json(request, { error: "Note could not be saved" }, 400); return json(request, { data: { note: first(await created.json()) } }, 201);
}

async function contactDetail(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const w = viewer.user.workspaceId;
  const [contactResponse, notesResponse, commsResponse, activityResponse, eventsResponse, enrollmentsResponse] = await Promise.all([
    dbFetch(`crm_contacts?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=*&limit=1`),
    dbFetch(`crm_notes?contact_id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=id,body,pinned,created_at,created_by&order=created_at.desc&limit=100`),
    dbFetch(`crm_communications?contact_id=eq.${encodeURIComponent(id)}&select=id,body,channel,direction,status,occurred_at&order=occurred_at.desc&limit=100`),
    dbFetch(`crm_activity_logs?entity_id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=id,action,metadata,actor_user_id,created_at&order=created_at.desc&limit=100`),
    dbFetch(`funnel_events?contact_id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=id,event_name,funnel_id,step_id,occurred_at,payload&order=occurred_at.desc&limit=100`),
    dbFetch(`funnel_workflow_enrollments?contact_id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=id,workflow_id,status,current_step_key,enrolled_at,next_run_at,completed_at&order=enrolled_at.desc&limit=50`),
  ]);
  const contact = first(contactResponse.ok ? await contactResponse.json() : []);
  if (!contact) return json(request, { error: "Contact not found" }, 404);
  return json(request, { data: { contact, notes: notesResponse.ok ? await notesResponse.json() : [], communications: commsResponse.ok ? await commsResponse.json() : [], activity: activityResponse.ok ? await activityResponse.json() : [], funnelEvents: eventsResponse.ok ? await eventsResponse.json() : [], enrollments: enrollmentsResponse.ok ? await enrollmentsResponse.json() : [] } });
}

async function pipelines(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const w = viewer.user.workspaceId; const url = new URL(request.url); const query = (url.searchParams.get("q") ?? "").trim(); const stage = (url.searchParams.get("stage") ?? "").trim();
  const sortMap: Record<string, string> = { title: "title", value: "value_cents", probability: "probability", updated: "updated_at", close: "expected_close_date" }; const sort = sortMap[url.searchParams.get("sort") ?? "updated"] ?? "updated_at"; const dir = url.searchParams.get("dir") === "asc" ? "asc" : "desc";
  const [p, s, d] = await Promise.all([
    dbFetch(`crm_pipelines?workspace_id=eq.${w}&select=id,name,is_default,created_at,updated_at&order=created_at.asc`),
    dbFetch(`crm_pipeline_stages?select=id,pipeline_id,name,sort_order,is_won,is_lost&order=sort_order.asc`),
    dbFetch(`crm_deals?workspace_id=eq.${w}&select=id,title,value_cents,currency,probability,expected_close_date,source,notes,pipeline_id,stage_id,contact_id,owner_user_id,updated_at&order=${sort}.${dir}.nullslast&limit=500`),
  ]);
  let deals = (d.ok ? await d.json() : []) as DbRow[]; if (query) { const needle = query.toLowerCase(); deals = deals.filter((deal) => String(deal.title ?? "").toLowerCase().includes(needle) || String(deal.source ?? "").toLowerCase().includes(needle)); } if (stage) deals = deals.filter((deal) => String(deal.stage_id) === stage);
  return json(request, { data: { pipelines: p.ok ? await p.json() : [], stages: s.ok ? await s.json() : [], deals } });
}

async function createDeal(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const title = String(body.title ?? "").trim(); if (!title) return json(request, { error: "Deal title is required" }, 400);
  const workspaceId = viewer.user.workspaceId;
  let pipelineId = optionalUuid(body.pipeline_id);
  if (!pipelineId) {
    const defaultPipeline = await dbFetch(`crm_pipelines?workspace_id=eq.${workspaceId}&is_default=eq.true&select=id&limit=1`);
    pipelineId = String(first(defaultPipeline.ok ? await defaultPipeline.json() : [])?.id ?? "");
  }
  if (!pipelineId) return json(request, { error: "No pipeline is configured" }, 400);
  let stageId = optionalUuid(body.stage_id);
  if (!stageId) {
    const firstStage = await dbFetch(`crm_pipeline_stages?pipeline_id=eq.${pipelineId}&select=id&order=sort_order.asc&limit=1`);
    stageId = String(first(firstStage.ok ? await firstStage.json() : [])?.id ?? "");
  }
  if (!stageId) return json(request, { error: "No pipeline stage is configured" }, 400);
  if (body.contact_id !== undefined && body.contact_id !== null && body.contact_id !== "" && !(await workspaceRecord("crm_contacts", String(body.contact_id), workspaceId))) return json(request, { error: "Contact is not in this workspace" }, 400);
  const payload: DbRow = { workspace_id: workspaceId, pipeline_id: pipelineId, stage_id: stageId, title, value_cents: Math.max(0, Math.round(Number(body.value_cents ?? 0))), probability: body.probability === undefined ? null : Math.max(0, Math.min(100, Number(body.probability))), expected_close_date: body.expected_close_date || null, source: body.source ? String(body.source) : null, notes: body.notes ? String(body.notes) : null, contact_id: body.contact_id || null, owner_user_id: viewer.user.id };
  const inserted = await dbFetch("crm_deals", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
  if (!inserted.ok) return json(request, { error: "Deal could not be created" }, 400);
  const deal = first(await inserted.json());
  if (deal?.id) await dbFetch("crm_activity_logs", { method: "POST", body: JSON.stringify({ workspace_id: workspaceId, entity_type: "deal", entity_id: deal.id, action: "deal_created", actor_user_id: viewer.user.id, metadata: { pipeline_id: pipelineId, stage_id: stageId } }) });
  return json(request, { data: { deal } }, 201);
}

async function updateDeal(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const allowed = ["title", "stage_id", "value_cents", "probability", "expected_close_date", "notes"]; const patch: DbRow = {};
  for (const key of allowed) if (body[key] !== undefined) patch[key] = body[key]; patch.updated_at = new Date().toISOString();
  if (patch.probability !== undefined) patch.probability = Math.max(0, Math.min(100, Number(patch.probability))); if (patch.value_cents !== undefined) patch.value_cents = Math.max(0, Math.round(Number(patch.value_cents)));
  if (!Object.keys(patch).length) return json(request, { error: "No editable deal fields supplied" }, 400);
  const existing = await dbFetch(`crm_deals?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}&select=id,stage_id,title&limit=1`); const current = first(existing.ok ? await existing.json() : []); if (!current) return json(request, { error: "Deal not found" }, 404);
  if (patch.stage_id) { const validStage = await dbFetch(`crm_pipeline_stages?id=eq.${encodeURIComponent(String(patch.stage_id))}&select=id,pipeline_id&limit=1`); if (!first(validStage.ok ? await validStage.json() : [])) return json(request, { error: "Stage not found" }, 400); }
  const updated = await dbFetch(`crm_deals?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) }); if (!updated.ok) return json(request, { error: "Deal could not be updated" }, 400);
  const deal = first(await updated.json()); await dbFetch("crm_activity_logs", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, entity_type: "deal", entity_id: id, action: patch.stage_id && patch.stage_id !== current.stage_id ? "deal_stage_changed" : "deal_updated", actor_user_id: viewer.user.id, metadata: { fields: Object.keys(patch), from_stage_id: current.stage_id, to_stage_id: patch.stage_id ?? current.stage_id } }) });
  return json(request, { data: { deal } });
}

async function publicFunnel(request: Request, slug: string) {
  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace not found" }, 404);
  const funnelResponse = await dbFetch(`funnel_funnels?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(slug)}&status=eq.published&select=id,name,slug,objective,primary_goal,settings&limit=1`);
  const funnel = first(funnelResponse.ok ? await funnelResponse.json() : []);
  if (!funnel) return json(request, { error: "Published funnel not found" }, 404);
  const stepsResponse = await dbFetch(`funnel_steps?funnel_id=eq.${funnel.id}&status=eq.published&select=id,step_key,name,step_type,sort_order,status&order=sort_order.asc`);
  const steps = (stepsResponse.ok ? await stepsResponse.json() : []) as unknown as DbRow[];
  const stepIds = steps.map((step) => String(step.id));
  const versionsResponse = stepIds.length ? await dbFetch(`funnel_page_versions?step_id=in.(${stepIds.join(",")})&state=eq.published&select=step_id,version,state,blocks,styles,metadata`) : null;
  const edgesResponse = await dbFetch(`funnel_step_edges?funnel_id=eq.${funnel.id}&select=from_step_id,to_step_id,condition,is_default`);
  return json(request, { data: { funnel, steps, versions: versionsResponse?.ok ? await versionsResponse.json() : [], edges: edgesResponse.ok ? await edgesResponse.json() : [] } });
}

function fletcherVisual(fletcher: DbRow): DbRow {
  const track = ["artist", "label", "hub"].includes(String(fletcher.track)) ? String(fletcher.track) : "artist";
  const accentTreatment = ["blue", "white"].includes(String(fletcher.accent_treatment)) ? String(fletcher.accent_treatment) : "blue";
  const ctaStyle = ["solid", "outline"].includes(String(fletcher.cta_style)) ? String(fletcher.cta_style) : "solid";
  const allowedSections = ["hero", "problem", "solution", "proof", "offer", "form"];
  const requestedSections = Array.isArray(fletcher.section_order) && fletcher.section_order.length ? fletcher.section_order.map((item) => String(item).trim().toLowerCase()).filter((item) => allowedSections.includes(item)) : allowedSections;
  const sectionOrder = requestedSections.length ? [...new Set(requestedSections)] : allowedSections;
  return { track, hero_image: String(fletcher.hero_image ?? "").trim(), accent_treatment: accentTreatment, cta_style: ctaStyle, section_order: sectionOrder };
}

function fletcherBlocks(funnelName: string, settings: DbRow, stepName: string, stepType: string) {
  const fletcher = (settings.fletcher as DbRow | undefined) ?? {};
  const visual = fletcherVisual(fletcher);
  const audience = String(fletcher.audience ?? "independent artists and music teams").trim();
  const problem = String(fletcher.problem ?? "You have momentum, but the next release or growth decision is unclear.").trim();
  const promise = String(fletcher.promise ?? `A clearer next move for ${audience}.`).trim();
  const proof = String(fletcher.proof ?? "A practical LOUDmusic review built around your catalog, goals, and audience.").trim();
  const offer = String(fletcher.offer ?? "Start with a focused conversation about the next right move.").trim();
  const cta = String(fletcher.cta ?? "Start the conversation").trim();
  const fields = Array.isArray(fletcher.form_fields) && fletcher.form_fields.length ? fletcher.form_fields : [{ key: "name", label: "Name", type: "text", required: true }, { key: "email", label: "Email", type: "email", required: true }];
  if (stepType === "confirmation_page") return [{ type: "eyebrow", text: funnelName, section: "hero" }, { type: "heading", text: stepName || "You’re in.", section: "hero" }, { type: "text", text: String(fletcher.confirmation_message ?? "Thanks. Your next step is recorded and the LOUDmusic team will follow up."), section: "solution" }];
  const sections: Record<string, DbRow> = {
    hero: { type: "hero", section: "hero", eyebrow: funnelName, headline: promise, text: `For ${audience}.`, image: visual.hero_image, imageAlt: `LOUDmusic ${visual.track} track`, ctaText: cta, ctaHref: "#form", track: visual.track },
    problem: { type: "problem", section: "problem", label: "The tension", heading: "What gets in the way", text: problem },
    solution: { type: "solution", section: "solution", label: "The move", heading: "A clearer way forward", text: promise },
    proof: { type: "proof", section: "proof", label: "Proof", heading: "Built around your real situation", text: proof },
    offer: { type: "offer", section: "offer", label: "The next step", heading: "Make the next move", text: offer, ctaText: cta, ctaHref: "#form" },
    form: { type: "form", section: "form", fields, submitLabel: cta },
  };
  return (visual.section_order as string[]).map((section) => sections[section]).filter(Boolean);
}

function fletcherValidation(funnel: DbRow, steps: DbRow[], versions: DbRow[]) {
  const fletcher = ((funnel.settings as DbRow | undefined)?.fletcher as DbRow | undefined) ?? {};
  const errors: Array<{ code: string; message: string; stepId?: string }> = [];
  const required: Array<[string, string]> = [["audience", "Define who this funnel is for."], ["problem", "State the problem the audience is trying to solve."], ["promise", "State the promised outcome."], ["offer", "Describe the offer or next step."], ["cta", "Define the call to action."]];
  for (const [key, message] of required) if (!String(fletcher[key] ?? "").trim()) errors.push({ code: `fletcher_${key}_missing`, message });
  if (!steps.length) errors.push({ code: "steps_missing", message: "Add at least one website subpage before publishing." });
  for (const step of steps) {
    const version = versions.find((candidate) => String(candidate.step_id) === String(step.id) && ["draft", "published"].includes(String(candidate.state)));
    if (!version || !Array.isArray(version.blocks) || !version.blocks.length) errors.push({ code: "page_content_missing", message: `Add page content for “${step.name}”.`, stepId: String(step.id) });
  }
  return { isValid: errors.length === 0, errors };
}

async function funnels(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`funnel_funnels?workspace_id=eq.${viewer.user.workspaceId}&select=id,name,slug,objective,status,primary_goal,created_at,updated_at&order=updated_at.desc`);
  return json(request, { data: { funnels: response.ok ? await response.json() : [] } });
}

async function funnelDetail(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const w = viewer.user.workspaceId;
  const funnelResponse = await dbFetch(`funnel_funnels?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${w}&select=*&limit=1`);
  const funnel = first(funnelResponse.ok ? await funnelResponse.json() : []);
  if (!funnel) return json(request, { error: "Funnel not found" }, 404);
  const stepsResponse = await dbFetch(`funnel_steps?funnel_id=eq.${id}&select=*&order=sort_order.asc`);
  const stepRows = (stepsResponse.ok ? await stepsResponse.json() : []) as DbRow[];
  const stepIds = (stepRows as unknown as DbRow[]).map((step) => String(step.id));
  const [steps, versions, edges, stats] = await Promise.all([
    Promise.resolve({ ok: true, json: async () => stepRows }),
    dbFetch(stepIds.length ? `funnel_page_versions?step_id=in.(${stepIds.join(",")})&select=*&order=version.desc` : "funnel_page_versions?step_id=eq.00000000-0000-0000-0000-000000000000&select=*&limit=0"),
    dbFetch(`funnel_step_edges?funnel_id=eq.${id}&select=*`),
    dbFetch(`funnel_events?funnel_id=eq.${id}&select=event_name,step_id&limit=10000`),
  ]);
  const events = stats.ok ? await stats.json() : [];
  const byStep: Record<string, number> = {}; for (const event of events as DbRow[]) { const key = String(event.step_id ?? "funnel"); byStep[key] = (byStep[key] ?? 0) + 1; }
  return json(request, { data: { funnel, steps: steps.ok ? await steps.json() : [], versions: versions.ok ? await versions.json() : [], edges: edges.ok ? await edges.json() : [], analytics: { totalEvents: events.length, byStep } } });
}

async function createFunnel(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const name = String(body.name ?? "New funnel").trim().slice(0, 120); const slug = String(body.slug ?? body.basePath ?? name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")).replace(/^\/+|\/+$/g, "").slice(0, 80);
  if (!name || !slug) return json(request, { error: "Funnel name and slug are required" }, 400);
  const incomingFletcher = (body.settings as DbRow | undefined)?.fletcher;
  const fletcher: DbRow = incomingFletcher && typeof incomingFletcher === "object" ? incomingFletcher as DbRow : { audience: String(body.audience ?? "").trim(), problem: String(body.problem ?? "").trim(), promise: String(body.promise ?? "").trim(), proof: String(body.proof ?? "").trim(), offer: String(body.offer ?? "").trim(), cta: String(body.cta ?? "Start the conversation").trim(), form_fields: body.form_fields };
  const settings: DbRow = { ...((body.settings as DbRow | undefined) ?? {}), fletcher };
  const created = await dbFetch("funnel_funnels", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: viewer.user.workspaceId, name, slug, objective: String(body.objective ?? body.type ?? "lead_generation"), primary_goal: String(body.primary_goal ?? "form_submitted"), settings, created_by: viewer.user.id, updated_by: viewer.user.id }) });
  if (!created.ok) return json(request, { error: "Funnel could not be created" }, 400);
  const funnel = first(await created.json());
  if (!funnel) return json(request, { error: "Funnel could not be read after creation" }, 500);
  const stepResponse = await dbFetch("funnel_steps", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ funnel_id: funnel.id, step_key: "start", name: "Start", step_type: "landing", sort_order: 0, status: "draft" }) });
  const step = first(stepResponse.ok ? await stepResponse.json() : []);
  if (step) await dbFetch("funnel_page_versions", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ step_id: step.id, version: 1, state: "draft", blocks: fletcherBlocks(name, settings, "Start", "landing"), styles: {}, metadata: { route: `/funnel/${slug}/start/`, seo_title: name, seo_description: String((fletcher as DbRow).promise ?? ""), visual: fletcherVisual(fletcher) }, created_by: viewer.user.id }) });
  return json(request, { data: { funnel: { ...funnel, type: funnel.objective, basePath: funnel.slug }, step } }, 201);
}

async function updateFunnel(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const patch: DbRow = {}; for (const key of ["name", "objective", "primary_goal", "status"]) if (body[key] !== undefined) patch[key] = String(body[key]).slice(0, 120); if (body.type !== undefined && body.objective === undefined) patch.objective = String(body.type).slice(0, 120); if (body.slug !== undefined || body.basePath !== undefined) patch.slug = String(body.slug ?? body.basePath).replace(/^\/+|\/+$/g, "").slice(0, 80); if (body.settings !== undefined) patch.settings = body.settings; patch.updated_by = viewer.user.id;
  if (!Object.keys(patch).length) return json(request, { error: "No funnel fields supplied" }, 400);
  const updated = await dbFetch(`funnel_funnels?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) }); if (!updated.ok) return json(request, { error: "Funnel could not be updated" }, 400);
  const funnel = first(await updated.json()); if (!funnel) return json(request, { error: "Funnel not found" }, 404); return json(request, { data: { funnel } });
}

async function createStep(request: Request, funnelId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const stepKey = String(body.step_key ?? body.name ?? "step").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const check = await dbFetch(`funnel_funnels?id=eq.${encodeURIComponent(funnelId)}&workspace_id=eq.${viewer.user.workspaceId}&select=id,name,slug,settings&limit=1`); const funnel = first(check.ok ? await check.json() : []); if (!funnel) return json(request, { error: "Funnel not found" }, 404);
  const created = await dbFetch("funnel_steps", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({
      funnel_id: funnelId,
      step_key: stepKey,
      name: String(body.name ?? "New step").slice(0, 120),
      step_type: String(body.step_type ?? body.stepType ?? "landing"),
      sort_order: Number(body.sort_order ?? body.position ?? 0),
      status: "draft",
    }),
  });
  if (!created.ok) return json(request, { error: "Step could not be created" }, 400);
  const rows = await created.json(); const step = first(rows);
  if (step) await dbFetch("funnel_page_versions", {
    method: "POST",
    headers: { Prefer: "return=minimal" },
    body: JSON.stringify({
      step_id: step.id,
      version: 1,
      metadata: { route: String(body.route ?? `/funnel/${funnel.slug}/${stepKey}/`), seo_title: String(body.seo_title ?? body.name ?? ""), seo_description: String(body.seo_description ?? ""), visual: fletcherVisual(((funnel.settings as DbRow | undefined)?.fletcher as DbRow | undefined) ?? {}) },
      blocks: Array.isArray(body.blocks) && body.blocks.length ? body.blocks : fletcherBlocks(String(funnel.name ?? "LOUDmusic"), (funnel.settings as DbRow | undefined) ?? {}, String(body.name ?? "New step"), String(body.step_type ?? body.stepType ?? "landing")),
      styles: body.styles ?? {},
    }),
  });
  return json(request, { data: { step } }, 201);
}

async function saveDraft(request: Request, stepId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const stepResponse = await dbFetch(`funnel_steps?id=eq.${encodeURIComponent(stepId)}&select=id,funnel_id`); const step = first(stepResponse.ok ? await stepResponse.json() : []);
  if (!step) return json(request, { error: "Step not found" }, 404);
  const funnelResponse = await dbFetch(`funnel_funnels?id=eq.${step.funnel_id}&workspace_id=eq.${viewer.user.workspaceId}&select=id`); if (!first(funnelResponse.ok ? await funnelResponse.json() : [])) return json(request, { error: "Step not found" }, 404);
  const currentResponse = await dbFetch(`funnel_page_versions?step_id=eq.${stepId}&select=version&order=version.desc&limit=1`); const current = first<{ version: number }>(currentResponse.ok ? await currentResponse.json() : []); const version = Number(current?.version ?? 0) + 1;
  const created = await dbFetch("funnel_page_versions", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ step_id: stepId, version, state: "draft", blocks: Array.isArray(body.blocks) ? body.blocks : [], styles: body.styles ?? {}, metadata: body.metadata ?? {}, created_by: viewer.user.id }),
  });
  if (!created.ok) return json(request, { error: "Draft could not be saved" }, 400);
  return json(request, { data: { version: first(await created.json()) } }, 201);
}

async function publishFunnel(request: Request, funnelId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const check = await dbFetch(`funnel_funnels?id=eq.${encodeURIComponent(funnelId)}&workspace_id=eq.${viewer.user.workspaceId}&select=*&limit=1`); const funnel = first(check.ok ? await check.json() : []); if (!funnel) return json(request, { error: "Funnel not found" }, 404);
  const stepsResponse = await dbFetch(`funnel_steps?funnel_id=eq.${funnelId}&select=*&order=sort_order.asc`); const steps = (stepsResponse.ok ? await stepsResponse.json() : []) as DbRow[];
  const stepIds = steps.map((step) => String(step.id));
  const versionsResponse = stepIds.length ? await dbFetch(`funnel_page_versions?step_id=in.(${stepIds.join(",")})&select=*`) : null; const versions = (versionsResponse?.ok ? await versionsResponse.json() : []) as DbRow[];
  const validation = fletcherValidation(funnel, steps, versions);
  if (!validation.isValid) return json(request, { error: "Funnel is not ready to publish", errors: validation.errors }, 422);
  for (const step of steps) {
    const latest = versions.filter((version) => String(version.step_id) === String(step.id) && String(version.state) === "draft").sort((a, b) => Number(b.version) - Number(a.version))[0];
    if (latest) { await dbFetch(`funnel_page_versions?step_id=eq.${step.id}&state=eq.published`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ state: "superseded" }) }); await dbFetch(`funnel_page_versions?id=eq.${latest.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ state: "published", published_at: new Date().toISOString() }) }); }
    await dbFetch(`funnel_steps?id=eq.${step.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "published" }) });
  }
  await dbFetch(`funnel_funnels?id=eq.${funnelId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "published", updated_by: viewer.user.id }) });
  return json(request, { data: { published: true, funnel_id: funnelId, routes: steps.map((step) => `/funnel/${funnel.slug}/${step.step_key}/`) } });
}

async function workflows(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const [w, s, q] = await Promise.all([
    dbFetch(`funnel_workflows?workspace_id=eq.${viewer.user.workspaceId}&select=*&order=updated_at.desc`),
    dbFetch(`funnel_workflow_steps?select=*&order=sort_order.asc`),
    dbFetch(`funnel_outbound_queue?workspace_id=eq.${viewer.user.workspaceId}&select=id,contact_id,channel,status,subject,created_at,failure_reason&order=created_at.desc&limit=100`),
  ]);
  return json(request, { data: { workflows: w.ok ? await w.json() : [], steps: s.ok ? await s.json() : [], outboundQueue: q.ok ? await q.json() : [] } });
}

async function createWorkflow(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const name = String(body.name ?? "New follow-up sequence").trim().slice(0, 120);
  const created = await dbFetch("funnel_workflows", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: viewer.user.workspaceId, name, description: String(body.description ?? ""), trigger: body.trigger ?? { event_name: "form_submitted" }, created_by: viewer.user.id, updated_by: viewer.user.id }) });
  if (!created.ok) return json(request, { error: "Workflow could not be created" }, 400);
  const workflow = first(await created.json());
  if (workflow) await dbFetch("funnel_workflow_steps", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workflow_id: workflow.id, step_key: "create-task", step_type: "create_task", sort_order: 0, config: { title: "Follow up with new lead", due_in_hours: 24 }, next_step_key: "review-message" }) });
  return json(request, { data: { workflow } }, 201);
}

async function updateWorkflow(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const patch: DbRow = {}; for (const key of ["name", "description", "status", "trigger"]) if (body[key] !== undefined) patch[key] = key === "trigger" ? body[key] : String(body[key]).slice(0, 500); patch.updated_by = viewer.user.id;
  const updated = await dbFetch(`funnel_workflows?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) }); if (!updated.ok) return json(request, { error: "Workflow could not be updated" }, 400);
  const workflow = first(await updated.json()); if (!workflow) return json(request, { error: "Workflow not found" }, 404); return json(request, { data: { workflow } });
}

async function testWorkflow(request: Request, workflowId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const contactId = String(body.contact_id ?? ""); if (!contactId) return json(request, { error: "contact_id is required for a test run" }, 400);
  const workflowResponse = await dbFetch(`funnel_workflows?id=eq.${encodeURIComponent(workflowId)}&workspace_id=eq.${viewer.user.workspaceId}&select=id,name`); const workflow = first(workflowResponse.ok ? await workflowResponse.json() : []); if (!workflow) return json(request, { error: "Workflow not found" }, 404);
  const stepsResponse = await dbFetch(`funnel_workflow_steps?workflow_id=eq.${workflowId}&select=*&order=sort_order.asc`); const steps = stepsResponse.ok ? await stepsResponse.json() : [];
  const preview = (steps as DbRow[]).map((step) => ({ step_key: step.step_key, step_type: step.step_type, action: step.step_type === "send_email" || step.step_type === "send_sms" ? "queued_for_review" : "simulated", config: step.config }));
  const enrollment = await dbFetch("funnel_workflow_enrollments", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ workflow_id: workflowId, workspace_id: viewer.user.workspaceId, contact_id: contactId, status: "active", current_step_key: steps[0]?.step_key ?? null, next_run_at: new Date().toISOString() }),
  });
  return json(request, { data: { workflow, mode: "test", enrollment: first(enrollment.ok ? await enrollment.json() : []), steps: preview } }, 202);
}

async function publicEvent(request: Request) {
  const body = await readJson(request); const workspace = await workspaceFor(String(body.workspace_slug ?? DEFAULT_WORKSPACE));
  if (!workspace) return json(request, { error: "Workspace not found" }, 404);
  const eventName = String(body.event_name ?? "page.viewed").slice(0, 80); const idempotencyKey = String(request.headers.get("x-idempotency-key") ?? body.idempotency_key ?? "").trim().slice(0, 180);
  if (!idempotencyKey) return json(request, { error: "Idempotency key is required" }, 400);
  const existingEvent = await dbFetch(`funnel_events?workspace_id=eq.${workspace.id}&idempotency_key=eq.${encodeURIComponent(idempotencyKey)}&select=id,contact_id,visitor_id,event_name&limit=1`); const existing = first(existingEvent.ok ? await existingEvent.json() : []);
  if (existing) return json(request, { data: { accepted: true, duplicate: true, event: existing } });
  const visitorKey = String(body.visitor_key ?? "").trim().slice(0, 160); let visitorId: string | null = null; let contactId: string | null = body.contact_id ? String(body.contact_id) : null;
  const touch = { source: String(body.source ?? "website").slice(0, 80), medium: String(body.medium ?? "").slice(0, 80), campaign: String(body.campaign ?? "").slice(0, 120), landing_page: String(body.landing_page ?? "").slice(0, 500), referrer: String(body.referrer ?? "").slice(0, 500) };
  if (visitorKey) {
    const visitorResponse = await dbFetch(`funnel_visitors?workspace_id=eq.${workspace.id}&visitor_key=eq.${encodeURIComponent(visitorKey)}&select=id,contact_id,first_touch&limit=1`); const existingVisitor = first(visitorResponse.ok ? await visitorResponse.json() : []);
    if (existingVisitor) { visitorId = String(existingVisitor.id); contactId = contactId ?? (existingVisitor.contact_id ? String(existingVisitor.contact_id) : null); await dbFetch(`funnel_visitors?id=eq.${visitorId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ contact_id: contactId, latest_touch: touch, last_seen_at: new Date().toISOString() }) }); }
    else { const createdVisitor = await dbFetch("funnel_visitors", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: workspace.id, visitor_key: visitorKey, contact_id: contactId, first_touch: touch, latest_touch: touch }) }); visitorId = String(first(createdVisitor.ok ? await createdVisitor.json() : [])?.id ?? ""); }
  }
  if (eventName === "form_submitted" || eventName === "lead.created") {
    const email = String(body.email ?? "").trim().toLowerCase(); const name = String(body.name ?? "").trim().slice(0, 160);
    if (!/^\S+@\S+\.\S+$/.test(email) || name.length < 2) return json(request, { error: "A valid name and email are required for form_submitted" }, 400);
    const existingContact = await dbFetch(`crm_contacts?workspace_id=eq.${workspace.id}&primary_email=eq.${encodeURIComponent(email)}&deleted_at=is.null&select=id,custom_fields&limit=1`); const contact = first(existingContact.ok ? await existingContact.json() : []);
    const parts = name.split(/\s+/); const firstName = parts.shift() ?? name; const lastName = parts.join(" ") || null; const fields = { workspace_id: workspace.id, display_name: name, first_name: firstName, last_name: lastName, primary_email: email, emails: [{ value: email, type: "work" }], lead_source: touch.source || "funnel", custom_fields: { ...(contact?.custom_fields as DbRow ?? {}), ...(body.fields ?? {}), attribution: touch }, updated_by: null };
    if (contact) { contactId = String(contact.id); await dbFetch(`crm_contacts?id=eq.${contactId}&workspace_id=eq.${workspace.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify(fields) }); }
    else { const created = await dbFetch("crm_contacts", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(fields) }); const createdContact = first(created.ok ? await created.json() : []); if (!createdContact) return json(request, { error: "Contact could not be created" }, 500); contactId = String(createdContact.id); }
    if (visitorId) await dbFetch(`funnel_visitors?id=eq.${visitorId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ contact_id: contactId }) });
    await dbFetch("crm_activity_logs", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: workspace.id, entity_type: "contact", entity_id: contactId, action: "funnel_form_submitted", metadata: { event_name: eventName, attribution: touch } }) });
  }
  const createdEvent = await dbFetch("funnel_events", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: workspace.id, event_name: eventName, visitor_id: visitorId || null, contact_id: contactId, funnel_id: body.funnel_id || null, step_id: body.step_id || null, session_key: body.session_key || null, source: touch.source, occurred_at: body.occurred_at || new Date().toISOString(), idempotency_key: idempotencyKey, classification: eventName === "page.viewed" ? "Internal" : "Confidential", payload: { ...body, password: undefined, payment: undefined, card: undefined } }) });
  if (!createdEvent.ok) return json(request, { error: "Event could not be recorded" }, 500);
  const event = first(await createdEvent.json());
  const enrolledWorkflows: string[] = [];
  if (contactId) {
    const activeResponse = await dbFetch(`funnel_workflows?workspace_id=eq.${workspace.id}&status=eq.active&select=id,trigger`); const activeWorkflows = (activeResponse.ok ? await activeResponse.json() : []) as unknown as DbRow[];
    for (const workflow of activeWorkflows) {
      const trigger = (workflow.trigger as DbRow | undefined) ?? {};
      if (String(trigger.event_name ?? "") !== eventName && String(trigger.event_name ?? "") !== "*") continue;
      const enrollmentResponse = await dbFetch("funnel_workflow_enrollments", { method: "POST", headers: { Prefer: "return=representation,resolution=ignore-duplicates" }, body: JSON.stringify({ workflow_id: workflow.id, workspace_id: workspace.id, contact_id: contactId, source_event_id: event?.id ?? null, status: "active", next_run_at: new Date().toISOString() }) });
      if (enrollmentResponse.ok) enrolledWorkflows.push(String(workflow.id));
    }
  }
  return json(request, { data: { accepted: true, duplicate: false, contact_id: contactId, enrolled_workflows: enrolledWorkflows, event } }, 202);
}

async function funnelAnalytics(request: Request, funnelId: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`funnel_events?workspace_id=eq.${viewer.user.workspaceId}&funnel_id=eq.${encodeURIComponent(funnelId)}&select=event_name,step_id,contact_id,occurred_at&order=occurred_at.desc&limit=10000`); const events = response.ok ? await response.json() : [];
  const counts: Record<string, number> = {}; for (const event of events as DbRow[]) { const key = String(event.step_id ?? event.event_name); counts[key] = (counts[key] ?? 0) + 1; }
  return json(request, { data: { funnel_id: funnelId, total_events: events.length, unique_contacts: new Set((events as DbRow[]).map((e) => e.contact_id).filter(Boolean)).size, counts } });
}

async function lead(request: Request) {
  const body = await readJson(request); if (String(body.website ?? "").trim()) return json(request, { data: { accepted: true } });
  const name = String(body.name ?? "").trim().slice(0, 160); const email = String(body.email ?? "").trim().toLowerCase().slice(0, 240); const topic = String(body.topic ?? "General").trim().slice(0, 120); const message = String(body.message ?? "").trim().slice(0, 5000);
  if (name.length < 2 || !/^\S+@\S+\.\S+$/.test(email) || message.length < 2) return json(request, { error: "Name, valid email, and message are required" }, 400);
  return publicEvent(new Request(request.url, { method: "POST", headers: new Headers({ ...Object.fromEntries(request.headers.entries()), "x-idempotency-key": request.headers.get("x-idempotency-key") ?? crypto.randomUUID() }), body: JSON.stringify({ event_name: "form_submitted", name, email, fields: { inquiry_topic: topic, inquiry_message: message }, source: "new-site", landing_page: body.landing_page ?? "/contact/", visitor_key: body.visitor_key ?? crypto.randomUUID() }) }));
}

// TASKS + ACTIVITY ENDPOINTS
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TASK_SORTS: Record<string, string> = { created: "created_at", due: "due_at", priority: "priority", updated: "updated_at", title: "title" };

function optionalUuid(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  return UUID_RE.test(String(value)) ? String(value) : undefined;
}

function optionalTimestamp(value: unknown) {
  if (value === undefined || value === null || value === "") return null;
  const parsed = new Date(String(value));
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString();
}

async function workspaceRecord(table: string, id: string, workspaceId: string) {
  const response = await dbFetch(`${table}?id=eq.${encodeURIComponent(id)}&workspace_id=eq.${encodeURIComponent(workspaceId)}&select=id&limit=1`);
  return first(response.ok ? await response.json() : []);
}

async function workspaceMember(id: string, workspaceId: string) {
  const response = await dbFetch(`workspace_members?workspace_id=eq.${encodeURIComponent(workspaceId)}&user_id=eq.${encodeURIComponent(id)}&select=user_id&limit=1`);
  return first(response.ok ? await response.json() : []);
}

async function validateTaskReferences(body: DbRow, workspaceId: string) {
  for (const field of ["contact_id", "deal_id", "owner_user_id"]) {
    if (body[field] === undefined || body[field] === null || body[field] === "") continue;
    const id = optionalUuid(body[field]);
    if (!id) return `${field} must be a valid UUID`;
    const exists = field === "contact_id" ? await workspaceRecord("crm_contacts", id, workspaceId)
      : field === "deal_id" ? await workspaceRecord("crm_deals", id, workspaceId)
      : await workspaceMember(id, workspaceId);
    if (!exists) return `${field} is not a member of this workspace`;
  }
  return null;
}

async function recordActivity(workspaceId: string, entityType: string, entityId: string, action: string, actorUserId: string, metadata: DbRow) {
  const response = await dbFetch("crm_activity_logs", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: workspaceId, entity_type: entityType, entity_id: entityId, action, actor_user_id: actorUserId, metadata }) });
  if (!response.ok) console.error("crm_activity_logs write failed", response.status);
}

async function activity(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") ?? 50) || 50));
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "id,entity_type,entity_id,action,metadata,actor_user_id,created_at", order: "created_at.desc", limit: String(limit) });
  const entityType = url.searchParams.get("entity_type"); const entityId = url.searchParams.get("entity_id");
  if (entityType) params.set("entity_type", `eq.${encodeURIComponent(entityType.slice(0, 80))}`);
  if (entityId && UUID_RE.test(entityId)) params.set("entity_id", `eq.${entityId}`);
  const response = await dbFetch(`crm_activity_logs?${params}`);
  return json(request, { data: { activity: response.ok ? await response.json() : [] } });
}

async function tasks(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const workspaceId = viewer.user.workspaceId;
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") ?? 25) || 25));
  const offset = Math.max(0, Number(url.searchParams.get("offset") ?? 0) || 0);
  const params = new URLSearchParams({ workspace_id: `eq.${workspaceId}`, select: "id,title,description,contact_id,deal_id,due_at,completed_at,priority,owner_user_id,created_at,updated_at", limit: String(limit), offset: String(offset), order: `${TASK_SORTS[url.searchParams.get("sort") ?? "created"] ?? "created_at"}.${url.searchParams.get("order") === "asc" ? "asc" : "desc"}.nullslast` });
  const contactId = url.searchParams.get("contact_id"); const dealId = url.searchParams.get("deal_id");
  if (contactId && UUID_RE.test(contactId)) params.set("contact_id", `eq.${contactId}`);
  if (dealId && UUID_RE.test(dealId)) params.set("deal_id", `eq.${dealId}`);
  if (url.searchParams.get("completed") === "open") params.set("completed_at", "is.null");
  if (url.searchParams.get("completed") === "done") params.set("completed_at", "not.is.null");
  const response = await dbFetch(`crm_tasks?${params}`, { headers: { Prefer: "count=exact" } }); const rows = response.ok ? await response.json() : [];
  const range = response.headers.get("content-range") ?? "*/0"; const total = Number(range.split("/")[1] ?? rows.length) || rows.length;
  return json(request, { data: { tasks: rows, total, limit, offset } });
}

function normalizedTask(body: DbRow, workspaceId: string, userId: string, isCreate: boolean): { task?: DbRow; error?: string } {
  const title = String(body.title ?? "").trim().slice(0, 200);
  if (isCreate && !title) return { error: "Task title is required" };
  if (!isCreate && body.title !== undefined && !title) return { error: "Task title cannot be empty" };
  const priority = body.priority === undefined ? undefined : Number(body.priority);
  if (priority !== undefined && (!Number.isInteger(priority) || priority < 0 || priority > 9)) return { error: "Priority must be an integer from 0 to 9" };
  const due = optionalTimestamp(body.due_at); const completed = optionalTimestamp(body.completed_at);
  if (due === undefined || completed === undefined) return { error: "Task dates must be valid ISO timestamps" };
  const task: DbRow = { workspace_id: workspaceId, updated_at: new Date().toISOString() };
  if (isCreate || body.title !== undefined) task.title = title;
  for (const key of ["description", "contact_id", "deal_id", "owner_user_id"]) if (body[key] !== undefined) task[key] = body[key] === "" ? null : body[key];
  if (body.due_at !== undefined) task.due_at = due;
  if (body.completed_at !== undefined) task.completed_at = completed;
  if (priority !== undefined) task.priority = priority;
  if (isCreate && task.owner_user_id === undefined) task.owner_user_id = userId;
  return { task };
}

async function createTask(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const normalized = normalizedTask(body, viewer.user.workspaceId, viewer.user.id, true);
  if (normalized.error) return json(request, { error: normalized.error }, 400);
  const referenceError = await validateTaskReferences(normalized.task!, viewer.user.workspaceId); if (referenceError) return json(request, { error: referenceError }, 400);
  const response = await dbFetch("crm_tasks", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(normalized.task) });
  if (!response.ok) return json(request, { error: "Task could not be created" }, 400);
  const task = first(await response.json()); if (!task) return json(request, { error: "Task could not be read after creation" }, 500);
  await recordActivity(viewer.user.workspaceId, "task", String(task.id), "task_created", viewer.user.id, { title: task.title, contact_id: task.contact_id ?? null, deal_id: task.deal_id ?? null });
  return json(request, { data: { task } }, 201);
}

async function updateTask(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Task id must be a valid UUID" }, 400);
  const body = await readJson(request); const currentResponse = await dbFetch(`crm_tasks?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=*&limit=1`); const current = first(currentResponse.ok ? await currentResponse.json() : []);
  if (!current) return json(request, { error: "Task not found" }, 404);
  const normalized = normalizedTask(body, viewer.user.workspaceId, viewer.user.id, false); if (normalized.error) return json(request, { error: normalized.error }, 400);
  const patch = normalized.task!; delete patch.workspace_id;
  const referenceError = await validateTaskReferences(patch, viewer.user.workspaceId); if (referenceError) return json(request, { error: referenceError }, 400);
  if (Object.keys(patch).length === 1 && patch.updated_at) return json(request, { error: "No editable task fields supplied" }, 400);
  const response = await dbFetch(`crm_tasks?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!response.ok) return json(request, { error: "Task could not be updated" }, 400);
  const task = first(await response.json()); if (!task) return json(request, { error: "Task could not be read after update" }, 500);
  await recordActivity(viewer.user.workspaceId, "task", id, task.completed_at && !current.completed_at ? "task_completed" : "task_updated", viewer.user.id, { fields: Object.keys(patch), completed_at: task.completed_at ?? null });
  return json(request, { data: { task } });
}

async function deleteTask(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Task id must be a valid UUID" }, 400);
  const response = await dbFetch(`crm_tasks?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE", headers: { Prefer: "return=representation" } });
  if (!response.ok) return json(request, { error: "Task could not be deleted" }, 400);
  const deletedTask = first(await response.json()); if (!deletedTask) return json(request, { error: "Task not found" }, 404);
  await recordActivity(viewer.user.workspaceId, "task", id, "task_deleted", viewer.user.id, { title: deletedTask.title });
  return json(request, { data: { task: deletedTask } });
}

// COMPANIES / ORGANIZATIONS ENDPOINTS
const COMPANY_SELECT = "id,name,domain,industry,employee_count,website,phone,location,timezone,description,owner_id,team_id,source,archived_at,created_at,updated_at";
const COMPANY_SORTS: Record<string, string> = {
  name: "name", created: "created_at", createdAt: "created_at", updated: "updated_at", updatedAt: "updated_at", industry: "industry",
};

function companyPayload(body: DbRow, workspaceId: string, userId: string, isCreate: boolean): { payload?: DbRow; error?: string } {
  const name = String(body.name ?? "").trim().slice(0, 200);
  if (isCreate && !name) return { error: "Company name is required" };
  if (!isCreate && body.name !== undefined && !name) return { error: "Company name cannot be empty" };
  const employeeValue = body.employeeCount ?? body.employee_count;
  const employeeCount = employeeValue === undefined || employeeValue === null || employeeValue === "" ? undefined : Number(employeeValue);
  if (employeeCount !== undefined && (!Number.isInteger(employeeCount) || employeeCount < 0)) return { error: "employeeCount must be a non-negative integer" };
  const payload: DbRow = { workspace_id: workspaceId, updated_by: userId };
  if (isCreate || body.name !== undefined) payload.name = name;
  const fields: Array<[string, string]> = [["domain", "domain"], ["industry", "industry"], ["website", "website"], ["phone", "phone"], ["location", "location"], ["timezone", "timezone"], ["description", "description"], ["source", "source"]];
  for (const [camel, snake] of fields) if (body[camel] !== undefined || body[snake] !== undefined) payload[snake] = String(body[camel] ?? body[snake] ?? "").trim().slice(0, 1000) || null;
  if (employeeCount !== undefined) payload.employee_count = employeeCount;
  for (const [camel, snake] of [["ownerId", "owner_id"], ["teamId", "team_id"]]) {
    if (body[camel] !== undefined || body[snake] !== undefined) {
      const value = body[camel] ?? body[snake]; const parsed = optionalUuid(value);
      if (parsed === undefined) return { error: `${camel} must be a valid UUID` };
      payload[snake] = parsed;
    }
  }
  if (isCreate) payload.created_by = userId;
  return { payload };
}

async function company(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const response = await dbFetch(`crm_organizations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=${COMPANY_SELECT}&limit=1`);
  const row = first(response.ok ? await response.json() : []);
  if (!row) return json(request, { error: "Company not found" }, 404);
  return json(request, { data: { ...row, is_archived: Boolean(row.archived_at) } });
}

async function companies(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const page = Math.max(1, Number(url.searchParams.get("page") ?? 1) || 1);
  const pageSize = Math.min(200, Math.max(1, Number(url.searchParams.get("pageSize") ?? url.searchParams.get("page_size") ?? 25) || 25));
  const includeArchived = url.searchParams.get("includeArchived") === "true" || url.searchParams.get("archived") === "true";
  const rawSort = url.searchParams.get("sort") ?? "-createdAt"; const descending = rawSort.startsWith("-"); const sort = COMPANY_SORTS[descending ? rawSort.slice(1) : rawSort] ?? "created_at";
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: COMPANY_SELECT, order: `${sort}.${descending ? "desc" : "asc"}.nullslast`, limit: String(pageSize), offset: String((page - 1) * pageSize) });
  if (!includeArchived) params.set("archived_at", "is.null");
  const query = (url.searchParams.get("q") ?? "").trim().replace(/[^a-zA-Z0-9 @._-]/g, "");
  if (query) params.set("or", `(name.ilike.*${query}*,domain.ilike.*${query}*,industry.ilike.*${query}*)`);
  const response = await dbFetch(`crm_organizations?${params}`, { headers: { Prefer: "count=exact" } });
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  const range = response.headers.get("content-range") ?? "*/0"; const total = Number(range.split("/")[1] ?? rows.length) || rows.length;
  const items = rows.map((row) => ({ ...row, is_archived: Boolean(row.archived_at) }));
  return json(request, { data: { items, meta: { page, pageSize, totalCount: total, totalPages: Math.max(1, Math.ceil(total / pageSize)) } } });
}

async function createCompany(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const normalized = companyPayload(body, viewer.user.workspaceId, viewer.user.id, true);
  if (normalized.error) return json(request, { error: normalized.error }, 400);
  const response = await dbFetch("crm_organizations", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(normalized.payload) });
  if (!response.ok) return json(request, { error: "Company could not be created" }, response.status === 409 ? 409 : 400);
  const row = first(await response.json()); if (!row) return json(request, { error: "Company could not be read after creation" }, 500);
  await recordActivity(viewer.user.workspaceId, "company", String(row.id), "company_created", viewer.user.id, { name: row.name });
  return json(request, { data: { ...row, is_archived: false } }, 201);
}

async function updateCompany(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const existing = await dbFetch(`crm_organizations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=id,archived_at&limit=1`); const current = first(existing.ok ? await existing.json() : []);
  if (!current) return json(request, { error: "Company not found" }, 404);
  const normalized = companyPayload(await readJson(request), viewer.user.workspaceId, viewer.user.id, false);
  if (normalized.error) return json(request, { error: normalized.error }, 400);
  delete normalized.payload!.workspace_id; delete normalized.payload!.updated_by;
  if (Object.keys(normalized.payload!).length === 0) return json(request, { error: "No editable company fields supplied" }, 400);
  const response = await dbFetch(`crm_organizations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(normalized.payload) });
  if (!response.ok) return json(request, { error: "Company could not be updated" }, response.status === 409 ? 409 : 400);
  const row = first(await response.json()); if (!row) return json(request, { error: "Company not found" }, 404);
  await recordActivity(viewer.user.workspaceId, "company", id, "company_updated", viewer.user.id, { fields: Object.keys(normalized.payload) });
  return json(request, { data: { ...row, is_archived: Boolean(row.archived_at) } });
}

async function archiveCompany(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const response = await dbFetch(`crm_organizations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&archived_at=is.null`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ archived_at: new Date().toISOString(), archived_by: viewer.user.id, updated_by: viewer.user.id }) });
  if (!response.ok) return json(request, { error: "Company could not be archived" }, 400);
  const row = first(await response.json()); if (!row) return json(request, { error: "Company not found" }, 404);
  await recordActivity(viewer.user.workspaceId, "company", id, "company_archived", viewer.user.id, {});
  return new Response(null, { status: 204, headers: corsHeaders(request) });
}

async function restoreCompany(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const response = await dbFetch(`crm_organizations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&archived_at=not.is.null`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ archived_at: null, archived_by: null, updated_by: viewer.user.id }) });
  if (!response.ok) return json(request, { error: "Company could not be restored" }, 400);
  const row = first(await response.json()); if (!row) return json(request, { error: "Company not found" }, 404);
  await recordActivity(viewer.user.workspaceId, "company", id, "company_restored", viewer.user.id, {});
  return json(request, { data: { ...row, is_archived: false } });
}

async function companyContacts(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const companyExists = await workspaceRecord("crm_organizations", id, viewer.user.workspaceId); if (!companyExists) return json(request, { error: "Company not found" }, 404);
  const links = await dbFetch(`crm_contact_organizations?organization_id=eq.${id}&select=contact_id,role,is_primary,created_at`); const linkRows = (links.ok ? await links.json() : []) as DbRow[];
  const ids = linkRows.map((row) => String(row.contact_id)).filter((value) => UUID_RE.test(value));
  const contactsResponse = ids.length ? await dbFetch(`crm_contacts?id=in.(${ids.join(",")})&workspace_id=eq.${viewer.user.workspaceId}&deleted_at=is.null&select=id,display_name,first_name,last_name,primary_email,primary_phone,lifecycle_stage,created_at,updated_at&order=display_name.asc`) : null;
  const contacts = contactsResponse?.ok ? await contactsResponse.json() : [];
  return json(request, { data: { items: contacts, meta: { page: 1, pageSize: contacts.length, totalCount: contacts.length, totalPages: 1 } } });
}

async function linkContactToCompany(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!UUID_RE.test(id)) return json(request, { error: "Company id must be a valid UUID" }, 400);
  const body = await readJson(request); const contactId = String(body.contactId ?? body.contact_id ?? "");
  if (!UUID_RE.test(contactId)) return json(request, { error: "contactId must be a valid UUID" }, 400);
  if (!(await workspaceRecord("crm_organizations", id, viewer.user.workspaceId))) return json(request, { error: "Company not found" }, 404);
  if (!(await workspaceRecord("crm_contacts", contactId, viewer.user.workspaceId))) return json(request, { error: "Contact is not in this workspace" }, 400);
  const response = await dbFetch("crm_contact_organizations", { method: "POST", headers: { Prefer: "return=minimal,resolution=ignore-duplicates" }, body: JSON.stringify({ organization_id: id, contact_id: contactId, role: body.role ? String(body.role).slice(0, 120) : null, is_primary: Boolean(body.isPrimary ?? body.is_primary) }) });
  if (!response.ok) return json(request, { error: "Contact could not be linked to company" }, 400);
  await recordActivity(viewer.user.workspaceId, "company", id, "company_contact_linked", viewer.user.id, { contact_id: contactId });
  return new Response(null, { status: 204, headers: corsHeaders(request) });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request) });
  const url = new URL(request.url); const segments = url.pathname.split("/").filter(Boolean); const marker = segments.indexOf("loudmusic-v1"); const path = "/" + (marker >= 0 ? segments.slice(marker + 1).join("/") : segments.join("/"));
  try {
    if (request.method === "GET" && path === "/health") return json(request, { data: { status: "ok", version: VERSION, service: "loudmusic-v1" } });
    if (request.method === "GET" && path.startsWith("/public/funnels/")) return publicFunnel(request, path.split("/")[3]);
    if (request.method === "POST" && path === "/auth/login") return authLogin(request);
    if (request.method === "POST" && path === "/auth/refresh") return authRefresh(request);
    if (request.method === "GET" && path === "/auth/me") { const viewer = await requireViewer(request); return "error" in viewer ? json(request, { error: viewer.error }, viewer.status) : json(request, { data: viewer.user }); }
    if (request.method === "GET" && path === "/dashboard") return dashboard(request);
    if (request.method === "GET" && path === "/contacts") return contacts(request);
    if (request.method === "PATCH" && path.startsWith("/contacts/") && !path.endsWith("/notes")) return updateContact(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/contacts/") && path.endsWith("/notes")) return addContactNote(request, path.split("/")[2]);
    if (request.method === "GET" && path.startsWith("/contacts/")) return contactDetail(request, path.split("/")[2]);
    if (request.method === "GET" && path === "/crm/pipelines") return pipelines(request);
    if (request.method === "POST" && path === "/crm/deals") return createDeal(request);
    if (request.method === "PATCH" && path.startsWith("/crm/deals/")) return updateDeal(request, path.split("/")[3]);
    if (request.method === "GET" && path === "/funnels") return funnels(request);
    if (request.method === "POST" && path === "/funnels") return createFunnel(request);
    if (request.method === "PATCH" && path.startsWith("/funnels/") && path.split("/").length === 3) return updateFunnel(request, path.split("/")[2]);
    if (request.method === "GET" && path.startsWith("/funnels/") && path.endsWith("/analytics")) return funnelAnalytics(request, path.split("/")[2]);
    if (request.method === "GET" && path.startsWith("/funnels/") && path.split("/").length === 3) return funnelDetail(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/funnels/") && path.endsWith("/steps")) return createStep(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/funnels/") && path.endsWith("/publish")) return publishFunnel(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/funnel-steps/") && path.endsWith("/draft")) return saveDraft(request, path.split("/")[2]);
    if (request.method === "GET" && path === "/workflows") return workflows(request);
    if (request.method === "POST" && path === "/workflows") return createWorkflow(request);
    if (request.method === "PATCH" && path.startsWith("/workflows/") && path.split("/").length === 3) return updateWorkflow(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/workflows/") && path.endsWith("/test")) return testWorkflow(request, path.split("/")[2]);
    if (request.method === "POST" && path === "/events") return publicEvent(request);
    if (request.method === "POST" && path === "/lead") return lead(request);
    if (request.method === "GET" && path === "/companies") return companies(request);
    if (request.method === "POST" && path === "/companies") return createCompany(request);
    if (request.method === "POST" && path.startsWith("/companies/") && path.endsWith("/restore")) return restoreCompany(request, path.split("/")[2]);
    if (request.method === "GET" && path.startsWith("/companies/") && path.endsWith("/contacts")) return companyContacts(request, path.split("/")[2]);
    if (request.method === "POST" && path.startsWith("/companies/") && path.endsWith("/contacts")) return linkContactToCompany(request, path.split("/")[2]);
    if (request.method === "PATCH" && path.startsWith("/companies/") && path.split("/").length === 3) return updateCompany(request, path.split("/")[2]);
    if (request.method === "DELETE" && path.startsWith("/companies/") && path.split("/").length === 3) return archiveCompany(request, path.split("/")[2]);
    if (request.method === "GET" && path.startsWith("/companies/") && path.split("/").length === 3) return company(request, path.split("/")[2]);
    if (request.method === "GET" && path === "/activity") return activity(request);
    if (request.method === "GET" && path === "/tasks") return tasks(request);
    if (request.method === "POST" && path === "/tasks") return createTask(request);
    if (request.method === "PATCH" && path.startsWith("/tasks/") && !path.endsWith("/notes")) return updateTask(request, path.split("/")[2]);
    if (request.method === "DELETE" && path.startsWith("/tasks/")) return deleteTask(request, path.split("/")[2]);
    return json(request, { error: "Route not found" }, 404);
  } catch (error) {
    console.error("loudmusic-v1", error instanceof Error ? error.message : "unknown error");
    return json(request, { error: "Internal server error" }, 500);
  }
});