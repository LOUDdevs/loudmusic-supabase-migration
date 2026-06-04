import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

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

function parseNumber(value: string | null, fallback?: number): number | null {
  if (value === null || value === '') return fallback ?? null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

function distanceMiles(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const toRad = (degrees: number) => degrees * Math.PI / 180
  const earthRadiusMiles = 3958.7613
  const dLat = toRad(lat2 - lat1)
  const dLng = toRad(lng2 - lng1)
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2
  return 2 * earthRadiusMiles * Math.asin(Math.sqrt(a))
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } }
  )

  try {
    const url = new URL(req.url)
    const path = url.pathname.replace(/^\/studio-directory/, '') || '/'

    if (path === '/api/studios') {
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .limit(100)
      if (error) throw error
      return jsonResponse(data)
    }

    if (path.match(/^\/api\/studio\/[^\/]+$/)) {
      const slug = path.split('/').pop()
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .eq('slug', slug)
        .single()
      if (error) throw error
      return jsonResponse(data)
    }

    if (path === '/api/search') {
      const q = url.searchParams.get('q') || ''
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .ilike('name', `%${q}%`)
        .limit(50)
      if (error) throw error
      return jsonResponse(data)
    }

    if (path === '/api/nearby') {
      const lat = parseNumber(url.searchParams.get('lat'))
      const lng = parseNumber(url.searchParams.get('lng'))
      const radius = parseNumber(url.searchParams.get('radius'), 25)
      const limit = Math.min(Math.max(parseNumber(url.searchParams.get('limit'), 50) ?? 50, 1), 100)

      if (lat === null || lng === null || radius === null || radius <= 0) {
        return jsonResponse({ detail: 'lat, lng, and positive radius are required' }, 400)
      }

      const latDelta = radius / 69
      const lngDelta = radius / (Math.max(Math.cos(lat * Math.PI / 180), 0.01) * 69)

      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .not('lat', 'is', null)
        .not('lng', 'is', null)
        .gte('lat', lat - latDelta)
        .lte('lat', lat + latDelta)
        .gte('lng', lng - lngDelta)
        .lte('lng', lng + lngDelta)
        .limit(500)

      if (error) throw error

      const nearby = (data ?? [])
        .map((studio) => ({
          ...studio,
          distance_miles: Number(distanceMiles(lat, lng, Number(studio.lat), Number(studio.lng)).toFixed(2)),
        }))
        .filter((studio) => studio.distance_miles <= radius)
        .sort((a, b) => a.distance_miles - b.distance_miles)
        .slice(0, limit)

      return jsonResponse(nearby)
    }

    return jsonResponse({ detail: 'Not Found' }, 404)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return jsonResponse({ detail: message }, 500)
  }
})
