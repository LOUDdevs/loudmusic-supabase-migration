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

function createAnonClient(req: Request): SupabaseClient {
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

async function requireUser(req: Request, supabase: SupabaseClient) {
  if (isServiceRequest(req)) return null
  const token = bearer(req)
  if (!token || token === Deno.env.get('SUPABASE_ANON_KEY')) {
    return { error: jsonResponse({ detail: 'Authentication required' }, 401) }
  }
  const { data, error } = await supabase.auth.getUser(token)
  if (error || !data.user) {
    return { error: jsonResponse({ detail: 'Invalid authentication token' }, 401) }
  }
  return { user: data.user }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const userClient = createAnonClient(req)
  const serviceClient = createServiceClient()
  const db = isServiceRequest(req) ? serviceClient : userClient

  try {
    const url = new URL(req.url)
    const path = url.pathname.replace(/^\/audio-analysis/, '') || '/'

    if (path === '/health') {
      return jsonResponse({ status: 'ok', version: '0.2.0' })
    }

    if (path === '/api/analyze' && req.method === 'POST') {
      const auth = await requireUser(req, userClient)
      if (auth?.error) return auth.error

      const body = await req.json()
      const { track_url, audio_id } = body
      if (!track_url && !audio_id) {
        return jsonResponse({ detail: 'track_url or audio_id is required' }, 400)
      }

      const insertBody = {
        track_url,
        audio_id,
        user_id: auth?.user?.id ?? body.user_id ?? null,
        status: 'pending',
      }

      const { data, error } = await db
        .from('analysis_jobs')
        .insert(insertBody)
        .select()
        .single()

      if (error) throw error

      return jsonResponse({
        job_id: data.id,
        status: data.status,
        message: 'Analysis queued',
      })
    }

    if (path === '/api/analyze/spotify' && req.method === 'POST') {
      const body = await req.json()
      const { spotify_url } = body

      return jsonResponse({
        spotify_url,
        status: 'not_implemented',
        message: 'Spotify analysis to be wired in',
      })
    }

    if (path === '/api/results' && req.method === 'GET') {
      const jobId = url.searchParams.get('job_id')
      if (!jobId) return jsonResponse({ detail: 'job_id is required' }, 400)

      const { data, error } = await db
        .from('analysis_jobs')
        .select('*')
        .eq('id', jobId)
        .maybeSingle()

      if (error) throw error
      if (!data) return jsonResponse({ detail: 'Analysis job not found' }, 404)
      return jsonResponse(data)
    }

    return jsonResponse({ detail: 'Not Found' }, 404)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return jsonResponse({ detail: message }, 500)
  }
})
