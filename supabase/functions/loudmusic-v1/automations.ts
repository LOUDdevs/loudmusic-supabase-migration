// Automations: versioned trigger -> conditions -> actions workflows, with
// execution history. Execution creation/advancement lives in engine.ts
// (invoked by a pg_cron tick, see migration 20260814100500) — this module
// is the CRUD/versioning/publish/inspection surface the admin UI calls.

import { dbFetch, json, readJson, first, requireViewer, type DbRow } from "./_shared.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function optionalUuid(value: unknown): string | null {
  return typeof value === "string" && UUID_RE.test(value) ? value : null;
}

function rowToAutomation(row: DbRow): DbRow {
  return {
    id: row.id, name: row.name, description: row.description ?? null, status: row.status,
    publishedVersionId: row.published_version_id ?? null, maxRunsPerRecord: row.max_runs_per_record ?? null,
    cooldownSeconds: row.cooldown_seconds ?? null, ownerId: row.owner_id ?? null, teamId: row.team_id ?? null,
  };
}

function rowToVersion(row: DbRow): DbRow {
  return {
    id: row.id, automationId: row.automation_id, versionNumber: row.version_number, status: row.status,
    triggerType: row.trigger_type, triggerConfig: row.trigger_config ?? {}, conditions: row.conditions ?? {},
    actions: row.actions ?? [], publishedAt: row.published_at ?? null, notes: row.notes ?? null,
  };
}

function rowToExecution(row: DbRow): DbRow {
  return {
    id: row.id, automationId: row.automation_id, automationVersionId: row.automation_version_id,
    triggerEntityType: row.trigger_entity_type ?? null, triggerEntityId: row.trigger_entity_id ?? null, status: row.status,
    nextActionIndex: row.next_action_index, nextRunAt: row.next_run_at ?? null, retryCount: row.retry_count,
    errorMessage: row.error_message ?? null, startedAt: row.started_at ?? null, endedAt: row.ended_at ?? null, createdAt: row.created_at,
  };
}

function rowToExecutionStep(row: DbRow): DbRow {
  return { id: row.id, actionIndex: row.action_index, actionType: row.action_type, status: row.status, input: row.input ?? {}, output: row.output ?? {}, errorMessage: row.error_message ?? null };
}

async function automationRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_automations?id=eq.${id}&workspace_id=eq.${workspaceId}&select=*&limit=1`);
  return first<DbRow>(response.ok ? await response.json() : []);
}

// ---------------------------------------------------------------------------
// Automations
// ---------------------------------------------------------------------------

export async function listAutomations(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const searchTerm = (url.searchParams.get("q") ?? "").trim();
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "*", order: "updated_at.desc", limit: "500" });
  if (searchTerm) params.append("name", `ilike.*${searchTerm.replace(/[^a-zA-Z0-9 ._-]/g, "")}*`);
  const response = await dbFetch(`crm_automations?${params}`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToAutomation) });
}

export async function createAutomation(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const name = String(body.name ?? "").trim().slice(0, 200);
  if (!name) return json(request, { error: "name is required" }, 400);
  const insert: DbRow = { workspace_id: viewer.user.workspaceId, name, created_by: viewer.user.id, owner_id: viewer.user.id };
  for (const [key, column] of [["description", "description"], ["maxRunsPerRecord", "max_runs_per_record"], ["cooldownSeconds", "cooldown_seconds"], ["teamId", "team_id"]] as const) if (body[key] !== undefined) insert[column] = body[key];
  const created = await dbFetch("crm_automations", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Automation could not be created" }, 400);
  const automation = first<DbRow>(await created.json())!;
  await dbFetch("crm_automation_versions", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ automation_id: automation.id, version_number: 1, trigger_type: "event" }) });
  return json(request, { data: rowToAutomation(automation) }, 201);
}

export async function getAutomation(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await automationRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Automation not found" }, 404);
  return json(request, { data: rowToAutomation(row) });
}

export async function updateAutomation(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await automationRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Automation not found" }, 404);
  const body = await readJson(request); const patch: DbRow = { updated_at: new Date().toISOString() };
  for (const [key, column] of [["name", "name"], ["description", "description"], ["maxRunsPerRecord", "max_runs_per_record"], ["cooldownSeconds", "cooldown_seconds"], ["ownerId", "owner_id"], ["teamId", "team_id"], ["status", "status"]] as const) if (body[key] !== undefined) patch[column] = body[key];
  if (Object.keys(patch).length === 1) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_automations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Automation could not be updated" }, 400);
  return json(request, { data: rowToAutomation(first<DbRow>(await updated.json())!) });
}

export async function deleteAutomation(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await automationRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Automation not found" }, 404);
  const deleted = await dbFetch(`crm_automations?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE" });
  if (!deleted.ok) return json(request, { error: "Automation could not be deleted" }, 400);
  return json(request, {}, 204);
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

export async function listAutomationVersions(request: Request, automationId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const automation = await automationRow(automationId, viewer.user.workspaceId); if (!automation) return json(request, { error: "Automation not found" }, 404);
  const response = await dbFetch(`crm_automation_versions?automation_id=eq.${automationId}&select=*&order=version_number.desc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToVersion) });
}

export async function createAutomationVersion(request: Request, automationId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const automation = await automationRow(automationId, viewer.user.workspaceId); if (!automation) return json(request, { error: "Automation not found" }, 404);
  const body = await readJson(request); const triggerType = String(body.triggerType ?? "").trim();
  if (!triggerType) return json(request, { error: "triggerType is required" }, 400);
  const actions = Array.isArray(body.actions) ? body.actions : [];
  const latestResponse = await dbFetch(`crm_automation_versions?automation_id=eq.${automationId}&select=version_number&order=version_number.desc&limit=1`);
  const nextVersion = Number(first<DbRow>(latestResponse.ok ? await latestResponse.json() : [])?.version_number ?? 0) + 1;
  const insert = { automation_id: automationId, version_number: nextVersion, trigger_type: triggerType, trigger_config: body.triggerConfig ?? {}, conditions: body.conditions ?? {}, actions, notes: body.notes ?? null };
  const created = await dbFetch("crm_automation_versions", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Version could not be created" }, 400);
  return json(request, { data: rowToVersion(first<DbRow>(await created.json())!) }, 201);
}

export async function publishAutomation(request: Request, automationId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const automation = await automationRow(automationId, viewer.user.workspaceId); if (!automation) return json(request, { error: "Automation not found" }, 404);
  const body = await readJson(request); const versionId = String(body.automationVersionId ?? "");
  const versionResponse = await dbFetch(`crm_automation_versions?id=eq.${versionId}&automation_id=eq.${automationId}&select=*&limit=1`);
  const version = first<DbRow>(versionResponse.ok ? await versionResponse.json() : []);
  if (!version) return json(request, { error: "automationVersionId does not belong to this automation" }, 400);
  if (!Array.isArray(version.actions) || !(version.actions as unknown[]).length) return json(request, { error: "This version has no actions to publish yet." }, 422);

  const now = new Date().toISOString();
  if (automation.published_version_id) await dbFetch(`crm_automation_versions?id=eq.${automation.published_version_id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "archived" }) });
  await dbFetch(`crm_automation_versions?id=eq.${versionId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "published", published_at: now }) });
  const updated = await dbFetch(`crm_automations?id=eq.${automationId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "active", published_version_id: versionId, updated_at: now }) });
  if (!updated.ok) return json(request, { error: "Automation could not be published" }, 400);
  return json(request, { data: rowToAutomation(first<DbRow>(await updated.json())!) });
}

// ---------------------------------------------------------------------------
// Executions
// ---------------------------------------------------------------------------

export async function listAutomationExecutions(request: Request, automationId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const automation = await automationRow(automationId, viewer.user.workspaceId); if (!automation) return json(request, { error: "Automation not found" }, 404);
  const url = new URL(request.url); const q = url.searchParams;
  const params = new URLSearchParams({ automation_id: `eq.${automationId}`, select: "*", order: "created_at.desc", limit: String(Math.min(200, Number(q.get("pageSize") ?? 100) || 100)) });
  const status = q.get("status"); if (status) params.set("status", `eq.${status}`);
  const response = await dbFetch(`crm_automation_executions?${params}`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToExecution) });
}

async function executionRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_automation_executions?id=eq.${id}&select=*,automation:crm_automations!inner(workspace_id)&limit=1`);
  const row = first<DbRow>(response.ok ? await response.json() : []);
  if (!row || (row.automation as DbRow)?.workspace_id !== workspaceId) return null;
  return row;
}

export async function getAutomationExecution(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await executionRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Execution not found" }, 404);
  const stepsResponse = await dbFetch(`crm_automation_execution_steps?execution_id=eq.${id}&select=*&order=action_index.asc`);
  const steps = (stepsResponse.ok ? await stepsResponse.json() : []) as DbRow[];
  return json(request, { data: { ...rowToExecution(row), steps: steps.map(rowToExecutionStep) } });
}

export async function retryAutomationExecution(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await executionRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Execution not found" }, 404);
  if (!["failed", "dead_letter"].includes(String(row.status))) return json(request, { error: "Only failed executions can be retried" }, 400);
  const updated = await dbFetch(`crm_automation_executions?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "pending", next_run_at: new Date().toISOString(), retry_count: Number(row.retry_count ?? 0) + 1, error_message: null }) });
  if (!updated.ok) return json(request, { error: "Execution could not be retried" }, 400);
  return json(request, { data: rowToExecution(first<DbRow>(await updated.json())!) });
}

export async function skipAutomationExecution(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await executionRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Execution not found" }, 404);
  if (!["pending", "running"].includes(String(row.status))) return json(request, { error: "Only pending or running executions can be skipped" }, 400);
  const updated = await dbFetch(`crm_automation_executions?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "skipped", ended_at: new Date().toISOString() }) });
  if (!updated.ok) return json(request, { error: "Execution could not be skipped" }, 400);
  return json(request, { data: rowToExecution(first<DbRow>(await updated.json())!) });
}
