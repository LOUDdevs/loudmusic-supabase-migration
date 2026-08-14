// Shared request/db/auth helpers used by index.ts and the resource modules
// (fletcher-templates.ts, funnel-builder-chat.ts, job-board.ts, ...). Pulled
// out of index.ts so new modules can reuse dbFetch/requireViewer without a
// circular import back into index.ts.

export const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
export const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
export const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
export const DEFAULT_WORKSPACE = "loudmusic";
export const ALLOWED_ORIGINS = new Set(["https://stg.loudmusic.io", "https://loudmusic.io", "http://localhost:5175", "http://localhost:5174"]);

export type Viewer = { id: string; email: string; name: string; role: string; workspaceId: string };
export type DbRow = Record<string, unknown>;

export function corsHeaders(request: Request) {
  const origin = request.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.has(origin) ? origin : "https://stg.loudmusic.io";
  return { "Access-Control-Allow-Origin": allowed, "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-idempotency-key", "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS", "Access-Control-Allow-Credentials": "true", "Vary": "Origin" };
}

export function json(request: Request, payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders(request) } });
}

export async function dbFetch(path: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", `Bearer ${SERVICE_KEY}`);
  headers.set("Accept-Profile", "marketing");
  headers.set("Content-Profile", "marketing");
  headers.set("Content-Type", "application/json");
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, { ...init, headers });
}

export async function readJson(request: Request): Promise<DbRow> {
  try { return await request.json(); } catch { return {}; }
}

export function first<T extends DbRow>(rows: unknown): T | null {
  return Array.isArray(rows) && rows.length ? rows[0] as T : null;
}

export async function workspaceFor(slug = DEFAULT_WORKSPACE) {
  const response = await dbFetch(`workspaces?slug=eq.${encodeURIComponent(slug)}&select=id,slug,name&limit=1`);
  return first<{ id: string; slug: string; name: string }>(response.ok ? await response.json() : []);
}

export async function requireViewer(request: Request): Promise<{ user: Viewer } | { error: string; status: number }> {
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

export async function countRows(table: string, workspaceId?: string) {
  const [resource, rawQuery] = table.split("?", 2);
  const params = new URLSearchParams(rawQuery ?? "");
  params.set("select", "id"); params.set("limit", "1");
  if (workspaceId) params.set("workspace_id", `eq.${workspaceId}`);
  const response = await dbFetch(`${resource}?${params.toString()}`, { headers: { Prefer: "count=exact" } });
  const range = response.headers.get("content-range") ?? "*/0";
  const total = Number(range.split("/")[1] ?? 0);
  return Number.isFinite(total) ? total : 0;
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "")
    .slice(0, 96) || crypto.randomUUID().slice(0, 8);
}

export { slugify };
