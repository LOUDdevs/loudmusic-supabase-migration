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

    if (path === '/health') {
      return new Response(JSON.stringify({ status: 'ok', version: '0.2.0' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    if (path === '/api/analyze' && req.method === 'POST') {
      // Audio analysis upload — triggers async processing
      // For heavy processing (ffmpeg/librosa), this should queue a job
      // to an external worker instead of processing in Edge Function
      const body = await req.json()
      const { track_url, audio_id } = body

      // Store analysis request, return job ID
      const { data, error } = await supabase
        .from('analysis_jobs')
        .insert({ track_url, audio_id, status: 'pending' })
        .select()
        .single()

      if (error) throw error

      // TODO: Trigger webhook to external audio processing worker
      // (musicnn-service + essentia-service on 37172 for now)

      return new Response(JSON.stringify({
        job_id: data.id,
        status: 'pending',
        message: 'Analysis queued'
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/analyze/spotify' && req.method === 'POST') {
      // Spotify track analysis
      const body = await req.json()
      const { spotify_url } = body

      // TODO: Call Spotify API + Chartmetric enrichment
      // This requires SPOTIFY_CLIENT_ID + SPOTIFY_CLIENT_SECRET env vars

      return new Response(JSON.stringify({
        spotify_url,
        status: 'not_implemented',
        message: 'Spotify analysis to be wired in'
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
    }

    if (path === '/api/results' && req.method === 'GET') {
      // Get analysis results by job_id
      const jobId = url.searchParams.get('job_id')
      const { data, error } = await supabase
        .from('analysis_jobs')
        .select('*')
        .eq('id', jobId)
        .single()

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
