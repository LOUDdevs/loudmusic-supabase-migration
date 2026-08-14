// Job board: public directory/search/apply + admin jobs/companies/applicants.
// Companies reuse marketing.crm_organizations (see migration 20260814080000).
// Everything else lives in marketing.jobs_* tables. No candidate accounts —
// applications are anonymous, matching the artist-bio-survey/lead pattern
// already used elsewhere in this API.

import { SUPABASE_URL, SERVICE_KEY, dbFetch, json, readJson, first, workspaceFor, requireViewer, slugify, type DbRow } from "./_shared.ts";

const JOB_SELECT = "*,company:crm_organizations(id,name,logo_url,industry,headquarters,verified,public_slug)";

function toInt(value: string | null, fallback: number) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function publicJobFilterBase() {
  const now = new Date().toISOString();
  return `status=eq.published&is_private=eq.false&or=(publish_at.is.null,publish_at.lte.${now})&or=(expires_at.is.null,expires_at.gt.${now})`;
}

// ---------------------------------------------------------------------------
// Public: directory / search
// ---------------------------------------------------------------------------
export async function listJobsPublic(request: Request) {
  const url = new URL(request.url);
  const q = url.searchParams;
  const page = toInt(q.get("page"), 1);
  const limit = Math.min(toInt(q.get("limit"), 20), 50);
  const offset = (page - 1) * limit;

  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace is not configured" }, 500);

  const params = new URLSearchParams();
  params.set("select", JOB_SELECT);
  params.set("workspace_id", `eq.${workspace.id}`);
  params.set("status", "eq.published");
  params.set("is_private", "eq.false");
  const now = new Date().toISOString();

  const search = q.get("search")?.trim();
  if (search) params.set("search_vector", `wfts(english).${search}`);

  const location = q.get("location")?.trim();
  if (location) params.append("or", `(city.ilike.*${location}*,state.ilike.*${location}*,country.ilike.*${location}*)`);

  const category = q.get("category")?.trim();
  if (category) {
    const cat = await dbFetch(`jobs_categories?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(category)}&select=id&limit=1`);
    const catRow = first<{ id: string }>(cat.ok ? await cat.json() : []);
    params.set("category_id", `eq.${catRow?.id ?? "00000000-0000-0000-0000-000000000000"}`);
  }

  const department = q.get("department")?.trim();
  if (department) {
    const dep = await dbFetch(`jobs_departments?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(department)}&select=id&limit=1`);
    const depRow = first<{ id: string }>(dep.ok ? await dep.json() : []);
    params.set("department_id", `eq.${depRow?.id ?? "00000000-0000-0000-0000-000000000000"}`);
  }

  const employmentType = q.get("employment_type")?.trim();
  if (employmentType) params.set("employment_type", `eq.${employmentType}`);

  const workplaceType = q.get("workplace_type")?.trim() || (q.get("remote") === "true" ? "remote" : "");
  if (workplaceType) params.set("workplace_type", `eq.${workplaceType}`);

  const salaryMin = q.get("salary_min");
  if (salaryMin) params.set("salary_max", `gte.${salaryMin}`);

  const skills = q.get("skills")?.trim();
  if (skills) params.set("skills", `cs.{${skills.split(",").map((s) => s.trim()).filter(Boolean).join(",")}}`);

  const companyId = q.get("company_id")?.trim();
  if (companyId) params.set("company_id", `eq.${companyId}`);

  const datePosted = q.get("date_posted")?.trim();
  if (datePosted) {
    const days = Number(datePosted);
    if (Number.isFinite(days) && days > 0) {
      const since = new Date(Date.now() - days * 86400000).toISOString();
      params.set("created_at", `gte.${since}`);
    }
  }

  const sort = q.get("sort") ?? "relevance";
  const order = sort === "newest" ? "created_at.desc"
    : sort === "salary" ? "salary_max.desc.nullslast,created_at.desc"
    : sort === "popular" ? "view_count.desc,created_at.desc"
    : "featured.desc,promoted_rank.desc,created_at.desc"; // relevance / featured default
  params.set("order", order);
  params.set("limit", String(limit));
  params.set("offset", String(offset));

  const response = await dbFetch(`jobs_postings?${params.toString()}`, { headers: { Prefer: "count=exact" } });
  const rows = response.ok ? await response.json() : [];
  const range = response.headers.get("content-range") ?? "*/0";
  const total = Number(range.split("/")[1] ?? 0);

  return json(request, { data: rows, meta: { page, limit, total, totalPages: Math.max(1, Math.ceil(total / limit)) } });
}

export async function listJobCategoriesPublic(request: Request) {
  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace is not configured" }, 500);
  const [catsRes, depsRes] = await Promise.all([
    dbFetch(`jobs_categories?workspace_id=eq.${workspace.id}&select=id,name,slug&order=sort_order.asc`),
    dbFetch(`jobs_departments?workspace_id=eq.${workspace.id}&select=id,name,slug&order=sort_order.asc`),
  ]);
  return json(request, { data: { categories: catsRes.ok ? await catsRes.json() : [], departments: depsRes.ok ? await depsRes.json() : [] } });
}

export async function getJobPublic(request: Request, slug: string) {
  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace is not configured" }, 500);
  const response = await dbFetch(`jobs_postings?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(slug)}&${publicJobFilterBase()}&select=${JOB_SELECT}&limit=1`);
  const job = first<DbRow>(response.ok ? await response.json() : []);
  if (!job) return json(request, { error: "This job posting is not available." }, 404);

  const [questionsRes, similarRes, sameCompanyRes] = await Promise.all([
    dbFetch(`jobs_questions?posting_id=eq.${job.id}&select=id,label,question_type,options,required,sort_order&order=sort_order.asc`),
    dbFetch(`jobs_postings?workspace_id=eq.${workspace.id}&id=neq.${job.id}&category_id=eq.${job.category_id ?? "00000000-0000-0000-0000-000000000000"}&${publicJobFilterBase()}&select=id,title,slug,employment_type,workplace_type,city,state,company:crm_organizations(name,logo_url)&order=created_at.desc&limit=4`),
    dbFetch(`jobs_postings?workspace_id=eq.${workspace.id}&id=neq.${job.id}&company_id=eq.${job.company_id}&${publicJobFilterBase()}&select=id,title,slug,employment_type,workplace_type,city,state&order=created_at.desc&limit=4`),
  ]);

  // View counter — best-effort, not blocking the response.
  dbFetch(`jobs_postings?id=eq.${job.id}`, { method: "PATCH", body: JSON.stringify({ view_count: Number(job.view_count ?? 0) + 1 }) }).catch(() => {});
  dbFetch(`jobs_events`, { method: "POST", body: JSON.stringify({ posting_id: job.id, event_type: "view" }) }).catch(() => {});

  return json(request, {
    data: {
      job,
      questions: questionsRes.ok ? await questionsRes.json() : [],
      similarJobs: similarRes.ok ? await similarRes.json() : [],
      companyJobs: sameCompanyRes.ok ? await sameCompanyRes.json() : [],
    },
  });
}

export async function getCompanyPublic(request: Request, slug: string) {
  const companyRes = await dbFetch(`crm_organizations?public_slug=eq.${encodeURIComponent(slug)}&is_employer=eq.true&archived_at=is.null&select=id,name,logo_url,cover_image_url,description,website,industry,company_size,founded_year,headquarters,social_links,benefits,culture,photos,verified,public_slug&limit=1`);
  const company = first<DbRow>(companyRes.ok ? await companyRes.json() : []);
  if (!company) return json(request, { error: "Company not found" }, 404);
  const jobsRes = await dbFetch(`jobs_postings?company_id=eq.${company.id}&${publicJobFilterBase()}&select=id,title,slug,employment_type,workplace_type,city,state,country,created_at,featured&order=featured.desc,created_at.desc`);
  return json(request, { data: { company, jobs: jobsRes.ok ? await jobsRes.json() : [] } });
}

// ---------------------------------------------------------------------------
// Public: apply / save / alerts / events
// ---------------------------------------------------------------------------
export async function applyToJob(request: Request, slug: string) {
  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace is not configured" }, 500);
  const body = await readJson(request);

  const jobRes = await dbFetch(`jobs_postings?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(slug)}&${publicJobFilterBase()}&select=id,title&limit=1`);
  const job = first<DbRow>(jobRes.ok ? await jobRes.json() : []);
  if (!job) return json(request, { error: "This job posting is not available." }, 404);

  const firstName = String(body.first_name ?? "").trim();
  const lastName = String(body.last_name ?? "").trim();
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!firstName || !lastName || !email) return json(request, { error: "First name, last name, and email are required." }, 400);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json(request, { error: "Enter a valid email address." }, 400);

  const settingsRes = await dbFetch(`jobs_settings?workspace_id=eq.${workspace.id}&key=eq.candidate&select=value&limit=1`);
  const settings = first<{ value: DbRow }>(settingsRes.ok ? await settingsRes.json() : []);
  const resumeRequired = Boolean(settings?.value?.resume_required ?? true);
  const resumePath = body.resume_path ? String(body.resume_path) : null;
  if (resumeRequired && !resumePath) return json(request, { error: "A resume is required to apply." }, 400);

  const insert = {
    posting_id: job.id,
    workspace_id: workspace.id,
    first_name: firstName,
    last_name: lastName,
    email,
    phone: body.phone ? String(body.phone) : null,
    location: body.location ? String(body.location) : null,
    resume_path: resumePath,
    resume_filename: body.resume_filename ? String(body.resume_filename) : null,
    cover_letter: body.cover_letter ? String(body.cover_letter) : null,
    linkedin_url: body.linkedin_url ? String(body.linkedin_url) : null,
    portfolio_url: body.portfolio_url ? String(body.portfolio_url) : null,
    website_url: body.website_url ? String(body.website_url) : null,
    source: body.source ? String(body.source) : "direct",
    visitor_id: body.visitor_id ?? null,
    current_stage: "new",
  };

  const response = await dbFetch("jobs_applications", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!response.ok) {
    const text = await response.text();
    if (text.includes("idx_jobs_applications_dedupe") || response.status === 409) {
      return json(request, { error: "You've already applied to this job today." }, 409);
    }
    return json(request, { error: "We could not submit your application. Please try again." }, 400);
  }
  const application = first<DbRow>(await response.json());
  if (!application) return json(request, { error: "We could not submit your application. Please try again." }, 400);

  const answers = Array.isArray(body.answers) ? body.answers as Array<{ question_id: string; answer: string }> : [];
  if (answers.length) {
    await dbFetch("jobs_application_answers", {
      method: "POST",
      body: JSON.stringify(answers.filter((a) => a.question_id).map((a) => ({ application_id: application.id, question_id: a.question_id, answer: String(a.answer ?? "") }))),
    }).catch(() => {});
  }

  await Promise.all([
    dbFetch("jobs_application_stage_history", { method: "POST", body: JSON.stringify({ application_id: application.id, from_stage: null, to_stage: "new" }) }),
    dbFetch(`jobs_postings?id=eq.${job.id}`, { method: "PATCH", body: JSON.stringify({}) }), // touch updated_at via trigger; count handled below
    dbFetch("jobs_events", { method: "POST", body: JSON.stringify({ posting_id: job.id, event_type: "apply_complete", source: insert.source }) }),
  ]).catch(() => {});

  // Denormalized application_count bump (best-effort, not transactional).
  const countRes = await dbFetch(`jobs_applications?posting_id=eq.${job.id}&select=id`, { headers: { Prefer: "count=exact", Range: "0-0" } });
  const total = Number((countRes.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);
  await dbFetch(`jobs_postings?id=eq.${job.id}`, { method: "PATCH", body: JSON.stringify({ application_count: total }) }).catch(() => {});

  const confirmRes = await dbFetch(`jobs_settings?workspace_id=eq.${workspace.id}&key=eq.application&select=value&limit=1`);
  const confirm = first<{ value: DbRow }>(confirmRes.ok ? await confirmRes.json() : []);

  return json(request, {
    data: {
      applicationId: application.id,
      message: String(confirm?.value?.confirmation_message ?? "Thanks for applying — we'll be in touch."),
    },
  }, 201);
}

export async function recordJobEvent(request: Request, slug: string) {
  const workspace = await workspaceFor();
  if (!workspace) return json(request, { error: "Workspace is not configured" }, 500);
  const body = await readJson(request);
  const eventType = String(body.event_type ?? "");
  const allowed = ["impression", "apply_click", "apply_start", "save", "unsave", "share"];
  if (!allowed.includes(eventType)) return json(request, { error: "Unsupported event type" }, 400);
  const jobRes = await dbFetch(`jobs_postings?workspace_id=eq.${workspace.id}&slug=eq.${encodeURIComponent(slug)}&select=id&limit=1`);
  const job = first<DbRow>(jobRes.ok ? await jobRes.json() : []);
  if (!job) return json(request, { error: "Job not found" }, 404);
  await dbFetch("jobs_events", { method: "POST", body: JSON.stringify({ posting_id: job.id, event_type: eventType, visitor_id: body.visitor_id ?? null, source: body.source ?? null }) });
  return json(request, { data: { recorded: true } });
}

export async function saveJob(request: Request) {
  const body = await readJson(request);
  const visitorId = String(body.visitor_id ?? "");
  const postingId = String(body.posting_id ?? "");
  if (!visitorId || !postingId) return json(request, { error: "visitor_id and posting_id are required" }, 400);
  const response = await dbFetch("jobs_saved?on_conflict=visitor_id,posting_id", { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=representation" }, body: JSON.stringify({ visitor_id: visitorId, posting_id: postingId }) });
  if (!response.ok) return json(request, { error: "Could not save this job" }, 400);
  await dbFetch("jobs_events", { method: "POST", body: JSON.stringify({ posting_id: postingId, event_type: "save", visitor_id: visitorId }) }).catch(() => {});
  return json(request, { data: { saved: true } });
}

export async function unsaveJob(request: Request) {
  const body = await readJson(request);
  const visitorId = String(body.visitor_id ?? "");
  const postingId = String(body.posting_id ?? "");
  if (!visitorId || !postingId) return json(request, { error: "visitor_id and posting_id are required" }, 400);
  await dbFetch(`jobs_saved?visitor_id=eq.${visitorId}&posting_id=eq.${postingId}`, { method: "DELETE" });
  return json(request, { data: { saved: false } });
}

export async function listSavedJobs(request: Request) {
  const url = new URL(request.url);
  const visitorId = url.searchParams.get("visitor_id") ?? "";
  if (!visitorId) return json(request, { data: [] });
  const response = await dbFetch(`jobs_saved?visitor_id=eq.${visitorId}&select=id,created_at,posting:jobs_postings(id,title,slug,status,employment_type,workplace_type,city,state,company:crm_organizations(name,logo_url))&order=created_at.desc`);
  return json(request, { data: response.ok ? await response.json() : [] });
}

export async function createAlert(request: Request) {
  const body = await readJson(request);
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json(request, { error: "A valid email is required" }, 400);
  const insert = { email, label: body.label ? String(body.label) : null, query: body.query ?? {}, frequency: ["immediate", "daily", "weekly"].includes(body.frequency) ? body.frequency : "daily" };
  const response = await dbFetch("jobs_alerts", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!response.ok) return json(request, { error: "Could not create alert" }, 400);
  return json(request, { data: first(await response.json()) }, 201);
}

export async function listAlerts(request: Request) {
  const url = new URL(request.url);
  const email = (url.searchParams.get("email") ?? "").trim().toLowerCase();
  if (!email) return json(request, { data: [] });
  const response = await dbFetch(`jobs_alerts?email=eq.${encodeURIComponent(email)}&select=*&order=created_at.desc`);
  return json(request, { data: response.ok ? await response.json() : [] });
}

export async function updateAlert(request: Request, id: string) {
  const body = await readJson(request);
  const patch: DbRow = {};
  if (typeof body.active === "boolean") patch.active = body.active;
  if (typeof body.frequency === "string") patch.frequency = body.frequency;
  if (typeof body.label === "string") patch.label = body.label;
  await dbFetch(`jobs_alerts?id=eq.${id}`, { method: "PATCH", body: JSON.stringify(patch) });
  return json(request, { data: { updated: true } });
}

export async function deleteAlert(request: Request, id: string) {
  await dbFetch(`jobs_alerts?id=eq.${id}`, { method: "DELETE" });
  return json(request, { data: { deleted: true } });
}

// ---------------------------------------------------------------------------
// Admin: dashboard + jobs CRUD
// ---------------------------------------------------------------------------
export async function adminJobsStats(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const wid = viewer.user.workspaceId;

  const countBy = async (filter: string) => {
    const res = await dbFetch(`jobs_postings?workspace_id=eq.${wid}&${filter}&select=id`, { headers: { Prefer: "count=exact", Range: "0-0" } });
    return Number((res.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);
  };
  const soon = new Date(Date.now() + 7 * 86400000).toISOString();

  const [active, drafts, expiringSoon, filled, totalsRes, weekAppsRes, topRes] = await Promise.all([
    countBy("status=eq.published"),
    countBy("status=eq.draft"),
    countBy(`status=eq.published&expires_at=lte.${soon}&expires_at=gt.${new Date().toISOString()}`),
    countBy("status=eq.filled"),
    dbFetch(`jobs_postings?workspace_id=eq.${wid}&select=view_count,application_count`),
    dbFetch(`jobs_applications?workspace_id=eq.${wid}&created_at=gte.${new Date(Date.now() - 7 * 86400000).toISOString()}&select=id`, { headers: { Prefer: "count=exact", Range: "0-0" } }),
    dbFetch(`jobs_postings?workspace_id=eq.${wid}&status=eq.published&select=id,title,view_count,application_count&order=application_count.desc&limit=5`),
  ]);

  const totals = totalsRes.ok ? await totalsRes.json() as DbRow[] : [];
  const totalViews = totals.reduce((sum, r) => sum + Number(r.view_count ?? 0), 0);
  const totalApplications = totals.reduce((sum, r) => sum + Number(r.application_count ?? 0), 0);
  const applicationsThisWeek = Number((weekAppsRes.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);

  return json(request, {
    data: {
      activeJobs: active,
      draftJobs: drafts,
      expiringJobs: expiringSoon,
      filledJobs: filled,
      totalViews,
      totalApplications,
      conversionRate: totalViews > 0 ? Number(((totalApplications / totalViews) * 100).toFixed(1)) : 0,
      applicationsThisWeek,
      topListings: topRes.ok ? await topRes.json() : [],
    },
  });
}

export async function adminListJobs(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const q = url.searchParams;
  const page = toInt(q.get("page"), 1);
  const limit = Math.min(toInt(q.get("limit"), 25), 100);
  const params = new URLSearchParams();
  params.set("select", JOB_SELECT);
  params.set("workspace_id", `eq.${viewer.user.workspaceId}`);
  const status = q.get("status");
  if (status) params.set("status", `eq.${status}`);
  const search = q.get("search")?.trim();
  if (search) params.append("or", `(title.ilike.*${search}*)`);
  params.set("order", q.get("sort") === "oldest" ? "created_at.asc" : "created_at.desc");
  params.set("limit", String(limit));
  params.set("offset", String((page - 1) * limit));
  const response = await dbFetch(`jobs_postings?${params.toString()}`, { headers: { Prefer: "count=exact" } });
  const rows = response.ok ? await response.json() : [];
  const total = Number((response.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);
  return json(request, { data: rows, meta: { page, limit, total, totalPages: Math.max(1, Math.ceil(total / limit)) } });
}

async function uniqueJobSlug(workspaceId: string, base: string, excludeId?: string) {
  let slug = slugify(base);
  let attempt = 0;
  while (attempt < 25) {
    const candidate = attempt === 0 ? slug : `${slug}-${attempt + 1}`;
    const params = new URLSearchParams({ workspace_id: `eq.${workspaceId}`, slug: `eq.${candidate}`, select: "id", limit: "1" });
    if (excludeId) params.set("id", `neq.${excludeId}`);
    const res = await dbFetch(`jobs_postings?${params.toString()}`);
    const rows = res.ok ? await res.json() : [];
    if (!rows.length) return candidate;
    attempt++;
  }
  return `${slug}-${crypto.randomUUID().slice(0, 6)}`;
}

function jobPayload(body: DbRow): DbRow {
  const allowed = [
    "title", "company_id", "department_id", "category_id", "description", "responsibilities", "requirements",
    "preferred_qualifications", "skills", "experience_level", "education_requirement", "openings",
    "employment_type", "workplace_type", "city", "state", "country", "address", "additional_locations",
    "salary_min", "salary_max", "salary_period", "currency", "salary_visible", "commission_details",
    "bonus_info", "equity_info", "compensation_notes", "benefits", "publish_at", "expires_at",
    "application_deadline", "featured", "urgent", "is_private", "promoted_rank", "seo_title",
    "seo_description", "social_image_url", "owner_id",
  ];
  const payload: DbRow = {};
  for (const key of allowed) if (key in body) payload[key] = body[key];
  return payload;
}

export async function adminCreateJob(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  if (!body.title || !body.company_id) return json(request, { error: "Job title and company are required" }, 400);
  const slug = await uniqueJobSlug(viewer.user.workspaceId, String(body.title));
  const insert = { ...jobPayload(body), workspace_id: viewer.user.workspaceId, slug, status: "draft", created_by: viewer.user.id, updated_by: viewer.user.id };
  const response = await dbFetch("jobs_postings", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!response.ok) return json(request, { error: "Could not create job posting" }, 400);
  const job = first<DbRow>(await response.json());
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action: "job_created", entity_type: "job_posting", entity_id: job?.id, after: job }) }).catch(() => {});
  return json(request, { data: job }, 201);
}

export async function adminGetJob(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=${JOB_SELECT}&limit=1`);
  const job = first<DbRow>(response.ok ? await response.json() : []);
  if (!job) return json(request, { error: "Job posting not found" }, 404);
  const questionsRes = await dbFetch(`jobs_questions?posting_id=eq.${id}&select=*&order=sort_order.asc`);
  return json(request, { data: { job, questions: questionsRes.ok ? await questionsRes.json() : [] } });
}

export async function adminUpdateJob(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const before = first<DbRow>(await (await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=*&limit=1`)).json());
  if (!before) return json(request, { error: "Job posting not found" }, 404);
  const patch = jobPayload(body);
  if (typeof body.title === "string" && body.title !== before.title && !body.slug) {
    patch.slug = await uniqueJobSlug(viewer.user.workspaceId, body.title, id);
  }
  patch.updated_by = viewer.user.id;
  const response = await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!response.ok) return json(request, { error: "Could not update job posting" }, 400);
  const job = first<DbRow>(await response.json());
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action: "job_updated", entity_type: "job_posting", entity_id: id, before, after: job }) }).catch(() => {});
  return json(request, { data: job });
}

async function transitionJobStatus(request: Request, id: string, status: string, action: string, extra: DbRow = {}) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const patch: DbRow = { status, updated_by: viewer.user.id, ...extra };
  if (status === "published" && !extra.publish_at) patch.publish_at = new Date().toISOString();
  const response = await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!response.ok) return json(request, { error: `Could not ${action} job posting` }, 400);
  const job = first<DbRow>(await response.json());
  if (!job) return json(request, { error: "Job posting not found" }, 404);
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action, entity_type: "job_posting", entity_id: id, after: { status } }) }).catch(() => {});
  return json(request, { data: job });
}

export const adminPublishJob = (request: Request, id: string) => transitionJobStatus(request, id, "published", "job_published");
export const adminPauseJob = (request: Request, id: string) => transitionJobStatus(request, id, "paused", "job_paused");
export const adminFillJob = (request: Request, id: string) => transitionJobStatus(request, id, "filled", "job_filled");
export const adminArchiveJob = (request: Request, id: string) => transitionJobStatus(request, id, "archived", "job_archived", { archived_at: new Date().toISOString() });
export const adminSubmitForApproval = (request: Request, id: string) => transitionJobStatus(request, id, "pending_approval", "job_submitted_for_approval");

export async function adminDuplicateJob(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const source = first<DbRow>(await (await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=*&limit=1`)).json());
  if (!source) return json(request, { error: "Job posting not found" }, 404);
  const { id: _id, slug: _slug, created_at: _c, updated_at: _u, view_count: _v, application_count: _a, ...rest } = source;
  const slug = await uniqueJobSlug(viewer.user.workspaceId, `${source.title} copy`);
  const insert = { ...rest, slug, status: "draft", view_count: 0, application_count: 0, created_by: viewer.user.id, updated_by: viewer.user.id };
  const response = await dbFetch("jobs_postings", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
  if (!response.ok) return json(request, { error: "Could not duplicate job posting" }, 400);
  return json(request, { data: first(await response.json()) }, 201);
}

export async function adminDeleteJob(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const countRes = await dbFetch(`jobs_applications?posting_id=eq.${id}&select=id`, { headers: { Prefer: "count=exact", Range: "0-0" } });
  const appCount = Number((countRes.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);
  if (appCount > 0) return transitionJobStatus(request, id, "archived", "job_archived_instead_of_delete", { archived_at: new Date().toISOString() });
  await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE" });
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action: "job_deleted", entity_type: "job_posting", entity_id: id }) }).catch(() => {});
  return json(request, { data: { deleted: true } });
}

export async function adminBulkJobs(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const ids = Array.isArray(body.ids) ? body.ids as string[] : [];
  const action = String(body.action ?? "");
  if (!ids.length) return json(request, { error: "No jobs selected" }, 400);
  const statusMap: Record<string, string> = { publish: "published", pause: "paused", archive: "archived", fill: "filled" };
  if (!(action in statusMap)) return json(request, { error: "Unsupported bulk action" }, 400);
  const idFilter = `in.(${ids.join(",")})`;
  await dbFetch(`jobs_postings?workspace_id=eq.${viewer.user.workspaceId}&id=${idFilter}`, { method: "PATCH", body: JSON.stringify({ status: statusMap[action], updated_by: viewer.user.id }) });
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action: `bulk_${action}`, entity_type: "job_posting", after: { ids } }) }).catch(() => {});
  return json(request, { data: { updated: ids.length } });
}

export async function adminSetJobQuestions(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const questions = Array.isArray(body.questions) ? body.questions as DbRow[] : [];
  await dbFetch(`jobs_questions?posting_id=eq.${id}`, { method: "DELETE" });
  if (questions.length) {
    const rows = questions.map((q, i) => ({
      posting_id: id, label: String(q.label ?? ""), question_type: String(q.question_type ?? "short_text"),
      options: q.options ?? [], required: Boolean(q.required), sort_order: i,
    }));
    await dbFetch("jobs_questions", { method: "POST", body: JSON.stringify(rows) });
  }
  return json(request, { data: { saved: true } });
}

export async function adminExportJobsCsv(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`jobs_postings?workspace_id=eq.${viewer.user.workspaceId}&select=title,slug,status,employment_type,workplace_type,city,state,country,view_count,application_count,created_at,expires_at&order=created_at.desc`);
  const rows = response.ok ? await response.json() as DbRow[] : [];
  const header = ["Title", "Slug", "Status", "Employment Type", "Workplace", "City", "State", "Country", "Views", "Applications", "Created", "Expires"];
  const csvRows = rows.map((r) => [r.title, r.slug, r.status, r.employment_type, r.workplace_type, r.city, r.state, r.country, r.view_count, r.application_count, r.created_at, r.expires_at]
    .map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(","));
  const csv = [header.join(","), ...csvRows].join("\n");
  return new Response(csv, { status: 200, headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=jobs.csv" } });
}

// ---------------------------------------------------------------------------
// Admin: applicants / ATS
// ---------------------------------------------------------------------------
export async function adminListApplications(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const q = url.searchParams;
  const params = new URLSearchParams();
  params.set("select", "*,posting:jobs_postings(id,title,slug)");
  params.set("workspace_id", `eq.${viewer.user.workspaceId}`);
  const postingId = q.get("posting_id");
  if (postingId) params.set("posting_id", `eq.${postingId}`);
  const stage = q.get("stage");
  if (stage) params.set("current_stage", `eq.${stage}`);
  const search = q.get("search")?.trim();
  if (search) params.append("or", `(first_name.ilike.*${search}*,last_name.ilike.*${search}*,email.ilike.*${search}*)`);
  params.set("order", "created_at.desc");
  const page = toInt(q.get("page"), 1);
  const limit = Math.min(toInt(q.get("limit"), 50), 200);
  params.set("limit", String(limit));
  params.set("offset", String((page - 1) * limit));
  const response = await dbFetch(`jobs_applications?${params.toString()}`, { headers: { Prefer: "count=exact" } });
  const rows = response.ok ? await response.json() : [];
  const total = Number((response.headers.get("content-range") ?? "*/0").split("/")[1] ?? 0);
  return json(request, { data: rows, meta: { page, limit, total } });
}

export async function adminGetApplication(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const [appRes, answersRes, notesRes, historyRes, attachmentsRes] = await Promise.all([
    dbFetch(`jobs_applications?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=*,posting:jobs_postings(id,title,slug)&limit=1`),
    dbFetch(`jobs_application_answers?application_id=eq.${id}&select=*,question:jobs_questions(label,question_type)`),
    dbFetch(`jobs_application_notes?application_id=eq.${id}&select=*&order=created_at.desc`),
    dbFetch(`jobs_application_stage_history?application_id=eq.${id}&select=*&order=changed_at.desc`),
    dbFetch(`jobs_application_attachments?application_id=eq.${id}&select=*`),
  ]);
  const application = first<DbRow>(appRes.ok ? await appRes.json() : []);
  if (!application) return json(request, { error: "Application not found" }, 404);
  return json(request, {
    data: {
      application,
      answers: answersRes.ok ? await answersRes.json() : [],
      notes: notesRes.ok ? await notesRes.json() : [],
      history: historyRes.ok ? await historyRes.json() : [],
      attachments: attachmentsRes.ok ? await attachmentsRes.json() : [],
    },
  });
}

export async function adminUpdateApplicationStage(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const toStage = String(body.to_stage ?? "");
  if (!toStage) return json(request, { error: "to_stage is required" }, 400);
  const current = first<DbRow>(await (await dbFetch(`jobs_applications?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=current_stage&limit=1`)).json());
  if (!current) return json(request, { error: "Application not found" }, 404);
  await dbFetch(`jobs_applications?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ current_stage: toStage }) });
  await dbFetch("jobs_application_stage_history", { method: "POST", body: JSON.stringify({ application_id: id, from_stage: current.current_stage, to_stage: toStage, changed_by: viewer.user.id }) });
  await dbFetch("jobs_audit_log", { method: "POST", body: JSON.stringify({ workspace_id: viewer.user.workspaceId, actor_id: viewer.user.id, action: "candidate_stage_changed", entity_type: "application", entity_id: id, before: { stage: current.current_stage }, after: { stage: toStage } }) }).catch(() => {});
  return json(request, { data: { updated: true } });
}

export async function adminUpdateApplication(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const patch: DbRow = {};
  if (typeof body.rating === "number") patch.rating = body.rating;
  if (Array.isArray(body.tags)) patch.tags = body.tags;
  if (typeof body.assigned_to === "string") patch.assigned_to = body.assigned_to;
  const response = await dbFetch(`jobs_applications?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(patch) });
  if (!response.ok) return json(request, { error: "Could not update application" }, 400);
  return json(request, { data: first(await response.json()) });
}

export async function adminAddApplicationNote(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const note = String(body.note ?? "").trim();
  if (!note) return json(request, { error: "Note text is required" }, 400);
  const response = await dbFetch("jobs_application_notes", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ application_id: id, author_id: viewer.user.id, note }) });
  return json(request, { data: first(response.ok ? await response.json() : []) }, 201);
}

export async function adminApplicationResumeUrl(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const app = first<DbRow>(await (await dbFetch(`jobs_applications?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}&select=resume_path,resume_filename&limit=1`)).json());
  if (!app?.resume_path) return json(request, { error: "No resume on file" }, 404);
  const signRes = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/job-applications/${app.resume_path}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ expiresIn: 600 }),
  });
  const signed = await signRes.json().catch(() => ({}));
  if (!signRes.ok || !signed.signedURL) return json(request, { error: "Could not generate download link" }, 500);
  return json(request, { data: { url: `${SUPABASE_URL}/storage/v1${signed.signedURL}`, filename: app.resume_filename } });
}

export async function adminExportApplicationsCsv(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const postingId = url.searchParams.get("posting_id");
  const params = new URLSearchParams({ workspace_id: `eq.${viewer.user.workspaceId}`, select: "first_name,last_name,email,phone,location,current_stage,rating,source,created_at,posting:jobs_postings(title)", order: "created_at.desc" });
  if (postingId) params.set("posting_id", `eq.${postingId}`);
  const response = await dbFetch(`jobs_applications?${params.toString()}`);
  const rows = response.ok ? await response.json() as DbRow[] : [];
  const header = ["First Name", "Last Name", "Email", "Phone", "Location", "Stage", "Rating", "Source", "Applied", "Job"];
  const csvRows = rows.map((r) => [r.first_name, r.last_name, r.email, r.phone, r.location, r.current_stage, r.rating, r.source, r.created_at, (r.posting as DbRow | undefined)?.title]
    .map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(","));
  const csv = [header.join(","), ...csvRows].join("\n");
  return new Response(csv, { status: 200, headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": "attachment; filename=applications.csv" } });
}

// ---------------------------------------------------------------------------
// Admin: categories / departments / hiring stages / settings / moderation / audit
// ---------------------------------------------------------------------------
function lookupHandlers(table: string) {
  return {
    list: async (request: Request) => {
      const viewer = await requireViewer(request);
      if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
      const response = await dbFetch(`${table}?workspace_id=eq.${viewer.user.workspaceId}&select=*&order=sort_order.asc`);
      return json(request, { data: response.ok ? await response.json() : [] });
    },
    create: async (request: Request) => {
      const viewer = await requireViewer(request);
      if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
      const body = await readJson(request);
      const name = String(body.name ?? body.label ?? "").trim();
      if (!name) return json(request, { error: "Name is required" }, 400);
      const insert: DbRow = { workspace_id: viewer.user.workspaceId, name: body.name, slug: slugify(String(body.slug ?? name)), sort_order: body.sort_order ?? 0 };
      if (table === "jobs_hiring_stages") { insert.key = slugify(String(body.key ?? name)).replace(/-/g, "_"); insert.label = name; insert.is_terminal = Boolean(body.is_terminal); delete insert.name; delete insert.slug; }
      const response = await dbFetch(table, { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(insert) });
      if (!response.ok) return json(request, { error: "Could not create record" }, 400);
      return json(request, { data: first(await response.json()) }, 201);
    },
    update: async (request: Request, id: string) => {
      const viewer = await requireViewer(request);
      if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
      const body = await readJson(request);
      const response = await dbFetch(`${table}?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify(body) });
      if (!response.ok) return json(request, { error: "Could not update record" }, 400);
      return json(request, { data: first(await response.json()) });
    },
    remove: async (request: Request, id: string) => {
      const viewer = await requireViewer(request);
      if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
      await dbFetch(`${table}?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "DELETE" });
      return json(request, { data: { deleted: true } });
    },
  };
}

export const jobCategories = lookupHandlers("jobs_categories");
export const jobDepartments = lookupHandlers("jobs_departments");
export const hiringStages = lookupHandlers("jobs_hiring_stages");

export async function adminGetSettings(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`jobs_settings?workspace_id=eq.${viewer.user.workspaceId}&select=key,value`);
  const rows = response.ok ? await response.json() as DbRow[] : [];
  const settings: DbRow = {};
  for (const row of rows) settings[String(row.key)] = row.value;
  return json(request, { data: settings });
}

export async function adminUpdateSettings(request: Request, key: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const response = await dbFetch("jobs_settings?on_conflict=workspace_id,key", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=representation" },
    body: JSON.stringify({ workspace_id: viewer.user.workspaceId, key, value: body, updated_at: new Date().toISOString() }),
  });
  if (!response.ok) return json(request, { error: "Could not update settings" }, 400);
  return json(request, { data: first(await response.json()) });
}

export async function adminModerationQueue(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const response = await dbFetch(`jobs_postings?workspace_id=eq.${viewer.user.workspaceId}&status=eq.pending_approval&select=${JOB_SELECT}&order=created_at.asc`);
  return json(request, { data: response.ok ? await response.json() : [] });
}

export async function adminModerateJob(request: Request, id: string) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const body = await readJson(request);
  const action = String(body.action ?? "");
  const statusMap: Record<string, string> = { approved: "published", rejected: "rejected", changes_requested: "draft", paused: "paused", removed: "archived" };
  if (!(action in statusMap) && action !== "flagged") return json(request, { error: "Unsupported moderation action" }, 400);
  if (action !== "flagged") {
    await dbFetch(`jobs_postings?id=eq.${id}&workspace_id=eq.${viewer.user.workspaceId}`, { method: "PATCH", body: JSON.stringify({ status: statusMap[action], updated_by: viewer.user.id }) });
  }
  await dbFetch("jobs_moderation_log", { method: "POST", body: JSON.stringify({ posting_id: id, reviewer_id: viewer.user.id, action, reason: body.reason ?? null }) });
  return json(request, { data: { moderated: true } });
}

export async function adminAuditLog(request: Request) {
  const viewer = await requireViewer(request);
  if ("error" in viewer) return json(request, { error: viewer.error }, viewer.status);
  const url = new URL(request.url);
  const limit = Math.min(toInt(url.searchParams.get("limit"), 50), 200);
  const response = await dbFetch(`jobs_audit_log?workspace_id=eq.${viewer.user.workspaceId}&select=*&order=created_at.desc&limit=${limit}`);
  return json(request, { data: response.ok ? await response.json() : [] });
}
