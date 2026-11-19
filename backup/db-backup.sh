#!/usr/bin/env bash
#
# db-backup.sh: nightly backup of the PRODUCTION databases to Cloudflare R2.
#
# Why this exists: production runs on MongoDB Atlas M0 (free tier), which has NO backups.
# Until 2026-11-19 the only copy of the data was one manual dump from 2026-09-21. This is now
# the only backup there is, so it proves every run instead of trusting it:
#
#   1. dump `easystock` (the product) and `mc` (Mission Control, billing) with mongodump
#   2. RESTORE both into a throwaway local mongod and compare document counts with the live
#      database, so an archive that cannot be restored fails tonight and not on the day it is
#      needed
#   3. upload to R2: daily/ kept 30 days, plus a monthly/ copy on the 1st, kept ~13 months
#   4. keep the last 7 days on this server too, for a fast restore
#   5. Telegram: one line on success, an alert on any failure (a silent cron is how the old
#      backups stopped without anyone noticing)
#
# Runs as root from /etc/cron.d/ezycore-db-backup (backup/ezycore-db-backup.cron), 03:00 Dhaka.
# By hand: sudo /opt/easystock/backup/db-backup.sh
#
# Reads, never prints:
#   /opt/easystock/backups/r2.env                R2_BACKUP_{ACCOUNT_ID,BUCKET,ACCESS_KEY_ID,SECRET_ACCESS_KEY}
#                                                (token scoped to that one bucket, root-only 600)
#   /opt/easystock/production/.env.backend       MONGODB_URI (→ easystock) + TELEGRAM_*
#   /opt/easystock/production/.env.mc-api        MONGODB_URI (→ mc)
# Secrets reach the containers by NAME (`-e VAR`), never as a value on a command line, so
# they do not show up in `ps`.
#
# RESTORE (see backup/README.md for the full runbook):
#   sudo docker run --rm -v /opt/easystock/backups/auto/<run>:/b:ro -e MONGO_URI mongo:8.0 \
#     sh -c 'mongorestore --uri "$MONGO_URI" --archive=/b/easystock.archive.gz --gzip --drop'
#
set -Eeuo pipefail

ROOT=/opt/easystock
OUT="$ROOT/backups"
LOCAL_DIR="$OUT/auto"
LOG="$OUT/backup.log"
KEEP_LOCAL_DAYS=7
KEEP_DAILY_DAYS=30
KEEP_MONTHLY_DAYS=400
# Tools match the server's major version (Atlas runs 8.0). aws-cli is pinned below 2.23 on
# purpose: newer versions send checksum headers R2 has rejected.
MONGO_IMAGE=mongo:8.0
AWS_IMAGE=amazon/aws-cli:2.17.0
RESTORE_CTR=ezy-backup-restore-test
# Live writes keep landing while the dump runs, so the restored count may trail the count
# taken just before it. More than this gap means documents went missing.
COUNT_TOLERANCE_PCT=2

DBS=(easystock mc)
declare -A ENV_FILE=([easystock]="$ROOT/production/.env.backend" [mc]="$ROOT/production/.env.mc-api")

STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
RUN_DIR="$LOCAL_DIR/$STAMP"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# Value of KEY in an env file, quotes stripped. Never echoed.
env_get() {
  local v
  v="$(grep -E "^$1=" "$2" | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

telegram() {
  local token chat
  token="$(env_get TELEGRAM_BOT_TOKEN "${ENV_FILE[easystock]}" 2>/dev/null || true)"
  chat="$(env_get TELEGRAM_CHAT_ID "${ENV_FILE[easystock]}" 2>/dev/null || true)"
  [ -n "$token" ] && [ -n "$chat" ] || { log "telegram not configured: $1"; return 0; }
  # Token in the URL path is how the Bot API works; curl's args are root-only on this box.
  curl -fsS -m 20 "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null || log "telegram send failed"
}

cleanup() { docker rm -f "$RESTORE_CTR" >/dev/null 2>&1 || true; }

on_error() {
  local line=$1
  log "FAILED at line $line"
  cleanup
  telegram "❌ EzyCore DB backup FAILED ($STAMP, line $line). Production has no other backup: check $LOG on the server."
  exit 1
}
trap 'on_error $LINENO' ERR
trap cleanup EXIT

mkdir -p "$LOCAL_DIR"
exec 9>"$OUT/.backup.lock"
flock -n 9 || { log "another run is in progress, skipping"; exit 0; }

log "=== run $STAMP"
mkdir -p "$RUN_DIR"
# Total documents in real collections (views have no count of their own). Same file for the
# live database and the restored copy, so both sides are counted the same way.
cat >"$RUN_DIR/count.js" <<'JS'
let t = 0;
db.getCollectionInfos({ type: "collection" }).forEach((c) => {
  if (!c.name.startsWith("system.")) t += db.getCollection(c.name).estimatedDocumentCount();
});
print(t);
JS

# --- 1. live counts, then dump -------------------------------------------------------------
declare -A LIVE_TOTAL
for db in "${DBS[@]}"; do
  MONGO_URI="$(env_get MONGODB_URI "${ENV_FILE[$db]}")"
  export MONGO_URI
  [ -n "$MONGO_URI" ] || { log "no MONGODB_URI in ${ENV_FILE[$db]}"; false; }

  LIVE_TOTAL[$db]="$(docker run --rm -e MONGO_URI -v "$RUN_DIR:/out:ro" "$MONGO_IMAGE"     sh -c 'mongosh "$MONGO_URI" --quiet --file /out/count.js' | tail -1)"

  docker run --rm -e MONGO_URI -v "$RUN_DIR:/out" "$MONGO_IMAGE" \
    sh -c 'mongodump --uri "$MONGO_URI" --archive=/out/'"$db"'.archive.gz --gzip --quiet'
  unset MONGO_URI

  size=$(stat -c %s "$RUN_DIR/$db.archive.gz")
  [ "$size" -gt 1024 ] || { log "$db archive is only $size bytes"; false; }
  log "dumped $db: $size bytes, ${LIVE_TOTAL[$db]} live documents"
done

# --- 2. prove it restores -----------------------------------------------------------------
cleanup
docker run -d --name "$RESTORE_CTR" --network none -v "$RUN_DIR:/b:ro" "$MONGO_IMAGE" --quiet >/dev/null
for _ in $(seq 1 30); do
  docker exec "$RESTORE_CTR" mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break
  sleep 2
done

SUMMARY=""
for db in "${DBS[@]}"; do
  out="$(docker exec "$RESTORE_CTR" mongorestore --archive="/b/$db.archive.gz" --gzip --drop 2>&1)"
  echo "$out" | grep -q " 0 document(s) failed" || { log "restore of $db reported failures: $(echo "$out" | tail -2)"; false; }
  restored="$(docker exec "$RESTORE_CTR" mongosh "$db" --quiet --file /b/count.js | tail -1)"
  live=${LIVE_TOTAL[$db]}
  floor=$(( live * (100 - COUNT_TOLERANCE_PCT) / 100 ))
  [ "$restored" -ge "$floor" ] || { log "$db restored $restored of $live documents"; false; }
  log "restore check $db: $restored restored vs $live live (ok)"
  SUMMARY+="$db $(numfmt --to=iec "$(stat -c %s "$RUN_DIR/$db.archive.gz")") ($restored docs) · "
done
cleanup

# --- 3. upload to R2 ----------------------------------------------------------------------
R2_ENV="$OUT/r2.env"
AWS_ACCESS_KEY_ID="$(env_get R2_BACKUP_ACCESS_KEY_ID "$R2_ENV")"
AWS_SECRET_ACCESS_KEY="$(env_get R2_BACKUP_SECRET_ACCESS_KEY "$R2_ENV")"
BUCKET="$(env_get R2_BACKUP_BUCKET "$R2_ENV")"
ENDPOINT="https://$(env_get R2_BACKUP_ACCOUNT_ID "$R2_ENV").r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
aws() {
  docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=auto \
    -v "$LOCAL_DIR:/b:ro" "$AWS_IMAGE" --endpoint-url "$ENDPOINT" "$@"
}

aws s3 cp --recursive --quiet "/b/$STAMP" "s3://$BUCKET/daily/$STAMP/"
if [ "$(date -u +%d)" = "01" ]; then
  aws s3 cp --recursive --quiet "/b/$STAMP" "s3://$BUCKET/monthly/$STAMP/"
fi
# Read it back: both archives must be listed in R2, at the size they have here.
for db in "${DBS[@]}"; do
  remote="$(aws s3 ls "s3://$BUCKET/daily/$STAMP/$db.archive.gz" | awk '{print $3}')"
  [ "$remote" = "$(stat -c %s "$RUN_DIR/$db.archive.gz")" ] || { log "r2 copy of $db is missing or the wrong size"; false; }
done
log "uploaded to r2://$BUCKET/daily/$STAMP/ (sizes checked)"

# --- 4. retention -------------------------------------------------------------------------
# Run folders are named by their UTC timestamp, so age is read from the name, not mtimes.
prune_r2() {
  local prefix=$1 days=$2 cutoff
  cutoff="$(date -u -d "-$days days" +%Y-%m-%d)"
  # `aws s3 ls` exits 1 for a prefix with nothing in it (monthly/ until the first 1st), so an
  # empty listing is not an error. The upload above already proved the token works.
  { aws s3 ls "s3://$BUCKET/$prefix/" || true; } | awk '/PRE /{print $2}' | tr -d / | while read -r run; do
    if [[ "$run" < "$cutoff" ]]; then
      aws s3 rm --recursive --quiet "s3://$BUCKET/$prefix/$run/"
      log "pruned r2 $prefix/$run"
    fi
  done
}
prune_r2 daily "$KEEP_DAILY_DAYS"
prune_r2 monthly "$KEEP_MONTHLY_DAYS"
find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$((KEEP_LOCAL_DAYS - 1))" -exec rm -rf {} +

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
log "=== done $STAMP"
telegram "✅ EzyCore DB backup $STAMP: ${SUMMARY% · }. Restore-checked, uploaded to R2."
