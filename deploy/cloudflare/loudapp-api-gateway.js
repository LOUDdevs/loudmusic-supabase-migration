const MAX_BODY_BYTES = 256 * 1024;

function requestId(request) {
  const supplied = request.headers.get("X-Request-Id");
  return supplied && /^[A-Za-z0-9._:-]{8,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}

function allowedOrigin(request, env) {
  const origin = request.headers.get("Origin") || "";
  const allowed = (env.ALLOWED_ORIGINS || "").split(",").map((value) => value.trim()).filter(Boolean);
  return allowed.includes(origin) ? origin : "";
}

function cors(request, env, id) {
  const headers = {
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-idempotency-key, x-request-id",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
    "Access-Control-Expose-Headers": "X-Request-Id, X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset",
    "Vary": "Origin",
    "X-Request-Id": id,
  };
  const origin = allowedOrigin(request, env);
  if (origin) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Allow-Credentials"] = "true";
  }
  return headers;
}

function json(request, env, payload, status, id, extra = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...cors(request, env, id), ...extra },
  });
}

export default {
  async fetch(request, env) {
    const id = requestId(request);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(request, env, id) });
    const length = Number(request.headers.get("Content-Length") || 0);
    if (length > MAX_BODY_BYTES) return json(request, env, { success: false, error: { code: "PAYLOAD_TOO_LARGE", message: "Request body exceeds the API limit" }, request_id: id }, 413, id);
    if (!env.UPSTREAM_API_BASE_URL) return json(request, env, { success: false, error: { code: "GATEWAY_NOT_CONFIGURED", message: "The API gateway has no upstream configured" }, request_id: id }, 503, id);

    const client = request.headers.get("CF-Connecting-IP") || "unknown";
    if (env.API_RATE_LIMITER) {
      const decision = await env.API_RATE_LIMITER.limit({ key: client });
      if (!decision.success) return json(request, env, { success: false, error: { code: "RATE_LIMITED", message: "Too many requests" }, request_id: id }, 429, id, { "Retry-After": "60" });
    }

    const upstream = new URL(env.UPSTREAM_API_BASE_URL);
    const incoming = new URL(request.url);
    upstream.pathname = `${upstream.pathname.replace(/\/$/, "")}${incoming.pathname}`;
    upstream.search = incoming.search;
    const headers = new Headers(request.headers);
    headers.set("X-Request-Id", id);
    headers.delete("Host");
    const response = await fetch(upstream, { method: request.method, headers, body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body, redirect: "manual" });
    const output = new Response(response.body, response);
    const gatewayHeaders = cors(request, env, id);
    for (const [key, value] of Object.entries(gatewayHeaders)) output.headers.set(key, value);
    output.headers.set("X-Request-Id", id);
    return output;
  },
};
