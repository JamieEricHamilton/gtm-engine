#!/usr/bin/env bash
# Export every workflow from a self-hosted n8n via the public API, then run tools/scrub.py before committing.
# Usage: N8N_URL=https://n8n.example.com N8N_API_KEY=... ./tools/export_workflows.sh out_dir
set -euo pipefail
out="${1:-raw}"; mkdir -p "$out"
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/api/v1/workflows?limit=200" > "$out/wf-list.json"
jq -r '.data[].id' "$out/wf-list.json" | while read -r id; do
  curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/api/v1/workflows/$id" > "$out/$id.json"
done
echo "exported $(ls "$out" | wc -l) files to $out"
