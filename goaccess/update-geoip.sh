#!/usr/bin/env bash
# Downloads DB-IP's free country + ASN databases into geo/ for GoAccess.
# Run on the server from /opt/easystock/goaccess, then `docker compose restart goaccess`.
#
# DB-IP Lite is CC BY 4.0 (https://db-ip.com). A new month's file appears on the 1st;
# re-running monthly keeps lookups current, but a stale file only misplaces a few IPs.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p geo
month=$(date -u +%Y-%m)
for kind in country asn; do
  url="https://download.db-ip.com/free/dbip-${kind}-lite-${month}.mmdb.gz"
  echo "→ ${url}"
  # To a file and checked before use: a cut-off download (seen 2026-10-27) would
  # otherwise replace a good database with a broken one and stop GoAccess starting.
  curl -sfL --retry 3 -o "geo/${kind}.mmdb.gz" "$url"
  gunzip -t "geo/${kind}.mmdb.gz"
  gunzip -c "geo/${kind}.mmdb.gz" > "geo/${kind}.mmdb.tmp"
  mv "geo/${kind}.mmdb.tmp" "geo/${kind}.mmdb"
  rm -f "geo/${kind}.mmdb.gz"
done
ls -l geo
