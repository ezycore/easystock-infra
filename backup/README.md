# Database backups

Production runs on **MongoDB Atlas M0 (free tier), which has no backups of its own.** This nightly
job is the only backup there is. Started 2026-11-19; before that, the only copy was a manual dump
from 2026-09-21.

## What runs

`db-backup.sh` runs as root at **21:00 UTC (03:00 Dhaka)** from `/etc/cron.d/ezycore-db-backup`:

1. `mongodump` of `easystock` (the product) and `mc` (Mission Control: billing, subscriptions),
   one gzip archive each.
2. **Restore check, every night:** both archives are restored into a throwaway local `mongod`
   (no network), and the document totals are compared with the live database (2% allowed for writes
   made during the dump). An archive that cannot be restored fails the run.
3. Upload to R2 bucket `ezycore-db-backups`, then read back: each object must exist at the local size.
4. Retention: `daily/` 30 days, `monthly/` (a copy on the 1st) about 13 months, and the last 7 days
   on the server in `/opt/easystock/backups/auto/`.
5. Telegram (the backend's `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`): ✅ with sizes every night,
   ❌ on any failure. **No message at all means the job did not run.** Check the cron.

Log: `/opt/easystock/backups/backup.log`. Credentials: `/opt/easystock/backups/r2.env` (root, 600),
an R2 token scoped to that one bucket. That file is not in git. To rebuild it, create a new token in
Cloudflare → R2 → Manage API tokens (Object Read & Write, this bucket only).

At 2026-11-19 sizes a run takes about 40 s: easystock 6.8 MB, mc 0.3 MB.

## Install (or reinstall)

```bash
sudo chmod 755 /opt/easystock/backup/db-backup.sh   # git keeps the bit; this is belt and braces
sudo install -m 644 /opt/easystock/backup/ezycore-db-backup.cron /etc/cron.d/ezycore-db-backup
sudo /opt/easystock/backup/db-backup.sh && sudo tail -8 /opt/easystock/backups/backup.log
```

On a new server, `bootstrap.sh` prints these same steps in its "next steps".

## Restore

Every archive in `auto/` and in R2 has already been restored once, by the job itself, so the files
are known to work. What follows puts one back into a real database.

**Never restore over production without deciding it first.** `--drop` replaces every collection
in the archive. Restore into a new database name and compare first, unless production is
already lost.

1. **Pick the archive.** It's either on the server (`/opt/easystock/backups/auto/<run>/`) or in R2.
   To download one from R2:
   ```bash
   sudo bash -c 'set -a; . /opt/easystock/backups/r2.env; set +a
     export AWS_ACCESS_KEY_ID=$R2_BACKUP_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_BACKUP_SECRET_ACCESS_KEY
     mkdir -p /tmp/restore
     docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=auto \
       -v /tmp/restore:/d amazon/aws-cli:2.17.0 \
       --endpoint-url https://$R2_BACKUP_ACCOUNT_ID.r2.cloudflarestorage.com \
       s3 cp --recursive s3://$R2_BACKUP_BUCKET/daily/<run>/ /d/'
   ```
2. **Restore into a side database first** (here `easystock_restore`) and look at it:
   ```bash
   export MONGO_URI='<Atlas URI WITHOUT a database name>'   # type it, don't paste it into a chat
   sudo -E docker run --rm -e MONGO_URI -v /tmp/restore:/b:ro mongo:8.0 sh -c \
     'mongorestore --uri "$MONGO_URI" --archive=/b/easystock.archive.gz --gzip \
        --nsFrom "easystock.*" --nsTo "easystock_restore.*"'
   ```
3. **To replace production:** stop the writers first (`backend-prod`, `backend-worker-prod`,
   `mc-api-prod`), restore with `--drop` and no `--nsTo`, then start them again. Restore `mc`
   from the same run as `easystock`, because the two are cross-linked (subscriptions ↔ organizations).

## Limits, honestly

- **Up to 24 hours of data can be lost.** This is a nightly copy, not point-in-time recovery.
  Atlas M10+ gives continuous backups.
- Staging is not backed up (separate cluster, test data).
- Images live in R2 (product images bucket) and are not part of this backup.
