// Message templates: reusable email/SMS content used by Sequences and
// Automations send actions. Test-send queues a real row in the shared
// funnel_outbound_queue provider-neutral review table — no external email/
// SMS provider is configured in this codebase, so nothing is delivered
// externally; the queued record IS the real, persisted result of a test send.

import { dbFetch, json, readJson, first, requireViewer, type DbRow } from "./_shared.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function optionalUuid(value: unknown): string | null {
  return typeof value === "string" && UUID_RE.test(value) ? value : null;
}

function rowToTemplate(row: DbRow): DbRow {
  return {
    id: row.id, name: row.name, channel: row.channel, subject: row.subject ?? null, previewText: row.preview_text ?? null,
    bodyHtml: row.body_html ?? null, bodyText: row.body_text ?? null, variableDefaults: row.variable_defaults ?? {},
  };
}

async function templateRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_message_templates?id=eq.${id}&workspace_id=eq.${workspaceId}&select=*&limit=1`);
  return first<DbRow>(response.ok ? await response.json() : []);
}

export async function listMessageTemplates(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const channel = url.searchParams.get("channel");
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "*", order: "updated_at.desc" });
  if (channel === "email" || channel === "sms") params.set("channel", `eq.${channel}`);
  const response = await dbFetch(`crm_message_templates?${params}`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToTemplate) });
}

export async function getMessageTemplate(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await templateRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Template not found" }, 404);
  return json(request, { data: rowToTemplate(row) });
}

export async function createMessageTemplate(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const name = String(body.name ?? "").trim().slice(0, 200);
  const channel = body.channel === "sms" ? "sms" : body.channel === "email" ? "email" : null;
  if (!name || !channel) return json(request, { error: "name and channel (email|sms) are required" }, 400);
  const insert: DbRow = { workspace_id: viewer.user.workspaceId, name, channel, created_by: viewer.user.id };
  for (const [key, column] of [["subject", "subject"], ["previewText", "preview_text"], ["bodyHtml", "body_html"], ["bodyText", "body_text"], ["variableDefaults", "variable_defaults"]] as const) if (body[key] !== undefined) insert[column] = body[key];
  const created = await dbFetch("crm_message_templates", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Template could not be created" }, 400);
  return json(request, { data: rowToTemplate(first<DbRow>(await created.json())!) }, 201);
}

export async function updateMessageTemplate(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await templateRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Template not found" }, 404);
  const body = await readJson(request); const patch: DbRow = { updated_at: new Date().toISOString() };
  for (const [key, column] of [["name", "name"], ["subject", "subject"], ["previewText", "preview_text"], ["bodyHtml", "body_html"], ["bodyText", "body_text"], ["variableDefaults", "variable_defaults"]] as const) if (body[key] !== undefined) patch[column] = body[key];
  if (Object.keys(patch).length === 1) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_message_templates?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Template could not be updated" }, 400);
  return json(request, { data: rowToTemplate(first<DbRow>(await updated.json())!) });
}

export async function deleteMessageTemplate(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await templateRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Template not found" }, 404);
  const deleted = await dbFetch(`crm_message_templates?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE" });
  if (!deleted.ok) return json(request, { error: "Template could not be deleted" }, 400);
  return json(request, {}, 204);
}

function renderTemplate(text: string, vars: Record<string, unknown>): string {
  return text.replace(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/g, (_match, key) => (vars[key] !== undefined ? String(vars[key]) : ""));
}

export async function testSendMessageTemplate(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const template = await templateRow(id, viewer.user.workspaceId); if (!template) return json(request, { error: "Template not found" }, 404);
  const body = await readJson(request); const contactId = optionalUuid(body.contactId);
  if (!contactId) return json(request, { error: "contactId is required" }, 400);
  const contactResponse = await dbFetch(`crm_contacts?id=eq.${contactId}&workspace_id=eq.${viewer.user.workspaceId}&select=id,display_name,primary_email,primary_phone&limit=1`);
  const contact = first<DbRow>(contactResponse.ok ? await contactResponse.json() : []);
  if (!contact) return json(request, { error: "Contact not found in this workspace" }, 404);

  const vars: Record<string, unknown> = { ...(template.variable_defaults as Record<string, unknown> ?? {}), contact_name: contact.display_name ?? "", contact_email: contact.primary_email ?? "" };
  const recipient = template.channel === "sms" ? String(contact.primary_phone ?? "") : String(contact.primary_email ?? "");
  if (!recipient) return json(request, { error: `This contact has no ${template.channel === "sms" ? "phone number" : "email address"} on file` }, 400);

  const insert = {
    workspace_id: viewer.user.workspaceId, contact_id: contactId, channel: template.channel, status: "pending",
    recipient, subject: template.subject ? renderTemplate(String(template.subject), vars) : null,
    body: renderTemplate(String(template.body_text ?? template.body_html ?? ""), vars),
    provider: "internal_review_queue", idempotency_key: crypto.randomUUID(), message_template_id: id,
    consent_snapshot: { source: "test_send", requested_by: viewer.user.id, at: new Date().toISOString() },
  };
  const created = await dbFetch("funnel_outbound_queue", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Test send could not be queued" }, 400);
  const queued = first<DbRow>(await created.json())!;
  return json(request, { data: { queued: true, id: queued.id, recipient, status: queued.status } }, 202);
}
