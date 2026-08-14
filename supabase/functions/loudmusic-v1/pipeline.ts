// Pipeline: pipelines, stages, win/loss reasons, opportunities, stage moves
// with history. Deliberately separate from the legacy /crm/pipelines +
// crm_deals routes (index.ts pipelines()/createDeal()) — this is the real
// backend for the admin Pipeline.tsx/OpportunityDetail.tsx screens, which
// were built against a generated client expecting camelCase fields and a
// richer opportunity shape than crm_deals has.

import { dbFetch, json, readJson, first, requireViewer, type DbRow } from "./_shared.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function rowToPipeline(row: DbRow): DbRow {
  return { id: row.id, name: row.name, description: row.description ?? null, isDefault: row.is_default, position: row.position, isArchived: row.is_archived };
}

function rowToStage(row: DbRow): DbRow {
  return {
    id: row.id, pipelineId: row.pipeline_id, name: row.name, position: row.sort_order, probability: row.probability,
    isWonStage: row.is_won, isLostStage: row.is_lost, color: row.color ?? null,
    requiredFields: row.required_fields ?? [], staleAfterDays: row.stale_after_days ?? null, defaultTasks: row.default_tasks ?? [],
  };
}

function rowToReason(row: DbRow): DbRow {
  return { id: row.id, pipelineId: row.pipeline_id, type: row.type, label: row.label };
}

function rowToOpportunity(row: DbRow): DbRow {
  return {
    id: row.id, name: row.name, contactId: row.contact_id ?? null, companyId: row.company_id ?? null,
    pipelineId: row.pipeline_id, stageId: row.stage_id, ownerId: row.owner_id ?? null, teamId: row.team_id ?? null,
    value: row.value != null ? String(row.value) : "0", currency: row.currency, probability: row.probability ?? null,
    expectedCloseDate: row.expected_close_date ?? null, product: row.product ?? null, source: row.source ?? null,
    funnelId: row.funnel_id ?? null, campaignId: row.campaign_id ?? null, nextStep: row.next_step ?? null,
    competitors: row.competitors ?? [], winReasonId: row.win_reason_id ?? null, lossReasonId: row.loss_reason_id ?? null,
    customFields: row.custom_fields ?? {}, status: row.status, isArchived: row.is_archived,
    lastActivityAt: row.last_activity_at ?? null, nextActivityAt: row.next_activity_at ?? null,
    closedAt: row.closed_at ?? null, createdAt: row.created_at, updatedAt: row.updated_at,
  };
}

function rowToStageHistory(row: DbRow): DbRow {
  return { id: row.id, opportunityId: row.opportunity_id, fromStageId: row.from_stage_id ?? null, toStageId: row.to_stage_id, changedBy: row.changed_by ?? null, enteredAt: row.entered_at, durationSeconds: row.duration_seconds ?? null };
}

function optionalUuid(value: unknown): string | null {
  if (typeof value !== "string" || !UUID_RE.test(value)) return null;
  return value;
}

// ---------------------------------------------------------------------------
// Pipelines / stages / win-loss reasons
// ---------------------------------------------------------------------------

export async function listPipelines(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`crm_pipelines?workspace_id=eq.${viewer.user.workspaceId}&is_archived=eq.false&select=*&order=position.asc,created_at.asc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToPipeline) });
}

async function pipelineBelongsToWorkspace(pipelineId: string, workspaceId: string) {
  const response = await dbFetch(`crm_pipelines?id=eq.${pipelineId}&workspace_id=eq.${workspaceId}&select=id&limit=1`);
  return Boolean(first(response.ok ? await response.json() : []));
}

export async function listPipelineStages(request: Request, pipelineId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!optionalUuid(pipelineId) || !(await pipelineBelongsToWorkspace(pipelineId, viewer.user.workspaceId))) return json(request, { error: "Pipeline not found" }, 404);
  const response = await dbFetch(`crm_pipeline_stages?pipeline_id=eq.${pipelineId}&select=*&order=sort_order.asc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToStage) });
}

export async function listPipelineWinLossReasons(request: Request, pipelineId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!optionalUuid(pipelineId) || !(await pipelineBelongsToWorkspace(pipelineId, viewer.user.workspaceId))) return json(request, { error: "Pipeline not found" }, 404);
  const response = await dbFetch(`crm_pipeline_win_loss_reasons?pipeline_id=eq.${pipelineId}&select=*&order=type.asc,label.asc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToReason) });
}

export async function createPipelineWinLossReason(request: Request, pipelineId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  if (!optionalUuid(pipelineId) || !(await pipelineBelongsToWorkspace(pipelineId, viewer.user.workspaceId))) return json(request, { error: "Pipeline not found" }, 404);
  const body = await readJson(request);
  const type = body.type === "loss" ? "loss" : body.type === "win" ? "win" : null;
  const label = String(body.label ?? "").trim().slice(0, 120);
  if (!type || !label) return json(request, { error: "type (win|loss) and label are required" }, 400);
  const created = await dbFetch("crm_pipeline_win_loss_reasons", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ pipeline_id: pipelineId, type, label }) });
  if (!created.ok) return json(request, { error: "Reason could not be created" }, 400);
  return json(request, { data: rowToReason(first<DbRow>(await created.json())!) }, 201);
}

// ---------------------------------------------------------------------------
// Opportunities
// ---------------------------------------------------------------------------

export async function listOpportunities(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const q = url.searchParams;
  const page = Math.max(1, Number(q.get("page") ?? 1) || 1);
  const pageSize = Math.min(200, Math.max(1, Number(q.get("pageSize") ?? 25) || 25));
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "*", limit: String(pageSize), offset: String((page - 1) * pageSize) });
  const sortMap: Record<string, string> = { updated: "updated_at.desc", created: "created_at.desc", value: "value.desc", close: "expected_close_date.asc" };
  params.set("order", sortMap[q.get("sort") ?? "updated"] ?? "updated_at.desc");
  for (const [param, column] of [["pipelineId", "pipeline_id"], ["stageId", "stage_id"], ["ownerId", "owner_id"], ["contactId", "contact_id"], ["companyId", "company_id"]] as const) {
    const value = optionalUuid(q.get(param));
    if (value) params.set(column, `eq.${value}`);
  }
  const status = q.get("status"); if (status && ["open", "won", "lost"].includes(status)) params.set("status", `eq.${status}`);
  if (q.get("includeArchived") !== "true") params.set("is_archived", "eq.false");
  const response = await dbFetch(`crm_opportunities?${params}`, { headers: { Prefer: "count=exact" } });
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  const total = Number((response.headers.get("content-range") ?? "*/0").split("/")[1] ?? rows.length) || rows.length;
  return json(request, { data: { items: rows.map(rowToOpportunity), meta: { page, pageSize, totalCount: total, totalPages: Math.max(1, Math.ceil(total / pageSize)) } } });
}

async function opportunityRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_opportunities?id=eq.${id}&workspace_id=eq.${workspaceId}&select=*&limit=1`);
  return first<DbRow>(response.ok ? await response.json() : []);
}

export async function getOpportunity(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await opportunityRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Opportunity not found" }, 404);
  return json(request, { data: rowToOpportunity(row) });
}

const OPPORTUNITY_FIELD_MAP: Record<string, string> = {
  name: "name", contactId: "contact_id", companyId: "company_id", ownerId: "owner_id", teamId: "team_id",
  value: "value", currency: "currency", expectedCloseDate: "expected_close_date", product: "product", source: "source",
  funnelId: "funnel_id", campaignId: "campaign_id", nextStep: "next_step", competitors: "competitors", customFields: "custom_fields",
};

export async function createOpportunity(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const name = String(body.name ?? "").trim().slice(0, 200);
  const pipelineId = optionalUuid(body.pipelineId); const stageId = optionalUuid(body.stageId);
  if (!name) return json(request, { error: "name is required" }, 400);
  if (!pipelineId || !(await pipelineBelongsToWorkspace(pipelineId, viewer.user.workspaceId))) return json(request, { error: "A valid pipelineId is required" }, 400);
  const stageResponse = await dbFetch(`crm_pipeline_stages?id=eq.${stageId}&pipeline_id=eq.${pipelineId}&select=id,probability&limit=1`);
  const stage = first<DbRow>(stageResponse.ok ? await stageResponse.json() : []);
  if (!stageId || !stage) return json(request, { error: "A valid stageId within that pipeline is required" }, 400);

  const insert: DbRow = { workspace_id: viewer.user.workspaceId, name, pipeline_id: pipelineId, stage_id: stageId, probability: stage.probability, owner_id: viewer.user.id };
  for (const [key, column] of Object.entries(OPPORTUNITY_FIELD_MAP)) if (body[key] !== undefined && key !== "name") insert[column] = body[key];
  const created = await dbFetch("crm_opportunities", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Opportunity could not be created" }, 400);
  const opportunity = first<DbRow>(await created.json())!;
  await dbFetch("crm_opportunity_stage_history", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ opportunity_id: opportunity.id, to_stage_id: stageId, changed_by: viewer.user.id }) });
  return json(request, { data: rowToOpportunity(opportunity) }, 201);
}

export async function updateOpportunity(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await opportunityRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Opportunity not found" }, 404);
  const body = await readJson(request);
  const patch: DbRow = { updated_at: new Date().toISOString() };
  for (const [key, column] of Object.entries(OPPORTUNITY_FIELD_MAP)) if (body[key] !== undefined) patch[column] = body[key];
  if (Object.keys(patch).length === 1) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_opportunities?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Opportunity could not be updated" }, 400);
  return json(request, { data: rowToOpportunity(first<DbRow>(await updated.json())!) });
}

export async function archiveOpportunity(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await opportunityRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Opportunity not found" }, 404);
  const updated = await dbFetch(`crm_opportunities?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ is_archived: true, updated_at: new Date().toISOString() }) });
  if (!updated.ok) return json(request, { error: "Opportunity could not be archived" }, 400);
  return json(request, {}, 204);
}

export async function restoreOpportunity(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await opportunityRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Opportunity not found" }, 404);
  const updated = await dbFetch(`crm_opportunities?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ is_archived: false, updated_at: new Date().toISOString() }) });
  if (!updated.ok) return json(request, { error: "Opportunity could not be restored" }, 400);
  return json(request, { data: rowToOpportunity(first<DbRow>(await updated.json())!) });
}

export async function moveOpportunityStage(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await opportunityRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Opportunity not found" }, 404);
  const body = await readJson(request);
  const stageId = optionalUuid(body.stageId); if (!stageId) return json(request, { error: "stageId is required" }, 400);
  const stageResponse = await dbFetch(`crm_pipeline_stages?id=eq.${stageId}&pipeline_id=eq.${existing.pipeline_id}&select=*&limit=1`);
  const stage = first<DbRow>(stageResponse.ok ? await stageResponse.json() : []);
  if (!stage) return json(request, { error: "That stage does not belong to this opportunity's pipeline" }, 400);

  const requiredFields = (stage.required_fields ?? []) as string[];
  for (const field of requiredFields) {
    const column = OPPORTUNITY_FIELD_MAP[field] ?? field;
    if (existing[column] === undefined || existing[column] === null || existing[column] === "") return json(request, { error: `"${field}" must be set before moving into ${stage.name}` }, 400);
  }

  const reasonId = optionalUuid(body.reasonId);
  if ((stage.is_won || stage.is_lost) && !reasonId) return json(request, { error: `A ${stage.is_won ? "win" : "loss"} reason is required to move into ${stage.name}` }, 400);
  if (reasonId) {
    const reasonResponse = await dbFetch(`crm_pipeline_win_loss_reasons?id=eq.${reasonId}&pipeline_id=eq.${existing.pipeline_id}&type=eq.${stage.is_won ? "win" : "loss"}&select=id&limit=1`);
    if (!first(reasonResponse.ok ? await reasonResponse.json() : [])) return json(request, { error: "reasonId is not a valid reason for this move" }, 400);
  }

  const now = new Date().toISOString();
  const patch: DbRow = { stage_id: stageId, probability: stage.probability, updated_at: now, last_activity_at: now };
  if (stage.is_won) { patch.status = "won"; patch.closed_at = now; patch.win_reason_id = reasonId; }
  else if (stage.is_lost) { patch.status = "lost"; patch.closed_at = now; patch.loss_reason_id = reasonId; }
  else { patch.status = "open"; patch.closed_at = null; }

  const updated = await dbFetch(`crm_opportunities?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Opportunity could not be moved" }, 400);

  const historyResponse = await dbFetch(`crm_opportunity_stage_history?opportunity_id=eq.${id}&select=entered_at&order=entered_at.desc&limit=1`);
  const lastEntry = first<DbRow>(historyResponse.ok ? await historyResponse.json() : []);
  const durationSeconds = lastEntry ? Math.max(0, Math.round((Date.now() - new Date(String(lastEntry.entered_at)).getTime()) / 1000)) : null;
  await dbFetch("crm_opportunity_stage_history", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ opportunity_id: id, from_stage_id: existing.stage_id, to_stage_id: stageId, changed_by: viewer.user.id, duration_seconds: durationSeconds }) });

  return json(request, { data: rowToOpportunity(first<DbRow>(await updated.json())!) });
}

export async function getOpportunityStageHistory(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await opportunityRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Opportunity not found" }, 404);
  const response = await dbFetch(`crm_opportunity_stage_history?opportunity_id=eq.${id}&select=*&order=entered_at.desc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToStageHistory) });
}
