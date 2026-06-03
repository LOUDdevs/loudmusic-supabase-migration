#!/bin/bash
set -e

# Load env
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_SERVICE_KEY" ]; then
  echo "Error: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in .env"
  exit 1
fi

# Link project
supabase link --project-ref "$(echo $SUPABASE_URL | sed 's|https://||;s/\.supabase\.co//')"

# Deploy all edge functions
for fn in studio-directory audio-analysis artist-enrichment; do
  echo "Deploying $fn..."
  supabase functions deploy "$fn"
done

echo "✅ All functions deployed"
