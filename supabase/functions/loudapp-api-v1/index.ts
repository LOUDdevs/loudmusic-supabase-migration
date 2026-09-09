import {
  checkRateLimit,
  corsHeaders,
  createSignedUploadUrl,
  dbFetch,
  failure,
  first,
  hasScope,
  json,
  loadIdempotency,
  randomApiKey,
  rateHeaders,
  readJson,
  requestId,
  requireIdempotencyKey,
  requirePrincipal,
  saveIdempotency,
  sha256,
  success,
  type DbRow,
  type Principal,
} from "./_shared.ts";

const FUNCTION_NAME = "loudapp-api-v1";
const MAX_BODY_BYTES = 256 * 1024;
const DEFAULT_LIMIT = 25;
const MAX_LIMIT = 100;

function routePath(request: Request): string {
  const pathname = new URL(request.url).pathname.replace(/\/+$/, "") || "/";
  for (const prefix of [`/functions/v1/${FUNCTION_NAME}`, `/${FUNCTION_NAME}`]) {
    if (pathname === prefix) return "/";
    if (pathname.startsWith(`${prefix}/`)) return pathname.slice(prefix.length);
  }
  return pathname;
}

function clientIp(request: Request): string {
  return request.headers.get("CF-Connecting-IP") ?? request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ?? "unknown";
}

function limitFrom(request: Request): number {
  const raw = Number(new URL(request.url).searchParams.get("limit") ?? DEFAULT_LIMIT);
  return Number.isFinite(raw) ? Math.min(MAX_LIMIT, Math.max(1, Math.floor(raw))) : DEFAULT_LIMIT;
}

function scopeFailure(request: Request, id: string, principal: Principal, scope: string): Response | null {
  return hasScope(principal, scope) ? null : failure(request, "INSUFFICIENT_SCOPE", `This API key requires the ${scope} scope`, 403, id);
}

async function responseJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch { return null; }
}

async function dbError(request: Request, id: string, response: Response, code: string): Promise<Response> {
  console.error(JSON.stringify({ request_id: id, status: response.status, code }));
  return failure(request, code, "The API data operation failed", response.status >= 500 ? 503 : response.status, id);
}

async function insertAudit(principal: Principal, action: string, resource: string, metadata: DbRow = {}) {
  try {
    await dbFetch("audit_log", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ workspace_id: principal.workspaceId, actor_id: principal.kind === "user" ? principal.id : null, action, resource, metadata }),
    });
  } catch { /* Audit failure must not expose or break the user operation. */ }
}

async function currentWorkspace(request: Request, id: string, principal: Principal): Promise<Response> {
  const result = await dbFetch(`workspaces?id=eq.${encodeURIComponent(principal.workspaceId)}&select=id,name,slug,owner_id,created_at,updated_at&limit=1`);
  if (!result.ok) return dbError(request, id, result, "WORKSPACE_READ_FAILED");
  return success(request, first(await responseJson(result)), 200, id);
}

async function profile(request: Request, id: string, principal: Principal): Promise<Response> {
  if (principal.kind !== "user") return failure(request, "USER_SESSION_REQUIRED", "Profile access requires a user session", 403, id);
  if (request.method === "GET") {
    const result = await dbFetch(`profiles?user_id=eq.${encodeURIComponent(principal.id)}&select=user_id,display_name,avatar_url,created_at,updated_at&limit=1`);
    if (!result.ok) return dbError(request, id, result, "PROFILE_READ_FAILED");
    return success(request, first(await responseJson(result)), 200, id);
  }
  if (request.method !== "PATCH" && request.method !== "PUT") return failure(request, "METHOD_NOT_ALLOWED", "Use GET or PATCH for profile", 405, id);
  if (principal.kind !== "user") return failure(request, "USER_SESSION_REQUIRED", "Profile updates require a user session", 403, id);
  const body = await readJson(request);
  const payload: DbRow = {};
  if (typeof body.display_name === "string") payload.display_name = body.display_name.trim().slice(0, 160);
  if (typeof body.avatar_url === "string" || body.avatar_url === null) payload.avatar_url = body.avatar_url;
  payload.user_id = principal.id;
  const result = await dbFetch("profiles", { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=representation" }, body: JSON.stringify(payload) });
  if (!result.ok) return dbError(request, id, result, "PROFILE_WRITE_FAILED");
  await insertAudit(principal, "profile.updated", `profile:${principal.id}`);
  return success(request, first(await responseJson(result)), 200, id);
}

async function settings(request: Request, id: string, principal: Principal, section: string): Promise<Response> {
  if (!/^[a-z][a-z0-9-]{0,63}$/.test(section)) return failure(request, "INVALID_SECTION", "The settings section is invalid", 400, id);
  if (request.method === "GET") {
    const result = await dbFetch(`settings?workspace_id=eq.${encodeURIComponent(principal.workspaceId)}&section=eq.${encodeURIComponent(section)}&select=section,value,created_at,updated_at&limit=1`);
    if (!result.ok) return dbError(request, id, result, "SETTINGS_READ_FAILED");
    return success(request, first(await responseJson(result)), 200, id);
  }
  const denied = scopeFailure(request, id, principal, "settings:write");
  if (denied) return denied;
  if (request.method !== "PATCH" && request.method !== "PUT") return failure(request, "METHOD_NOT_ALLOWED", "Use GET or PATCH for settings", 405, id);
  const body = await readJson(request);
  const value = Object.hasOwn(body, "value") ? body.value : body;
  const result = await dbFetch("settings", { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=representation" }, body: JSON.stringify({ workspace_id: principal.workspaceId, section, value }) });
  if (!result.ok) return dbError(request, id, result, "SETTINGS_WRITE_FAILED");
  await insertAudit(principal, "settings.updated", `settings:${section}`);
  return success(request, first(await responseJson(result)), 200, id);
}

async function playlistSubmissions(request: Request, id: string, principal: Principal): Promise<Response> {
  const denied = scopeFailure(request, id, principal, request.method === "GET" ? "playlist:read" : "playlist:submit");
  if (denied) return denied;
  if (request.method === "GET") {
    const url = new URL(request.url);
    const limit = limitFrom(request);
    const offset = Math.max(0, Number(url.searchParams.get("offset") ?? 0) || 0);
    const result = await dbFetch(`playlist_submissions?workspace_id=eq.${encodeURIComponent(principal.workspaceId)}&select=id,submitted_by,track_url,track_title,playlist_ids,status,created_at,updated_at&order=created_at.desc&limit=${limit}&offset=${offset}`);
    if (!result.ok) return dbError(request, id, result, "PLAYLIST_READ_FAILED");
    return success(request, await responseJson(result), 200, id, { "X-Page-Limit": String(limit), "X-Page-Offset": String(offset) });
  }
  if (request.method !== "POST") return failure(request, "METHOD_NOT_ALLOWED", "Use GET or POST for playlist submissions", 405, id);
  if (principal.kind !== "user") return failure(request, "USER_SESSION_REQUIRED", "Playlist submission requires a user session", 403, id);
  const idempotencyKey = requireIdempotencyKey(request);
  if (request.headers.has("X-Idempotency-Key") && !idempotencyKey) return failure(request, "INVALID_IDEMPOTENCY_KEY", "X-Idempotency-Key must be 8-200 safe characters", 400, id);
  const replay = await loadIdempotency(principal.workspaceId, idempotencyKey, "POST /v1/playlist/submissions");
  if (replay) return json(request, replay.body, replay.status, id);
  const body = await readJson(request);
  const trackUrl = typeof body.track_url === "string" ? body.track_url.trim() : typeof body.trackUrl === "string" ? body.trackUrl.trim() : "";
  let parsedUrl: URL;
  try { parsedUrl = new URL(trackUrl); } catch { return failure(request, "INVALID_TRACK_URL", "track_url must be a valid URL", 400, id); }
  if (!["http:", "https:"].includes(parsedUrl.protocol)) return failure(request, "INVALID_TRACK_URL", "track_url must use HTTPS or HTTP", 400, id);
  const ids = body.playlist_ids ?? body.playlistIds ?? [];
  if (!Array.isArray(ids) || ids.length > 100 || ids.some((item) => typeof item !== "string" || item.length > 200)) return failure(request, "INVALID_PLAYLIST_IDS", "playlist_ids must be an array of at most 100 strings", 400, id);
  const payload = { workspace_id: principal.workspaceId, submitted_by: principal.id, track_url: trackUrl.slice(0, 2048), track_title: typeof body.track_title === "string" ? body.track_title.slice(0, 500) : typeof body.trackTitle === "string" ? body.trackTitle.slice(0, 500) : "", playlist_ids: ids, status: "pending" };
  const result = await dbFetch("playlist_submissions", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify(payload) });
  if (!result.ok) return dbError(request, id, result, "PLAYLIST_CREATE_FAILED");
  const created = first(await responseJson(result));
  await insertAudit(principal, "playlist.submission_created", `playlist_submission:${String(created?.id ?? "unknown")}`);
  const envelope = { success: true, data: created, request_id: id };
  await saveIdempotency(principal.workspaceId, idempotencyKey, "POST /v1/playlist/submissions", 201, envelope);
  return json(request, envelope, 201, id);
}

async function apiKeys(request: Request, id: string, principal: Principal, keyId?: string): Promise<Response> {
  const denied = scopeFailure(request, id, principal, "api_keys:manage");
  if (denied) return denied;
  if (principal.role !== "owner" && principal.role !== "admin") return failure(request, "ADMIN_REQUIRED", "Only workspace owners and admins can manage API keys", 403, id);
  if (request.method === "GET") {
    const result = await dbFetch(`api_keys?workspace_id=eq.${encodeURIComponent(principal.workspaceId)}&select=id,name,environment,key_prefix,scopes,expires_at,last_used_at,revoked_at,created_at&order=created_at.desc&limit=${limitFrom(request)}`);
    if (!result.ok) return dbError(request, id, result, "API_KEY_READ_FAILED");
    return success(request, await responseJson(result), 200, id);
  }
  if (request.method === "POST" && !keyId) {
    if (principal.kind !== "user") return failure(request, "USER_SESSION_REQUIRED", "API key creation requires a user session", 403, id);
    const idempotencyKey = requireIdempotencyKey(request);
    if (request.headers.has("X-Idempotency-Key") && !idempotencyKey) return failure(request, "INVALID_IDEMPOTENCY_KEY", "X-Idempotency-Key must be 8-200 safe characters", 400, id);
    const replay = await loadIdempotency(principal.workspaceId, idempotencyKey, "POST /v1/api-keys");
    if (replay) return json(request, replay.body, replay.status, id);
    const body = await readJson(request);
    const environment = body.environment === "test" ? "test" : "live";
    const name = typeof body.name === "string" ? body.name.trim().slice(0, 120) : "Unnamed key";
    const scopes = Array.isArray(body.scopes) ? body.scopes.filter((scope) => typeof scope === "string").map(String).slice(0, 50) : [];
    const expiresAt = typeof body.expires_at === "string" ? body.expires_at : typeof body.expiresAt === "string" ? body.expiresAt : null;
    if (expiresAt && !Number.isFinite(Date.parse(expiresAt))) return failure(request, "INVALID_EXPIRY", "expires_at must be an ISO date", 400, id);
    const generated = randomApiKey(environment);
    const result = await dbFetch("api_keys", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: principal.workspaceId, created_by: principal.id, name, environment, key_prefix: generated.prefix, key_digest: await sha256(generated.plaintext), scopes, expires_at: expiresAt }) });
    if (!result.ok) return dbError(request, id, result, "API_KEY_CREATE_FAILED");
    const created = first(await responseJson(result));
    await insertAudit(principal, "api_key.created", `api_key:${String(created?.id ?? "unknown")}`, { environment, scopes });
    const envelope = { success: true, data: { ...created, key: generated.plaintext, warning: "Store this key now. It will not be shown again." }, request_id: id };
    await saveIdempotency(principal.workspaceId, idempotencyKey, "POST /v1/api-keys", 201, envelope);
    return json(request, envelope, 201, id);
  }
  if ((request.method === "DELETE" || request.method === "PATCH") && keyId) {
    const result = await dbFetch(`api_keys?id=eq.${encodeURIComponent(keyId)}&workspace_id=eq.${encodeURIComponent(principal.workspaceId)}&revoked_at=is.null`, { method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ revoked_at: new Date().toISOString() }) });
    if (!result.ok) return dbError(request, id, result, "API_KEY_REVOKE_FAILED");
    await insertAudit(principal, "api_key.revoked", `api_key:${keyId}`);
    return success(request, first(await responseJson(result)), 200, id);
  }
  return failure(request, "METHOD_NOT_ALLOWED", "Use GET, POST, or DELETE for API keys", 405, id);
}

async function storageFiles(request: Request, id: string, principal: Principal): Promise<Response> {
  const denied = scopeFailure(request, id, principal, request.method === "GET" ? "storage:read" : "storage:write");
  if (denied) return denied;
  if (request.method === "GET") {
    const result = await dbFetch(`storage_files?workspace_id=eq.${encodeURIComponent(principal.workspaceId)}&select=id,bucket,storage_path,original_name,mime_type,byte_size,scope,created_at,updated_at&order=created_at.desc&limit=${limitFrom(request)}`);
    if (!result.ok) return dbError(request, id, result, "STORAGE_READ_FAILED");
    return success(request, await responseJson(result), 200, id);
  }
  if (request.method !== "POST") return failure(request, "METHOD_NOT_ALLOWED", "Use GET or POST for storage files", 405, id);
  if (principal.kind !== "user") return failure(request, "USER_SESSION_REQUIRED", "Storage uploads require a user session", 403, id);
  const body = await readJson(request);
  const bucket = typeof body.bucket === "string" ? body.bucket.trim() : "loudapp-private";
  const originalName = typeof body.original_name === "string" ? body.original_name.trim().slice(0, 512) : "upload";
  const safeName = originalName.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 160) || "upload";
  const path = `${principal.workspaceId}/${crypto.randomUUID()}-${safeName}`;
  const signed = await createSignedUploadUrl(bucket, path);
  if (!signed.ok) return dbError(request, id, signed, "STORAGE_SIGN_FAILED");
  const signedData = await responseJson(signed) as DbRow;
  const result = await dbFetch("storage_files", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ workspace_id: principal.workspaceId, uploaded_by: principal.id, bucket, storage_path: path, original_name: originalName, mime_type: typeof body.mime_type === "string" ? body.mime_type.slice(0, 255) : null, byte_size: typeof body.byte_size === "number" ? body.byte_size : null, scope: "private" }) });
  if (!result.ok) return dbError(request, id, result, "STORAGE_METADATA_FAILED");
  const metadata = await responseJson(result);
  const file = first(metadata);
  await insertAudit(principal, "storage.upload_url_created", `storage_file:${String(file?.id ?? "unknown")}`);
  return success(request, { file, upload: signedData }, 201, id);
}

async function handle(request: Request): Promise<Response> {
  const id = requestId(request);
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request, id) });
  const contentLength = Number(request.headers.get("Content-Length") ?? 0);
  if (contentLength > MAX_BODY_BYTES) return failure(request, "PAYLOAD_TOO_LARGE", "Request body exceeds the API limit", 413, id);
  const rate = checkRateLimit(`ip:${clientIp(request)}`, 120, 60);
  if (!rate.allowed) return failure(request, "RATE_LIMITED", "Too many requests", 429, id, undefined);
  const path = routePath(request);
  if (path === "/health" || path === "/v1/health") return success(request, { status: "ok", version: "v1" }, 200, id, rateHeaders(rate, 120));
  const auth = await requirePrincipal(request);
  if (!("principal" in auth)) return failure(request, auth.code, auth.message, auth.status, id);
  const principal = auth.principal;
  const userRate = checkRateLimit(`${principal.kind}:${principal.id}`, 300, 60);
  if (!userRate.allowed) return failure(request, "RATE_LIMITED", "Too many requests", 429, id);
  const segments = path.split("/").filter(Boolean);
  if (segments[0] !== "v1") return failure(request, "NOT_FOUND", "API route not found", 404, id);
  const resource = segments[1] ?? "";
  const subresource = segments[2];
  if (resource === "workspace" && request.method === "GET") return currentWorkspace(request, id, principal);
  if (resource === "profile") return profile(request, id, principal);
  if (resource === "settings" && subresource) return settings(request, id, principal, subresource);
  if (resource === "playlist" && subresource === "submissions") return playlistSubmissions(request, id, principal);
  if (resource === "api-keys") return apiKeys(request, id, principal, subresource);
  if (resource === "storage" && subresource === "files") return storageFiles(request, id, principal);
  return failure(request, "NOT_FOUND", "API route not found", 404, id);
}

Deno.serve(async (request) => {
  try {
    return await handle(request);
  } catch (error) {
    const id = requestId(request);
    console.error(JSON.stringify({ request_id: id, error: error instanceof Error ? error.message : String(error) }));
    return failure(request, "INTERNAL_ERROR", "An unexpected API error occurred", 500, id);
  }
});
