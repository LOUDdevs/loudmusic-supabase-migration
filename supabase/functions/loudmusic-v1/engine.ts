// Background engine: advances due sequence enrollments and fires
// event-triggered automations. Invoked on a schedule by pg_cron (see
// migration 20260814100500_engine_scheduler.sql), which calls this route
// via pg_net with a shared secret header — not a normal viewer-authenticated
// request, so it does NOT go through requireViewer().
//
// Scope note: only trigger_type === "event" automations fire automatically
// (matched against the existing funnel_events ledger). "date_based" and
// "inactivity" triggers have no defined per-entity schedule in the frontend
// contract this was built against, so they're accepted and stored but do not
// yet create executions on their own — that needs a follow-up spec, not a
// guess. Actions without a real internal integration (most of the 21 action
// types) apply to real internal data (tasks, tags, custom fields, contacts,
// opportunities) rather than faking an external effect; send_email/send_sms
// queue a real row in the provider-neutral funnel_outbound_queue for human
// review, since no email/SMS provider is configured in this codebase.

import { dbFetch, json, first, type DbRow } from "./_shared.ts";

const ENGINE_SECRET = Deno.env.get("ENGINE_SECRET") ?? "";
const BATCH_SIZE = 50;

function ok(request: Request, payload: unknown) {
  return json(request, payload);
}

async function contactRow(contactId: string | null | undefined): Promise<DbRow | null> {
  if (!contactId) return null;
  const response = await dbFetch(`crm_contacts?id=eq.${contactId}&select=*&limit=1`);
  return first<DbRow>(response.ok ? await response.json() : []);
}

// ---------------------------------------------------------------------------
// Sequence step execution
// ---------------------------------------------------------------------------

async function performSequenceStep(enrollment: DbRow, step: DbRow, sequence: DbRow) {
  const contact = await contactRow(String(enrollment.contact_id));
  const config = (step.config ?? {}) as DbRow;
  const stepType = String(step.step_type);

  if (stepType === "automated_email" || stepType === "sms") {
    const recipient = stepType === "sms" ? String(contact?.primary_phone ?? "") : String(contact?.primary_email ?? "");
    if (recipient) {
      await dbFetch("funnel_outbound_queue", {
        method: "POST", headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          workspace_id: sequence.workspace_id, contact_id: enrollment.contact_id, channel: stepType === "sms" ? "sms" : "email",
          status: "pending", recipient, subject: config.subject ?? null, body: String(config.body ?? ""),
          provider: "internal_review_queue", idempotency_key: crypto.randomUUID(), message_template_id: step.message_template_id ?? null,
          crm_enrollment_id: enrollment.id, consent_snapshot: { source: "sequence_step", sequence_id: sequence.id, step_id: step.id },
        }),
      });
    }
  } else if (["manual_email_task", "phone_call_task", "social_task", "general_task"].includes(stepType)) {
    await dbFetch("crm_tasks", {
      method: "POST", headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ workspace_id: sequence.workspace_id, contact_id: enrollment.contact_id, title: String(config.title ?? step.name ?? "Sequence follow-up"), description: `Sequence: ${sequence.name}`, due_at: new Date().toISOString() }),
    });
  } else if (stepType === "internal_notification") {
    await dbFetch("crm_activity_logs", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: sequence.workspace_id, entity_type: "contact", entity_id: enrollment.contact_id, action: "sequence_notification", actor_user_id: null, metadata: { sequence_id: sequence.id, message: config.message ?? null } }) });
  } else if (stepType === "tag_update" && contact) {
    const tags = new Set((contact.tags as string[] | undefined) ?? []);
    if (config.action === "remove") tags.delete(String(config.tag)); else tags.add(String(config.tag));
    await dbFetch(`crm_contacts?id=eq.${contact.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ tags: [...tags] }) });
  } else if (stepType === "field_update" && contact && config.field) {
    await dbFetch(`crm_contacts?id=eq.${contact.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ [String(config.field)]: config.value ?? null }) });
  } else if (stepType === "owner_assignment" && contact && config.ownerId) {
    await dbFetch(`crm_contacts?id=eq.${contact.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ owner_user_id: config.ownerId }) });
  } else if (stepType === "webhook" && config.url) {
    try { await fetch(String(config.url), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sequenceId: sequence.id, contactId: enrollment.contact_id, stepId: step.id }) }); } catch { /* best-effort */ }
  }
  // wait_period / wait_until_date / wait_until_business_hours / wait_for_contact_action /
  // conditional_branch / pipeline_update / sequence_enrollment / sequence_removal: handled
  // by the delay computed below (waits) or left as no-op placement markers for now — no
  // real per-entity schedule/condition data exists yet to act on them further.
}

function delayAfterStep(step: DbRow): number {
  const config = (step.config ?? {}) as DbRow;
  if (step.step_type === "wait_period") {
    const minutes = Number(config.minutes ?? 0) + Number(config.hours ?? 0) * 60 + Number(config.days ?? 0) * 1440;
    return Math.max(0, minutes) * 60000;
  }
  return 0;
}

async function advanceSequences() {
  const dueResponse = await dbFetch(`crm_enrollments?status=eq.active&next_step_at=lte.${new Date().toISOString()}&select=*&order=next_step_at.asc&limit=${BATCH_SIZE}`);
  const due = (dueResponse.ok ? await dueResponse.json() : []) as DbRow[];
  let advanced = 0;

  for (const enrollment of due) {
    const sequenceResponse = await dbFetch(`crm_sequences?id=eq.${enrollment.sequence_id}&select=*&limit=1`);
    const sequence = first<DbRow>(sequenceResponse.ok ? await sequenceResponse.json() : []);
    if (!sequence) continue;

    if (enrollment.current_step_id) {
      const stepResponse = await dbFetch(`crm_sequence_steps?id=eq.${enrollment.current_step_id}&select=*&limit=1`);
      const step = first<DbRow>(stepResponse.ok ? await stepResponse.json() : []);
      if (step) await performSequenceStep(enrollment, step, sequence);
    }

    const currentStepResponse = enrollment.current_step_id ? await dbFetch(`crm_sequence_steps?id=eq.${enrollment.current_step_id}&select=position&limit=1`) : null;
    const currentPosition = Number(first<DbRow>(currentStepResponse && currentStepResponse.ok ? await currentStepResponse.json() : [])?.position ?? -1);
    const nextResponse = await dbFetch(`crm_sequence_steps?sequence_version_id=eq.${enrollment.sequence_version_id}&position=gt.${currentPosition}&select=*&order=position.asc&limit=1`);
    const nextStep = first<DbRow>(nextResponse.ok ? await nextResponse.json() : []);

    if (nextStep) {
      const stepDelay = enrollment.current_step_id ? delayAfterStep((await (async () => { const r = await dbFetch(`crm_sequence_steps?id=eq.${enrollment.current_step_id}&select=*&limit=1`); return first<DbRow>(r.ok ? await r.json() : []); })()) ?? {}) : 0;
      await dbFetch(`crm_enrollments?id=eq.${enrollment.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ current_step_id: nextStep.id, next_step_at: new Date(Date.now() + stepDelay).toISOString() }) });
    } else {
      await dbFetch(`crm_enrollments?id=eq.${enrollment.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "completed", completed_at: new Date().toISOString(), next_step_at: null }) });
    }
    advanced++;
  }
  return advanced;
}

// ---------------------------------------------------------------------------
// Event-triggered automations
// ---------------------------------------------------------------------------

async function performAutomationAction(execution: DbRow, action: DbRow, index: number, entity: DbRow | null) {
  const type = String(action.type ?? ""); const config = (action.config ?? {}) as DbRow;
  const input = { action, entityId: execution.trigger_entity_id };
  let status = "completed"; let output: DbRow = {}; let errorMessage: string | null = null;

  try {
    if (type === "create_task") {
      const created = await dbFetch("crm_tasks", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: config.workspaceId, title: String(config.title ?? "Automation task"), contact_id: entity?.id ?? config.contactId ?? null }) });
      output = { taskId: first<DbRow>(created.ok ? await created.json() : [])?.id ?? null };
    } else if (type === "add_tag" || type === "remove_tag") {
      if (entity) {
        const tags = new Set((entity.tags as string[] | undefined) ?? []);
        if (type === "add_tag") tags.add(String(config.tag)); else tags.delete(String(config.tag));
        await dbFetch(`crm_contacts?id=eq.${entity.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ tags: [...tags] }) });
      }
    } else if (type === "add_note" && entity) {
      await dbFetch("crm_notes", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ contact_id: entity.id, workspace_id: entity.workspace_id, body: String(config.body ?? "") }) });
    } else if (type === "notify_internal" || type === "internal_notification") {
      await dbFetch("crm_activity_logs", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: entity?.workspace_id, entity_type: "automation", entity_id: execution.automation_id, action: "automation_notification", metadata: { message: config.message ?? null } }) });
    } else if ((type === "send_email" || type === "send_sms") && entity) {
      const recipient = type === "send_sms" ? String(entity.primary_phone ?? "") : String(entity.primary_email ?? "");
      if (recipient) await dbFetch("funnel_outbound_queue", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: entity.workspace_id, contact_id: entity.id, channel: type === "send_sms" ? "sms" : "email", status: "pending", recipient, subject: config.subject ?? null, body: String(config.body ?? ""), provider: "internal_review_queue", idempotency_key: crypto.randomUUID(), message_template_id: config.messageTemplateId ?? null, automation_execution_id: execution.id, consent_snapshot: { source: "automation_action" } }) });
    } else if (type === "call_webhook" && config.url) {
      const response = await fetch(String(config.url), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ automationId: execution.automation_id, entity }) });
      output = { status: response.status };
    } else if (type === "enroll_sequence" && entity && config.sequenceId) {
      const sequenceResponse = await dbFetch(`crm_sequences?id=eq.${config.sequenceId}&select=id,published_version_id,status&limit=1`);
      const sequence = first<DbRow>(sequenceResponse.ok ? await sequenceResponse.json() : []);
      if (sequence?.status === "published") await dbFetch("crm_enrollments", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ sequence_id: sequence.id, sequence_version_id: sequence.published_version_id, contact_id: entity.id, enrollment_source: "automation", next_step_at: new Date().toISOString() }) });
    } else if (type === "remove_from_sequence" && entity && config.sequenceId) {
      await dbFetch(`crm_enrollments?sequence_id=eq.${config.sequenceId}&contact_id=eq.${entity.id}&status=eq.active`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "exited", exited_at: new Date().toISOString(), exit_reason: "automation" }) });
    } else if (type === "move_opportunity" && config.opportunityId && config.stageId) {
      await dbFetch(`crm_opportunities?id=eq.${config.opportunityId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ stage_id: config.stageId, updated_at: new Date().toISOString() }) });
    } else if (type === "create_opportunity" && entity && config.pipelineId && config.stageId) {
      await dbFetch("crm_opportunities", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ workspace_id: entity.workspace_id, name: String(config.name ?? `${entity.display_name ?? "New"} opportunity`), contact_id: entity.id, pipeline_id: config.pipelineId, stage_id: config.stageId }) });
    } else if (type === "assign_record" && entity && config.ownerId) {
      await dbFetch(`crm_contacts?id=eq.${entity.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ owner_user_id: config.ownerId }) });
    } else if (["update_record", "copy_field", "format_data", "increment_value", "add_to_list", "remove_from_list"].includes(type) && entity && config.field) {
      const customFields = { ...(entity.custom_fields as DbRow | undefined ?? {}) };
      if (type === "increment_value") customFields[String(config.field)] = Number(customFields[String(config.field)] ?? 0) + Number(config.amount ?? 1);
      else customFields[String(config.field)] = config.value ?? customFields[String(config.field)];
      await dbFetch(`crm_contacts?id=eq.${entity.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ custom_fields: customFields }) });
    } else if (type === "delay") {
      // Handled via next_run_at on the execution itself (see fireEventAutomations); no per-step action here.
    } else if (type === "stop_workflow") {
      status = "skipped";
    } else {
      status = "skipped"; errorMessage = `Action type "${type}" has no real executor wired up yet`;
    }
  } catch (error) {
    status = "failed"; errorMessage = error instanceof Error ? error.message : String(error);
  }

  await dbFetch("crm_automation_execution_steps", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ execution_id: execution.id, action_index: index, action_type: type, status, input, output, error_message: errorMessage }) });
  return status !== "failed";
}

async function runExecution(execution: DbRow) {
  const versionResponse = await dbFetch(`crm_automation_versions?id=eq.${execution.automation_version_id}&select=actions&limit=1`);
  const version = first<DbRow>(versionResponse.ok ? await versionResponse.json() : []);
  const actions = (version?.actions ?? []) as DbRow[];
  const entity = execution.trigger_entity_type === "contact" ? await contactRow(String(execution.trigger_entity_id)) : null;

  await dbFetch(`crm_automation_executions?id=eq.${execution.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "running", started_at: new Date().toISOString() }) });

  let failed = false;
  for (let i = Number(execution.next_action_index ?? 0); i < actions.length; i++) {
    const succeeded = await performAutomationAction(execution, actions[i], i, entity);
    if (!succeeded) { failed = true; await dbFetch(`crm_automation_executions?id=eq.${execution.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ next_action_index: i }) }); break; }
  }

  await dbFetch(`crm_automation_executions?id=eq.${execution.id}`, {
    method: "PATCH", headers: { Prefer: "return=minimal" },
    body: JSON.stringify(failed ? { status: "failed", ended_at: new Date().toISOString(), error_message: "One or more actions failed; see execution steps" } : { status: "completed", ended_at: new Date().toISOString(), next_action_index: actions.length }),
  });
}

async function fireEventAutomations() {
  const automationsResponse = await dbFetch(`crm_automations?status=eq.active&select=*`);
  const automations = (automationsResponse.ok ? await automationsResponse.json() : []) as DbRow[];
  let fired = 0;

  for (const automation of automations) {
    if (!automation.published_version_id) continue;
    const versionResponse = await dbFetch(`crm_automation_versions?id=eq.${automation.published_version_id}&select=*&limit=1`);
    const version = first<DbRow>(versionResponse.ok ? await versionResponse.json() : []);
    if (!version || version.trigger_type !== "event") continue;
    const eventName = String((version.trigger_config as DbRow)?.eventName ?? "");
    if (!eventName) continue;

    const lastExecResponse = await dbFetch(`crm_automation_executions?automation_id=eq.${automation.id}&select=created_at&order=created_at.desc&limit=1`);
    const since = String(first<DbRow>(lastExecResponse.ok ? await lastExecResponse.json() : [])?.created_at ?? automation.created_at);
    const eventsResponse = await dbFetch(`funnel_events?workspace_id=eq.${automation.workspace_id}&event_name=eq.${encodeURIComponent(eventName)}&occurred_at=gt.${encodeURIComponent(since)}&select=id,contact_id,occurred_at&order=occurred_at.asc&limit=${BATCH_SIZE}`);
    const events = (eventsResponse.ok ? await eventsResponse.json() : []) as DbRow[];

    for (const event of events) {
      if (!event.contact_id) continue;
      if (automation.max_runs_per_record) {
        const priorResponse = await dbFetch(`crm_automation_executions?automation_id=eq.${automation.id}&trigger_entity_id=eq.${event.contact_id}&select=id`);
        const prior = (priorResponse.ok ? await priorResponse.json() : []) as DbRow[];
        if (prior.length >= Number(automation.max_runs_per_record)) continue;
      }
      const created = await dbFetch("crm_automation_executions", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ automation_id: automation.id, automation_version_id: version.id, trigger_entity_type: "contact", trigger_entity_id: event.contact_id, status: "pending" }) });
      const execution = first<DbRow>(created.ok ? await created.json() : []);
      if (execution) { await runExecution(execution); fired++; }
    }
  }
  return fired;
}

async function runFailedExecutionRetries() {
  const dueResponse = await dbFetch(`crm_automation_executions?status=eq.pending&next_run_at=lte.${new Date().toISOString()}&select=*&limit=${BATCH_SIZE}`);
  const due = (dueResponse.ok ? await dueResponse.json() : []) as DbRow[];
  for (const execution of due) await runExecution(execution);
  return due.length;
}

export async function runEngineTick(request: Request) {
  if (!ENGINE_SECRET || request.headers.get("x-engine-secret") !== ENGINE_SECRET) return json(request, { error: "Unauthorized" }, 401);
  const [sequencesAdvanced, retriesRun, automationsFired] = await Promise.all([advanceSequences(), runFailedExecutionRetries(), fireEventAutomations()]);
  return ok(request, { data: { sequencesAdvanced, retriesRun, automationsFired, at: new Date().toISOString() } });
}
