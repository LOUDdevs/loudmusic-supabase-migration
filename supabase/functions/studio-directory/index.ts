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
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
  )

  try {
    const url = new URL(req.url)
    const path = url.pathname

    // Route mapping from original FastAPI app
    if (path === '/api/studios') {
      // GET /api/studios - List all studios with filters
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .limit(100)
      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path.match(/^\/api\/studio\/[^\/]+$/)) {
      // GET /api/studio/{slug} - Single studio
      const slug = path.split('/').pop()
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .eq('slug', slug)
        .single()
      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/search') {
      // GET /api/search?q=...
      const q = url.searchParams.get('q') || ''
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .ilike('name', `%${q}%`)
        .limit(50)
      if (error) throw error
      return new Response(JSON.stringify(data), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/nearby') {
      // GET /api/nearby?lat=&lng=&radius=
      // TODO: Implement geospatial query with PostGIS or computed distance
      const { data, error } = await supabase
        .from('studios')
        .select('*')
        .limit(50)
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
