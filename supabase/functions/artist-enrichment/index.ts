import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function bearer(req: Request): string {
  const header = req.headers.get('Authorization') ?? ''
  return header.replace(/^Bearer\s+/i, '')
}

function createPublicClient(req: Request): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } }
  )
}

function createServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_KEY')!,
  )
}

function jwtRole(token: string): string | null {
  const parts = token.split('.')
  if (parts.length < 2) return null
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')))
    return payload.role ?? null
  } catch (_) {
    return null
  }
}

function isServiceRequest(req: Request): boolean {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SERVICE_KEY')
  const token = bearer(req)
  const apikey = req.headers.get('apikey') ?? ''
  return Boolean(
    (serviceKey && (token === serviceKey || apikey === serviceKey)) ||
    jwtRole(token) === 'service_role' ||
    jwtRole(apikey) === 'service_role'
  )
}

async function isAuthenticatedRequest(req: Request, publicClient: SupabaseClient): Promise<boolean> {
  if (isServiceRequest(req)) return true
  const token = bearer(req)
  if (!token || token === Deno.env.get('SUPABASE_ANON_KEY')) return false
  const { data, error } = await publicClient.auth.getUser(token)
  return !error && Boolean(data.user)
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const publicClient = createPublicClient(req)
  const serviceClient = createServiceClient()

  try {
    const url = new URL(req.url)
    const path = url.pathname.replace(/^\/artist-enrichment/, '') || '/'

    if (path === '/api/artists' && req.method === 'GET') {
      const { data, error } = await publicClient
        .from('artist')
        .select('*')
        .order('enhanced_at', { ascending: false })
        .limit(100)

      if (error) throw error
      return jsonResponse(data)
    }

    if (path === '/api/artists/search' && req.method === 'GET') {
      const q = url.searchParams.get('q') || ''
      const { data, error } = await publicClient
        .from('artist')
        .select('*')
        .ilike('name', `%${q}%`)
        .limit(50)

      if (error) throw error
      return jsonResponse(data)
    }

    if (path === '/api/artists/enrich' && req.method === 'POST') {
      if (!(await isAuthenticatedRequest(req, publicClient))) {
        return jsonResponse({ detail: 'Authentication required' }, 401)
      }

      const body = await req.json()
      const { spotify_id, chartmetric_id } = body

      return jsonResponse({
        status: 'queued',
        spotify_id,
        chartmetric_id,
        message: 'Enrichment queued — to be wired to Chartmetric API',
      })
    }

    if (path === '/api/artists' && req.method === 'POST') {
      if (!isServiceRequest(req)) {
        return jsonResponse({ detail: 'Service role authorization required' }, 403)
      }

      const body = await req.json()

      const { data, error } = await serviceClient
        .from('artist')
        .upsert(body, { onConflict: 'spotify_id' })
        .select()

      if (error) throw error
      return jsonResponse(data)
    }

    return jsonResponse({ detail: 'Not Found' }, 404)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return jsonResponse({ detail: message }, 500)
  }
})
