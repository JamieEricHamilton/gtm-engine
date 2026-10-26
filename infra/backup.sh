#!/usr/bin/env bash
# Nightly: dump Postgres + copy n8n data dir. Keeps 14 days locally.
set -euo pipefail
cd /opt/n8n
ts=$(date +%Y%m%d-%H%M)
mkdir -p /opt/backups
docker compose exec -T postgres pg_dump -U n8n -d n8n | gzip > /opt/backups/n8n-db-$ts.sql.gz
docker run --rm -v n8n_n8n_data:/src:ro -v /opt/backups:/dst alpine tar czf /dst/n8n-data-$ts.tgz -C /src .
find /opt/backups -type f -mtime +14 -delete
echo "backup ok $ts"
