// Sequences: multi-step outreach sequences with versioning, publish, and
// contact enrollments. "Send" steps queue a real row in the shared
// funnel_outbound_queue provider-neutral review table (see job-board.ts's
// sibling _shared.ts) rather than delivering through an external email/SMS
// provider — no such provider is configured anywhere in this codebase.

import { dbFetch, json, readJson, first, requireViewer, type DbRow } from "./_shared.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STEP_TYPES = new Set([
  "automated_email", "manual_email_task", "sms", "phone_call_task", "social_task", "general_task",
  "internal_notification", "wait_period", "wait_until_date", "wait_until_business_hours",
  "wait_for_contact_action", "conditional_branch", "field_update", "tag_update", "owner_assignment",
  "pipeline_update", "webhook", "sequence_enrollment", "sequence_removal",
]);

function optionalUuid(value: unknown): string | null {
  return typeof value === "string" && UUID_RE.test(value) ? value : null;
}

function rowToSequence(row: DbRow): DbRow {
  return {
    id: row.id, name: row.name, description: row.description ?? null, status: row.status,
    goalEventType: row.goal_event_type ?? null, defaultSenderId: row.default_sender_id ?? null, fromName: row.from_name ?? null,
    businessHoursOnly: row.business_hours_only, useContactTimezone: row.use_contact_timezone, sendOnWeekends: row.send_on_weekends,
    reEntryAllowed: row.re_entry_allowed, exitOnEvents: row.exit_on_events ?? [], publishedVersionId: row.published_version_id ?? null,
    ownerId: row.owner_id ?? null, teamId: row.team_id ?? null, createdAt: row.created_at, updatedAt: row.updated_at,
  };
}

function rowToVersion(row: DbRow): DbRow {
  return { id: row.id, sequenceId: row.sequence_id, versionNumber: row.version_number, status: row.status, publishedAt: row.published_at ?? null, publishedBy: row.published_by ?? null, notes: row.notes ?? null };
}

function rowToStep(row: DbRow): DbRow {
  return { id: row.id, sequenceVersionId: row.sequence_version_id, position: row.position, stepType: row.step_type, name: row.name ?? null, messageTemplateId: row.message_template_id ?? null, config: row.config ?? {} };
}

function rowToEnrollment(row: DbRow): DbRow {
  return {
    id: row.id, sequenceId: row.sequence_id, sequenceVersionId: row.sequence_version_id, contactId: row.contact_id, status: row.status,
    currentStepId: row.current_step_id ?? null, enrollmentSource: row.enrollment_source ?? null, enrolledAt: row.enrolled_at,
    nextStepAt: row.next_step_at ?? null, pausedAt: row.paused_at ?? null, completedAt: row.completed_at ?? null,
    exitedAt: row.exited_at ?? null, exitReason: row.exit_reason ?? null, goalCompletedAt: row.goal_completed_at ?? null,
  };
}

async function sequenceRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_sequences?id=eq.${id}&workspace_id=eq.${workspaceId}&select=*&limit=1`);
  return first<DbRow>(response.ok ? await response.json() : []);
}

// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------

export async function listSequences(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const searchTerm = (url.searchParams.get("q") ?? "").trim();
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "*", order: "updated_at.desc", limit: "500" });
  if (searchTerm) params.append("name", `ilike.*${searchTerm.replace(/[^a-zA-Z0-9 ._-]/g, "")}*`);
  const response = await dbFetch(`crm_sequences?${params}`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToSequence) });
}

export async function createSequence(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request); const name = String(body.name ?? "").trim().slice(0, 200);
  if (!name) return json(request, { error: "name is required" }, 400);
  const insert: DbRow = { workspace_id: viewer.user.workspaceId, name, created_by: viewer.user.id, owner_id: viewer.user.id };
  for (const [key, column] of [["description", "description"], ["goalEventType", "goal_event_type"], ["defaultSenderId", "default_sender_id"], ["fromName", "from_name"], ["businessHoursOnly", "business_hours_only"], ["useContactTimezone", "use_contact_timezone"], ["sendOnWeekends", "send_on_weekends"], ["reEntryAllowed", "re_entry_allowed"], ["exitOnEvents", "exit_on_events"], ["teamId", "team_id"]] as const) {
    if (body[key] !== undefined) insert[column] = body[key];
  }
  const created = await dbFetch("crm_sequences", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Sequence could not be created" }, 400);
  const sequence = first<DbRow>(await created.json())!;
  await dbFetch("crm_sequence_versions", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ sequence_id: sequence.id, version_number: 1 }) });
  return json(request, { data: rowToSequence(sequence) }, 201);
}

export async function getSequence(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const row = await sequenceRow(id, viewer.user.workspaceId); if (!row) return json(request, { error: "Sequence not found" }, 404);
  return json(request, { data: rowToSequence(row) });
}

const SEQUENCE_FIELD_MAP: Record<string, string> = {
  name: "name", description: "description", goalEventType: "goal_event_type", defaultSenderId: "default_sender_id", fromName: "from_name",
  businessHoursOnly: "business_hours_only", useContactTimezone: "use_contact_timezone", sendOnWeekends: "send_on_weekends",
  reEntryAllowed: "re_entry_allowed", exitOnEvents: "exit_on_events", ownerId: "owner_id", teamId: "team_id",
};

export async function updateSequence(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await sequenceRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Sequence not found" }, 404);
  const body = await readJson(request); const patch: DbRow = { updated_at: new Date().toISOString() };
  for (const [key, column] of Object.entries(SEQUENCE_FIELD_MAP)) if (body[key] !== undefined) patch[column] = body[key];
  if (Object.keys(patch).length === 1) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_sequences?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Sequence could not be updated" }, 400);
  return json(request, { data: rowToSequence(first<DbRow>(await updated.json())!) });
}

export async function deleteSequence(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await sequenceRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Sequence not found" }, 404);
  const deleted = await dbFetch(`crm_sequences?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE" });
  if (!deleted.ok) return json(request, { error: "Sequence could not be deleted" }, 400);
  return json(request, {}, 204);
}

// ---------------------------------------------------------------------------
// Versions & steps
// ---------------------------------------------------------------------------

export async function listSequenceVersions(request: Request, sequenceId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { error: "Sequence not found" }, 404);
  const response = await dbFetch(`crm_sequence_versions?sequence_id=eq.${sequenceId}&select=*&order=version_number.desc`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToVersion) });
}

export async function createSequenceVersion(request: Request, sequenceId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { error: "Sequence not found" }, 404);
  const latestResponse = await dbFetch(`crm_sequence_versions?sequence_id=eq.${sequenceId}&select=version_number&order=version_number.desc&limit=1`);
  const latest = first<DbRow>(latestResponse.ok ? await latestResponse.json() : []);
  const nextVersion = Number(latest?.version_number ?? 0) + 1;
  const created = await dbFetch("crm_sequence_versions", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ sequence_id: sequenceId, version_number: nextVersion }) });
  if (!created.ok) return json(request, { error: "Version could not be created" }, 400);
  return json(request, { data: rowToVersion(first<DbRow>(await created.json())!) }, 201);
}

export async function publishSequence(request: Request, sequenceId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { error: "Sequence not found" }, 404);
  const body = await readJson(request); const versionId = String(body.sequenceVersionId ?? "");
  const versionResponse = await dbFetch(`crm_sequence_versions?id=eq.${versionId}&sequence_id=eq.${sequenceId}&select=*&limit=1`);
  const version = first<DbRow>(versionResponse.ok ? await versionResponse.json() : []);
  if (!version) return json(request, { error: "sequenceVersionId does not belong to this sequence" }, 400);
  const stepsResponse = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${versionId}&select=id&limit=1`);
  if (!first(stepsResponse.ok ? await stepsResponse.json() : [])) return json(request, { error: "This version has no steps to publish yet." }, 422);

  const now = new Date().toISOString();
  if (sequence.published_version_id) await dbFetch(`crm_sequence_versions?id=eq.${sequence.published_version_id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "archived" }) });
  await dbFetch(`crm_sequence_versions?id=eq.${versionId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "published", published_at: now, published_by: viewer.user.id }) });

  if (body.migrateActiveEnrollments) {
    await dbFetch(`crm_enrollments?sequence_id=eq.${sequenceId}&status=eq.active`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ sequence_version_id: versionId }) });
  }

  const updated = await dbFetch(`crm_sequences?id=eq.${sequenceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "published", published_version_id: versionId, updated_at: now }) });
  if (!updated.ok) return json(request, { error: "Sequence could not be published" }, 400);
  return json(request, { data: rowToSequence(first<DbRow>(await updated.json())!) });
}

async function versionIsDraft(versionId: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(versionId)) return null;
  const response = await dbFetch(`crm_sequence_versions?id=eq.${versionId}&select=*,sequence:crm_sequences!crm_sequence_versions_sequence_id_fkey(workspace_id)&limit=1`);
  const row = first<DbRow>(response.ok ? await response.json() : []);
  if (!row) return null;
  const sequence = row.sequence as DbRow | undefined;
  if (!sequence || sequence.workspace_id !== workspaceId) return null;
  return row.status === "draft" ? row : null;
}

export async function listSequenceSteps(request: Request, versionId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${versionId}&select=*,version:crm_sequence_versions!inner(sequence:crm_sequences!crm_sequence_versions_sequence_id_fkey(workspace_id))&order=position.asc`);
  if (!response.ok) return json(request, { data: [] });
  const rows = (await response.json()) as DbRow[];
  const scoped = rows.filter((row) => (((row.version as DbRow)?.sequence as DbRow)?.workspace_id) === viewer.user.workspaceId);
  return json(request, { data: scoped.map(rowToStep) });
}

export async function createSequenceStep(request: Request, versionId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const version = await versionIsDraft(versionId, viewer.user.workspaceId);
  if (!version) return json(request, { error: "Steps can only be added to a draft version" }, 400);
  const body = await readJson(request); const stepType = String(body.stepType ?? "");
  if (!STEP_TYPES.has(stepType)) return json(request, { error: `stepType must be one of: ${[...STEP_TYPES].join(", ")}` }, 400);
  const posResponse = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${versionId}&select=position&order=position.desc&limit=1`);
  const lastPosition = Number(first<DbRow>(posResponse.ok ? await posResponse.json() : [])?.position ?? -1);
  const insert: DbRow = { sequence_version_id: versionId, position: lastPosition + 1, step_type: stepType, name: body.name ?? null, message_template_id: body.messageTemplateId ?? null, config: body.config ?? {} };
  const created = await dbFetch("crm_sequence_steps", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!created.ok) return json(request, { error: "Step could not be created" }, 400);
  return json(request, { data: rowToStep(first<DbRow>(await created.json())!) }, 201);
}

async function stepRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_sequence_steps?id=eq.${id}&select=*,version:crm_sequence_versions!inner(status,sequence:crm_sequences!crm_sequence_versions_sequence_id_fkey(workspace_id))&limit=1`);
  const row = first<DbRow>(response.ok ? await response.json() : []);
  if (!row) return null;
  const version = row.version as DbRow | undefined;
  const sequence = version?.sequence as DbRow | undefined;
  if (!sequence || sequence.workspace_id !== workspaceId) return null;
  return row;
}

export async function updateSequenceStep(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await stepRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Step not found" }, 404);
  if ((existing.version as DbRow)?.status !== "draft") return json(request, { error: "Only steps on a draft version can be edited" }, 400);
  const body = await readJson(request); const patch: DbRow = {};
  if (body.stepType !== undefined) { if (!STEP_TYPES.has(String(body.stepType))) return json(request, { error: "Invalid stepType" }, 400); patch.step_type = body.stepType; }
  for (const [key, column] of [["name", "name"], ["messageTemplateId", "message_template_id"], ["config", "config"], ["position", "position"]] as const) if (body[key] !== undefined) patch[column] = body[key];
  if (!Object.keys(patch).length) return json(request, { error: "No editable fields supplied" }, 400);
  const updated = await dbFetch(`crm_sequence_steps?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!updated.ok) return json(request, { error: "Step could not be updated" }, 400);
  return json(request, { data: rowToStep(first<DbRow>(await updated.json())!) });
}

export async function deleteSequenceStep(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await stepRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Step not found" }, 404);
  if ((existing.version as DbRow)?.status !== "draft") return json(request, { error: "Only steps on a draft version can be deleted" }, 400);
  const deleted = await dbFetch(`crm_sequence_steps?id=eq.${id}`, { method: "DELETE" });
  if (!deleted.ok) return json(request, { error: "Step could not be deleted" }, 400);
  return json(request, {}, 204);
}

// ---------------------------------------------------------------------------
// Enrollments
// ---------------------------------------------------------------------------

export async function listEnrollments(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url); const q = url.searchParams;
  const sequenceId = optionalUuid(q.get("sequenceId"));
  if (!sequenceId) return json(request, { data: [] });
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { data: [] });
  const params = new URLSearchParams({ sequence_id: `eq.${sequenceId}`, select: "*", order: "enrolled_at.desc", limit: String(Math.min(200, Number(q.get("pageSize") ?? 100) || 100)) });
  const contactId = optionalUuid(q.get("contactId")); if (contactId) params.set("contact_id", `eq.${contactId}`);
  const status = q.get("status"); if (status) params.set("status", `eq.${status}`);
  const response = await dbFetch(`crm_enrollments?${params}`);
  const rows = (response.ok ? await response.json() : []) as DbRow[];
  return json(request, { data: rows.map(rowToEnrollment) });
}

export async function createEnrollment(request: Request) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const sequenceId = optionalUuid(body.sequenceId); if (!sequenceId) return json(request, { error: "sequenceId is required" }, 400);
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { error: "Sequence not found" }, 404);
  if (sequence.status !== "published" || !sequence.published_version_id) return json(request, { error: "Only a published sequence can be enrolled into" }, 400);
  const contactIds = Array.isArray(body.contactIds) ? body.contactIds.filter((id: unknown) => optionalUuid(id)) : [];
  if (!contactIds.length) return json(request, { error: "contactIds must include at least one valid contact id" }, 400);
  const firstStepResponse = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${sequence.published_version_id}&select=id&order=position.asc&limit=1`);
  const firstStep = first<DbRow>(firstStepResponse.ok ? await firstStepResponse.json() : []);

  const created: DbRow[] = [];
  for (const contactId of contactIds) {
    const insert = { sequence_id: sequenceId, sequence_version_id: sequence.published_version_id, contact_id: contactId, current_step_id: firstStep?.id ?? null, enrollment_source: body.enrollmentSource ?? "manual", next_step_at: new Date().toISOString() };
    const response = await dbFetch("crm_enrollments", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
    if (response.ok) { const row = first<DbRow>(await response.json()); if (row) created.push(row); }
  }
  return json(request, { data: created.map(rowToEnrollment) }, 201);
}

async function enrollmentRow(id: string, workspaceId: string): Promise<DbRow | null> {
  if (!optionalUuid(id)) return null;
  const response = await dbFetch(`crm_enrollments?id=eq.${id}&select=*,sequence:crm_sequences!inner(workspace_id)&limit=1`);
  const row = first<DbRow>(response.ok ? await response.json() : []);
  if (!row || (row.sequence as DbRow)?.workspace_id !== workspaceId) return null;
  return row;
}

export async function removeEnrollment(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await enrollmentRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Enrollment not found" }, 404);
  const deleted = await dbFetch(`crm_enrollments?id=eq.${id}`, { method: "DELETE" });
  if (!deleted.ok) return json(request, { error: "Enrollment could not be removed" }, 400);
  return json(request, {}, 204);
}

export async function pauseEnrollment(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await enrollmentRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Enrollment not found" }, 404);
  const updated = await dbFetch(`crm_enrollments?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "paused", paused_at: new Date().toISOString() }) });
  if (!updated.ok) return json(request, { error: "Enrollment could not be paused" }, 400);
  return json(request, { data: rowToEnrollment(first<DbRow>(await updated.json())!) });
}

export async function resumeEnrollment(request: Request, id: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const existing = await enrollmentRow(id, viewer.user.workspaceId); if (!existing) return json(request, { error: "Enrollment not found" }, 404);
  const updated = await dbFetch(`crm_enrollments?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ status: "active", paused_at: null, next_step_at: new Date().toISOString() }) });
  if (!updated.ok) return json(request, { error: "Enrollment could not be resumed" }, 400);
  return json(request, { data: rowToEnrollment(first<DbRow>(await updated.json())!) });
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

export async function getSequenceAnalytics(request: Request, sequenceId: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const sequence = await sequenceRow(sequenceId, viewer.user.workspaceId); if (!sequence) return json(request, { error: "Sequence not found" }, 404);

  const enrollmentsResponse = await dbFetch(`crm_enrollments?sequence_id=eq.${sequenceId}&select=status`);
  const enrollments = (enrollmentsResponse.ok ? await enrollmentsResponse.json() : []) as DbRow[];
  const counts = { active: 0, paused: 0, completed: 0, exited: 0, failed: 0 } as Record<string, number>;
  for (const row of enrollments) counts[String(row.status)] = (counts[String(row.status)] ?? 0) + 1;

  const queueResponse = await dbFetch(`funnel_outbound_queue?crm_enrollment_id=in.(${enrollments.length ? enrollments.map((e) => e.id).join(",") : "00000000-0000-0000-0000-000000000000"})&select=status,channel`);
  const queueRows = (queueResponse.ok ? await queueResponse.json() : []) as DbRow[];
  const emailsSent = queueRows.filter((r) => r.channel === "email" && r.status === "sent").length;
  const failed = queueRows.filter((r) => r.status === "failed").length;

  const byStepResponse = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${sequence.published_version_id ?? "00000000-0000-0000-0000-000000000000"}&select=id&order=position.asc`);
  const steps = (byStepResponse.ok ? await byStepResponse.json() : []) as DbRow[];

  return json(request, {
    data: {
      enrolled: enrollments.length, active: counts.active, paused: counts.paused, completed: counts.completed, exited: counts.exited,
      emailsSent, deliveryRate: emailsSent ? Number((((emailsSent - failed) / emailsSent) * 100).toFixed(1)) : 0,
      bounceRate: 0, clickRate: 0, replyRate: 0, meetingsBooked: 0, opportunitiesCreated: 0, revenueInfluenced: 0,
      unsubscribeRate: 0, failureRate: queueRows.length ? Number(((failed / queueRows.length) * 100).toFixed(1)) : 0,
      byStep: steps.map((s) => ({ stepId: s.id, sent: 0, openRate: 0, clickRate: 0 })),
    },
  });
}
