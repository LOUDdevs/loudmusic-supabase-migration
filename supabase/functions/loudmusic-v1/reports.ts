// Reports: 13 report keys, each backed by a real aggregation query over
// live workspace data. No fixture/placeholder numbers — reports over a
// young workspace will legitimately show mostly zeros until real records
// accumulate, which is correct behavior, not a bug.

import { dbFetch, json, requireViewer, type DbRow } from "./_shared.ts";

type Report = { metrics: Record<string, number | string>; series: DbRow[] };

async function rows(path: string): Promise<DbRow[]> {
  const response = await dbFetch(path);
  return response.ok ? await response.json() : [];
}

function count(list: DbRow[], predicate: (row: DbRow) => boolean): number {
  return list.filter(predicate).length;
}

function groupCount(list: DbRow[], key: string): DbRow[] {
  const counts = new Map<string, number>();
  for (const row of list) { const value = String(row[key] ?? "unspecified"); counts.set(value, (counts.get(value) ?? 0) + 1); }
  return [...counts.entries()].map(([k, v]) => ({ [key]: k, count: v })).sort((a, b) => Number(b.count) - Number(a.count));
}

async function acquisition(w: string): Promise<Report> {
  const contacts = await rows(`crm_contacts?workspace_id=eq.${w}&deleted_at=is.null&select=id,lead_source,created_at`);
  const weekAgo = Date.now() - 7 * 86400000; const monthAgo = Date.now() - 30 * 86400000;
  return {
    metrics: { totalContacts: contacts.length, newThisWeek: count(contacts, (c) => new Date(String(c.created_at)).getTime() >= weekAgo), newThisMonth: count(contacts, (c) => new Date(String(c.created_at)).getTime() >= monthAgo) },
    series: groupCount(contacts, "lead_source"),
  };
}

async function funnelPerformance(w: string): Promise<Report> {
  const [funnels, events] = await Promise.all([
    rows(`funnel_funnels?workspace_id=eq.${w}&select=id,name,status`),
    rows(`funnel_events?workspace_id=eq.${w}&select=funnel_id,event_name`),
  ]);
  return {
    metrics: { totalFunnels: funnels.length, publishedFunnels: count(funnels, (f) => f.status === "published"), totalEvents: events.length },
    series: funnels.map((f) => ({ funnelId: f.id, name: f.name, events: count(events, (e) => e.funnel_id === f.id) })),
  };
}

async function leadQuality(w: string): Promise<Report> {
  const contacts = await rows(`crm_contacts?workspace_id=eq.${w}&deleted_at=is.null&select=id,lifecycle_stage`);
  const qualified = count(contacts, (c) => c.lifecycle_stage === "qualified" || c.lifecycle_stage === "customer");
  return {
    metrics: { totalLeads: contacts.length, qualified, qualifiedRate: contacts.length ? Number(((qualified / contacts.length) * 100).toFixed(1)) : 0 },
    series: groupCount(contacts, "lifecycle_stage"),
  };
}

async function emailPerformance(w: string): Promise<Report> {
  const sends = await rows(`funnel_outbound_queue?workspace_id=eq.${w}&channel=eq.email&select=status`);
  const sent = count(sends, (s) => s.status === "sent"); const failed = count(sends, (s) => s.status === "failed");
  return {
    metrics: { totalQueued: sends.length, sent, failed, deliveryRate: sends.length ? Number((((sends.length - failed) / sends.length) * 100).toFixed(1)) : 0 },
    series: groupCount(sends, "status"),
  };
}

async function sequencePerformance(w: string): Promise<Report> {
  const sequences = await rows(`crm_sequences?workspace_id=eq.${w}&select=id,name,status`);
  const ids = sequences.map((s) => s.id);
  const enrollments = ids.length ? await rows(`crm_enrollments?sequence_id=in.(${ids.join(",")})&select=sequence_id,status`) : [];
  return {
    metrics: { totalSequences: sequences.length, published: count(sequences, (s) => s.status === "published"), totalEnrollments: enrollments.length, activeEnrollments: count(enrollments, (e) => e.status === "active") },
    series: sequences.map((s) => ({ sequenceId: s.id, name: s.name, enrollments: count(enrollments, (e) => e.sequence_id === s.id) })),
  };
}

async function pipelinePerformance(w: string): Promise<Report> {
  const [opportunities, stages] = await Promise.all([
    rows(`crm_opportunities?workspace_id=eq.${w}&is_archived=eq.false&select=id,stage_id,status,value`),
    rows(`crm_pipeline_stages?select=id,name,pipeline_id&pipeline_id=in.(${(await rows(`crm_pipelines?workspace_id=eq.${w}&select=id`)).map((p) => p.id).join(",") || "00000000-0000-0000-0000-000000000000"})`),
  ]);
  const openValue = opportunities.filter((o) => o.status === "open").reduce((sum, o) => sum + Number(o.value ?? 0), 0);
  const wonValue = opportunities.filter((o) => o.status === "won").reduce((sum, o) => sum + Number(o.value ?? 0), 0);
  const closed = count(opportunities, (o) => o.status === "won" || o.status === "lost");
  const won = count(opportunities, (o) => o.status === "won");
  return {
    metrics: { openOpportunities: count(opportunities, (o) => o.status === "open"), openValue: Number(openValue.toFixed(2)), wonValue: Number(wonValue.toFixed(2)), winRate: closed ? Number(((won / closed) * 100).toFixed(1)) : 0 },
    series: stages.map((stage) => ({ stageId: stage.id, name: stage.name, count: count(opportunities, (o) => o.stage_id === stage.id), value: Number(opportunities.filter((o) => o.stage_id === stage.id).reduce((sum, o) => sum + Number(o.value ?? 0), 0).toFixed(2)) })),
  };
}

async function salesActivity(w: string): Promise<Report> {
  const [tasks, activity] = await Promise.all([
    rows(`crm_tasks?workspace_id=eq.${w}&select=id,completed_at,owner_user_id`),
    rows(`crm_activity_logs?workspace_id=eq.${w}&select=id,action`),
  ]);
  return {
    metrics: { tasksCompleted: count(tasks, (t) => Boolean(t.completed_at)), tasksOpen: count(tasks, (t) => !t.completed_at), activitiesLogged: activity.length },
    series: groupCount(activity, "action"),
  };
}

async function revenue(w: string): Promise<Report> {
  const opportunities = await rows(`crm_opportunities?workspace_id=eq.${w}&status=eq.won&select=value,closed_at`);
  const totalWonValue = opportunities.reduce((sum, o) => sum + Number(o.value ?? 0), 0);
  const byMonth = new Map<string, number>();
  for (const o of opportunities) { const month = String(o.closed_at ?? "").slice(0, 7) || "unknown"; byMonth.set(month, (byMonth.get(month) ?? 0) + Number(o.value ?? 0)); }
  return {
    metrics: { totalWonValue: Number(totalWonValue.toFixed(2)), dealsWon: opportunities.length, avgDealSize: opportunities.length ? Number((totalWonValue / opportunities.length).toFixed(2)) : 0 },
    series: [...byMonth.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([month, value]) => ({ month, value: Number(value.toFixed(2)) })),
  };
}

async function retention(w: string): Promise<Report> {
  const contacts = await rows(`crm_contacts?workspace_id=eq.${w}&deleted_at=is.null&select=id,lifecycle_stage,last_contacted_at`);
  const customers = contacts.filter((c) => c.lifecycle_stage === "customer");
  const activeCustomers = customers.filter((c) => c.last_contacted_at && (Date.now() - new Date(String(c.last_contacted_at)).getTime()) < 90 * 86400000);
  return {
    metrics: { totalCustomers: customers.length, activeLast90Days: activeCustomers.length, retentionRate: customers.length ? Number(((activeCustomers.length / customers.length) * 100).toFixed(1)) : 0 },
    series: groupCount(contacts, "lifecycle_stage"),
  };
}

async function teamProductivity(w: string): Promise<Report> {
  const tasks = await rows(`crm_tasks?workspace_id=eq.${w}&completed_at=not.is.null&select=owner_user_id`);
  return { metrics: { totalCompletedTasks: tasks.length }, series: groupCount(tasks, "owner_user_id") };
}

async function attribution(w: string): Promise<Report> {
  const opportunities = await rows(`crm_opportunities?workspace_id=eq.${w}&select=id,source,value`);
  return {
    metrics: { totalOpportunities: opportunities.length, totalValue: Number(opportunities.reduce((sum, o) => sum + Number(o.value ?? 0), 0).toFixed(2)) },
    series: groupCount(opportunities, "source"),
  };
}

async function automationPerformance(w: string): Promise<Report> {
  const automations = await rows(`crm_automations?workspace_id=eq.${w}&select=id,name,status`);
  const ids = automations.map((a) => a.id);
  const executions = ids.length ? await rows(`crm_automation_executions?automation_id=in.(${ids.join(",")})&select=automation_id,status`) : [];
  const completed = count(executions, (e) => e.status === "completed"); const failed = count(executions, (e) => e.status === "failed" || e.status === "dead_letter");
  return {
    metrics: { totalAutomations: automations.length, activeAutomations: count(automations, (a) => a.status === "active"), totalExecutions: executions.length, successRate: executions.length ? Number(((completed / executions.length) * 100).toFixed(1)) : 0, failedExecutions: failed },
    series: automations.map((a) => ({ automationId: a.id, name: a.name, executions: count(executions, (e) => e.automation_id === a.id) })),
  };
}

async function dataQuality(w: string): Promise<Report> {
  const contacts = await rows(`crm_contacts?workspace_id=eq.${w}&deleted_at=is.null&select=id,primary_email,primary_phone,lifecycle_stage`);
  return {
    metrics: { totalContacts: contacts.length, missingEmail: count(contacts, (c) => !c.primary_email), missingPhone: count(contacts, (c) => !c.primary_phone) },
    series: groupCount(contacts, "lifecycle_stage"),
  };
}

const REPORTS: Record<string, (w: string) => Promise<Report>> = {
  "acquisition": acquisition, "funnel-performance": funnelPerformance, "lead-quality": leadQuality,
  "email-performance": emailPerformance, "sequence-performance": sequencePerformance, "pipeline-performance": pipelinePerformance,
  "sales-activity": salesActivity, "revenue": revenue, "retention": retention, "team-productivity": teamProductivity,
  "attribution": attribution, "automation-performance": automationPerformance, "data-quality": dataQuality,
};

export async function getAnalyticsReport(request: Request, reportKey: string) {
  const viewer = await requireViewer(request); if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const builder = REPORTS[reportKey];
  if (!builder) return json(request, { error: `Unknown report key. Expected one of: ${Object.keys(REPORTS).join(", ")}` }, 404);
  const { metrics, series } = await builder(viewer.user.workspaceId);
  return json(request, { data: { reportKey, generatedAt: new Date().toISOString(), dateRange: {}, metrics, series, comparison: {}, dataFreshness: new Date().toISOString() } });
}
