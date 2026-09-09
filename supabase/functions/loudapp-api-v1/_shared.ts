export const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get("LOUDAPP_ALLOWED_ORIGINS") ?? "http://localhost:4173,http://127.0.0.1:4173,https://app.loudmusic.io")
    .split(",")
    .map((value: string) => value.trim())
    .filter(Boolean),
);

export type DbRow = Record<string, unknown>;
export type Principal = {
  kind: "user" | "api_key";
  id: string;
  email?: string;
  workspaceId: string;
  role: "owner" | "admin" | "member";
  scopes: string[];
};

export function requestId(request: Request): string {
  const supplied = request.headers.get("X-Request-Id")?.trim();
  return supplied && /^[A-Za-z0-9._:-]{8,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}

export function corsHeaders(request: Request, id = requestId(request)): Record<string, string> {
  const origin = request.headers.get("Origin") ?? "";
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-idempotency-key, x-request-id",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
    "Access-Control-Expose-Headers": "X-Request-Id, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset",
    "Vary": "Origin",
    "X-Request-Id": id,
  };
  if (ALLOWED_ORIGINS.has(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Allow-Credentials"] = "true";
  }
  return headers;
}

export function json(request: Request, payload: unknown, status = 200, id = requestId(request), extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders(request, id), ...extra },
  });
}

export function success(request: Request, data: unknown, status = 200, id = requestId(request), extra: Record<string, string> = {}) {
  return json(request, { success: true, data, request_id: id }, status, id, extra);
}

export function failure(request: Request, code: string, message: string, status: number, id = requestId(request), details?: unknown) {
  return json(request, { success: false, error: { code, message, ...(details === undefined ? {} : { details }) }, request_id: id }, status, id);
}

export async function readJson(request: Request): Promise<DbRow> {
  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) return {};
  try {
    const value = await request.json();
    return value && typeof value === "object" && !Array.isArray(value) ? value as DbRow : {};
  } catch {
    return {};
  }
}

export async function dbFetch(path: string, init: RequestInit = {}) {
  if (!SUPABASE_URL || !SERVICE_KEY) throw new Error("Supabase server configuration is incomplete");
  const headers = new Headers(init.headers);
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", `Bearer ${SERVICE_KEY}`);
  headers.set("Accept-Profile", "loudapp");
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  if (["POST", "PATCH", "PUT", "DELETE"].includes((init.method ?? "GET").toUpperCase())) {
    headers.set("Content-Profile", "loudapp");
  }
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, { ...init, headers });
}

async function authUser(token: string): Promise<DbRow | null> {
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${token}` },
  });
  if (!response.ok) return null;
  const value = await response.json();
  return value && typeof value === "object" ? value as DbRow : null;
}

async function ensureWorkspace(user: DbRow): Promise<{ workspaceId: string; role: Principal["role"] } | null> {
  const userId = String(user.id ?? "");
  const memberships = await dbFetch(`workspace_members?user_id=eq.${encodeURIComponent(userId)}&select=workspace_id,role&order=created_at.asc&limit=1`);
  if (memberships.ok) {
    const rows = await memberships.json() as DbRow[];
    if (rows.length && rows[0].workspace_id) {
      return { workspaceId: String(rows[0].workspace_id), role: String(rows[0].role ?? "member") as Principal["role"] };
    }
  }

  const rawName = String((user.user_metadata as DbRow | undefined)?.full_name ?? user.email ?? "LOUDmusic workspace");
  const name = rawName.slice(0, 120) || "LOUDmusic workspace";
  const slug = `workspace-${userId.replaceAll("-", "").slice(0, 12)}`;
  const createWorkspace = await dbFetch("workspaces", {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ owner_id: userId, name, slug }),
  });
  if (!createWorkspace.ok && createWorkspace.status !== 409) return null;
  let workspaceId = "";
  if (createWorkspace.ok) {
    const created = await createWorkspace.json() as DbRow[];
    workspaceId = String(created[0]?.id ?? "");
  }
  if (!workspaceId) {
    const retry = await dbFetch(`workspaces?owner_id=eq.${encodeURIComponent(userId)}&select=id&limit=1`);
    if (!retry.ok) return null;
    const rows = await retry.json() as DbRow[];
    workspaceId = String(rows[0]?.id ?? "");
  }
  if (!workspaceId) return null;
  await dbFetch("workspace_members", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates" },
    body: JSON.stringify({ workspace_id: workspaceId, user_id: userId, role: "owner" }),
  });
  return { workspaceId, role: "owner" };
}

async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function createSignedUploadUrl(bucket: string, path: string): Promise<Response> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  return fetch(`${SUPABASE_URL}/storage/v1/object/upload/sign/${encodeURIComponent(bucket)}/${encodedPath}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
}

export async function requirePrincipal(request: Request): Promise<{ principal: Principal } | { code: string; message: string; status: number }> {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return { code: "AUTHENTICATION_REQUIRED", message: "A bearer token is required", status: 401 };
  const token = authorization.slice(7).trim();
  if (!token) return { code: "AUTHENTICATION_REQUIRED", message: "A bearer token is required", status: 401 };

  if (token.startsWith("lm_")) {
    const keyDigest = await digest(token);
    const response = await dbFetch(`api_keys?key_digest=eq.${encodeURIComponent(keyDigest)}&revoked_at=is.null&select=id,workspace_id,created_by,scopes,expires_at&limit=1`);
    if (!response.ok) return { code: "API_KEY_LOOKUP_FAILED", message: "API key validation failed", status: 503 };
    const rows = await response.json() as DbRow[];
    const key = rows[0];
    if (!key) return { code: "INVALID_API_KEY", message: "The API key is invalid or revoked", status: 401 };
    if (key.expires_at && Date.parse(String(key.expires_at)) <= Date.now()) return { code: "EXPIRED_API_KEY", message: "The API key has expired", status: 401 };
    const membership = await dbFetch(`workspace_members?workspace_id=eq.${encodeURIComponent(String(key.workspace_id))}&user_id=eq.${encodeURIComponent(String(key.created_by))}&select=role&limit=1`);
    const membershipRows = membership.ok ? await membership.json() as DbRow[] : [];
    if (!membershipRows.length) return { code: "INVALID_API_KEY", message: "The API key owner is no longer a workspace member", status: 401 };
    const role = String(membershipRows[0]?.role ?? "member") as Principal["role"];
    void dbFetch(`api_keys?id=eq.${encodeURIComponent(String(key.id))}`, { method: "PATCH", body: JSON.stringify({ last_used_at: new Date().toISOString() }) });
    return { principal: { kind: "api_key", id: String(key.id), workspaceId: String(key.workspace_id), role, scopes: Array.isArray(key.scopes) ? key.scopes.map(String) : [] } };
  }

  const user = await authUser(token);
  if (!user?.id) return { code: "INVALID_SESSION", message: "The session is invalid or expired", status: 401 };
  const workspace = await ensureWorkspace(user);
  if (!workspace) return { code: "WORKSPACE_UNAVAILABLE", message: "No workspace is available for this account", status: 503 };
  return {
    principal: {
      kind: "user",
      id: String(user.id),
      email: user.email ? String(user.email) : undefined,
      workspaceId: workspace.workspaceId,
      role: workspace.role,
      scopes: ["*"] ,
    },
  };
}

export function hasScope(principal: Principal, scope: string): boolean {
  return principal.kind === "user" || principal.scopes.includes("*") || principal.scopes.includes(scope);
}

const rateLimitStore = new Map<string, { count: number; resetAt: number }>();
export function checkRateLimit(identifier: string, limit: number, windowSeconds: number): { allowed: boolean; remaining: number; resetAt: number } {
  const now = Date.now();
  const existing = rateLimitStore.get(identifier);
  if (!existing || existing.resetAt <= now) {
    const resetAt = now + windowSeconds * 1000;
    rateLimitStore.set(identifier, { count: 1, resetAt });
    return { allowed: true, remaining: Math.max(0, limit - 1), resetAt };
  }
  existing.count += 1;
  return { allowed: existing.count <= limit, remaining: Math.max(0, limit - existing.count), resetAt: existing.resetAt };
}

export function rateHeaders(result: { remaining: number; resetAt: number }, limit: number): Record<string, string> {
  return { "X-RateLimit-Limit": String(limit), "X-RateLimit-Remaining": String(result.remaining), "X-RateLimit-Reset": String(Math.ceil(result.resetAt / 1000)) };
}

export function randomApiKey(environment: "test" | "live"): { plaintext: string; prefix: string } {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const encoded = btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const plaintext = `lm_${environment}_${encoded}`;
  return { plaintext, prefix: plaintext.slice(0, 16) };
}

export async function sha256(value: string): Promise<string> {
  return digest(value);
}

export async function loadIdempotency(workspaceId: string, key: string | null, route: string): Promise<{ status: number; body: unknown } | null> {
  if (!key) return null;
  const response = await dbFetch(`idempotency_keys?workspace_id=eq.${encodeURIComponent(workspaceId)}&idempotency_key=eq.${encodeURIComponent(key)}&route=eq.${encodeURIComponent(route)}&select=response_status,response_body&limit=1`);
  if (!response.ok) return null;
  const row = first(await response.json()) as DbRow | null;
  if (!row?.response_body) return null;
  return { status: Number(row.response_status ?? 200), body: row.response_body };
}

export async function saveIdempotency(workspaceId: string, key: string | null, route: string, status: number, body: unknown): Promise<void> {
  if (!key) return;
  await dbFetch("idempotency_keys", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
    body: JSON.stringify({ workspace_id: workspaceId, idempotency_key: key, route, response_status: status, response_body: body }),
  });
}

export function requireIdempotencyKey(request: Request): string | null {
  const key = request.headers.get("X-Idempotency-Key")?.trim() ?? null;
  return key && /^[A-Za-z0-9._:-]{8,200}$/.test(key) ? key : null;
}

export function first<T extends DbRow>(rows: unknown): T | null {
  return Array.isArray(rows) && rows.length ? rows[0] as T : null;
}
