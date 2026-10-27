#!/usr/bin/env bash
# One-time: loads Caddy's rotated production logs (*.log.gz) into GoAccess's
# database, oldest first, so the dashboard starts with history instead of empty.
# Run on the server from /opt/easystock/goaccess, BEFORE the first `docker compose up`.
#
# Run it once only. The live container reads access.log itself, and a second import
# would count every rotated request twice — to redo it, `docker compose down`,
# empty data/db, and import again.
set -euo pipefail
cd "$(dirname "$0")"

if [ -n "$(docker ps -q -f name=^goaccess$)" ]; then
  echo "goaccess is running — stop it first (docker compose down)." >&2
  exit 1
fi
mkdir -p data/db data/html

# Production only: staging writes access-staging*.log.
files=$(ls ../infra/logs/access-20*.log.gz 2>/dev/null | sort || true)
if [ -z "$files" ]; then
  echo "No rotated logs to import."
  exit 0
fi
echo "Importing:"; echo "$files"

# shellcheck disable=SC2086
zcat $files | docker run --rm -i \
  -v "$PWD/geo:/geo:ro" -v "$PWD/data:/data" \
  allinurl/goaccess:1.12 - \
  --log-format=CADDY --persist --db-path=/data/db --keep-last=30 --tz=Asia/Dhaka \
  --geoip-database=/geo/country.mmdb --geoip-database=/geo/asn.mmdb \
  --exclude-ip=172.16.0.0-172.31.255.255 --no-progress \
  -o /data/html/index.html
echo "Done. Now: docker compose up -d"
