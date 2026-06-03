import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_KEY')!, // Uses service role for admin ops
  )

  try {
    const url = new URL(req.url)
    const path = url.pathname

    if (path === '/api/artists' && req.method === 'GET') {
      // GET /api/artists - List enriched artists
      const { data, error } = await supabase
        .from('artist')
        .select('*')
        .order('enhanced_at', { ascending: false })
        .limit(100)

      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/artists/search' && req.method === 'GET') {
      // Search artists by name
      const q = url.searchParams.get('q') || ''
      const { data, error } = await supabase
        .from('artist')
        .select('*')
        .ilike('name', `%${q}%`)
        .limit(50)

      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/artists/enrich' && req.method === 'POST') {
      // Trigger enrichment for an artist
      const body = await req.json()
      const { spotify_id, chartmetric_id } = body

      // TODO: Call Chartmetric + Soundcharts + Spotify APIs
      // Then upsert to Supabase

      return new Response(JSON.stringify({
        status: 'queued',
        spotify_id,
        chartmetric_id,
        message: 'Enrichment queued — to be wired to Chartmetric API'
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/artists' && req.method === 'POST') {
      // Direct upsert from enrichment pipeline
      const body = await req.json()

      const { data, error } = await supabase
        .from('artist')
        .upsert(body, { onConflict: 'spotify_id' })
        .select()

      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    return new Response(JSON.stringify({ detail: 'Not Found' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  } catch (err) {
    return new Response(JSON.stringify({ detail: err.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    })
  }
})
