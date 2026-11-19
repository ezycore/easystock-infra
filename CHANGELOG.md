# Changelog

All notable changes to the EzyCore deploy infrastructure (`easystock-infra`). One entry per production release.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions:
[Semantic Versioning](https://semver.org/) — see "Releasing" in [`CLAUDE.md`](CLAUDE.md).

## [Unreleased]

### Fixed
- **`backups/` is gitignored.** It holds full database dumps and the R2 backup token (`backups/r2.env`), and neither `.env` rule covered it, so a `git add -A` on the server would have committed both.
- **The production access log really keeps 30 days.** `roll_keep 20` (a file count) beat `roll_keep_for 720h`: storefront and scanner traffic fills a 50 MiB file every 1.5–2 h, so only about two days were kept. Found when two Messenger webhooks Meta never delivered (13–14 Nov) could not be looked up. Now `roll_keep 450` (≈ 34 days at today's rate, ≈ 1.7 GB of the 54 GB free), so the 30-day limit applies again. GoAccess's dashboard gains the same history.

### Added
- **Caddy sees the real visitor behind Cloudflare.** A global `servers` block trusts `CF-Connecting-IP` from Cloudflare's IP ranges only. Before, every request proxied by Cloudflare logged a Cloudflare IP as the visitor, and the apps received one as well: mihirima's www and admin, which the customer runs through their own Cloudflare, already did. This is the first step of the Cloudflare for SaaS move.
- **Temporary test hosts `saas-test.ezycore.app` and the root `ezycore.app`** prove the Cloudflare for SaaS path on a spare domain before any store moves. The root is a CNAME to `shops.ezycore.com` flattened by its own Cloudflare zone, the setup the stores' roots will use, since the Free plan does not proxy a root A record. They answer with the host, the visitor IP Caddy sees and Cloudflare's ray id, and reach no app. Remove them once the stores have moved.
- **Nightly production database backup to R2** (`backup/`). Atlas M0 has no backups, and the last copy before this was a manual dump from 2026-09-21. Every night at 03:00 Dhaka `db-backup.sh` dumps `easystock` and `mc`, **restores both into a throwaway mongod and compares document counts**, uploads to the private R2 bucket `ezycore-db-backups` and reads the sizes back. It keeps 30 daily copies, a monthly copy for about 13 months and 7 days on the server, and posts ✅ or ❌ to Telegram every night. Restore runbook: `backup/README.md`. Up to 24 h of data can still be lost: this is not point-in-time recovery.
- **Scanner probes are dropped at Caddy.** New `block_scanner_paths` snippet closes the connection for `/.env`, `/.git`, `/wp-login.php`, `/wp-admin`, `/xmlrpc.php`, `/phpinfo.php`, `/actuator`, `/cgi-bin/` and similar on every host. About 4,600 such requests a day reached Next/Express before (all 404). `/wp-content/` and `/wp-json/` are left alone: shoppers still follow old WordPress links.
- **fail2ban** (`fail2ban/`): `sshd` jail (~1,950 failed SSH logins a day, password login already off) and `caddy-scanner` jail (3 probes in an hour → banned from 80/443 for 24h, doubling for repeat offenders). Docker networks and Cloudflare never get banned. Plain `/wp-admin` and `/wp-login.php` don't count toward a ban, because merchants who moved from WooCommerce still open old bookmarks. Bans never cover SSH, so a wrong ban can always be undone: `sudo fail2ban-client set caddy-scanner unbanip <ip>`.
- `bootstrap.sh`: allows 443/udp (HTTP/3), sets deny-incoming explicitly, installs fail2ban.
- `templates/backend.env.example`: `INBOX_AI_CHAT_HOURLY_REPLY_CAP` (optional, empty = 15) — the backend's per-chat hourly AI reply cap.
- `templates/backend.env.example`: `INBOX_IMAGE_MODEL_PATH` (optional) — where the backend's photo-shortlist model lives; the backend image bakes it in, so leave it empty.
- **The production backend runs as two containers from one image** (branch `feat/backend-worker`): `backend-prod` (`APP_ROLE=api`) serves the API and the Messenger webhooks with no scheduled job, and the new `backend-worker-prod` (`APP_ROLE=worker`) runs every scheduled job — the AI reply worker, missed-message recovery, notifications, digests — and answers only `/health`. A deploy, a crash or a heavy AI photo turn in one no longer takes the other with it. Both log to journald. `templates/backend.env.example` documents `APP_ROLE` (set per container in compose, never in the env file) and `INBOX_AI_CONCURRENCY`.

### Changed
- **Production backend logs survive a deploy.** `backend-prod` logs to the host's journal (`logging: driver: journald`, tag `backend-prod`) instead of Docker's json-file, which kept only 30 MB and lost everything each time a deploy recreated the container. `docker logs` and Dozzle still work (Docker's dual logging). Read old logs with `journalctl CONTAINER_TAG=backend-prod --since … -o cat`.

### Deploy notes
- **DB backups:** needs `/opt/easystock/backups/r2.env` (root, 600: `R2_BACKUP_ACCOUNT_ID`, `R2_BACKUP_BUCKET`, `R2_BACKUP_ACCESS_KEY_ID`, `R2_BACKUP_SECRET_ACCESS_KEY`, a token scoped to that bucket). It was created on production 2026-11-19, and two runs that day passed, with the R2 copies checksum-identical to the restore-checked archives. After `git pull`: `sudo install -m 644 /opt/easystock/backup/ezycore-db-backup.cron /etc/cron.d/ezycore-db-backup`. No Telegram message on a morning means the job did not run.
- **Edge hardening — already live on production since 2026-11-19, applied by hand.** ufw on (22, 80, 443/tcp, 443/udp; it had been off since the 2026-08-01 OVH move, which skipped `bootstrap.sh`). The new Caddyfile is in place (backup `infra/Caddyfile.bak-20261119-edge`), and fail2ban is installed with both files from `fail2ban/`. On the next `git pull` on the server, `infra/Caddyfile` shows as modified with identical content: `sudo -u deploy git -C /opt/easystock checkout -- infra/Caddyfile` first, then pull, then `docker compose -f infra/docker-compose.yml restart caddy` (reload does not see a file git replaced). Testing the Caddy block from your own machine gets your IP banned from the web ports. Unban it right after.
- **Backend worker — ORDER MATTERS.** Deploy inventory-backend ≥ 1.29.0 to production FIRST and check `/health` reports it. Only then `git pull` this branch and `cd /opt/easystock/production && docker compose up -d`. An older backend image ignores `APP_ROLE`, so both containers would start every job and every digest, reminder and SMS would go out twice. Check afterwards: `docker logs backend-prod | grep '"role"'` → `api`, `docker logs backend-worker-prod | grep '"role"'` → `worker`, and only the worker logs `inbox.ai worker started`. To undo: remove the `backend-worker-prod` service and the `APP_ROLE` line, `docker compose up -d --remove-orphans` — the backend falls back to `all`.
- Backend logs: after `git pull`, `cd /opt/easystock/production && docker compose up -d backend-prod` recreates the container with the new driver (a few seconds of downtime — do it with the next backend deploy). Check: `docker inspect backend-prod --format '{{.HostConfig.LogConfig.Type}}'` → `journald`.
- On the server: `cd /opt/easystock && git pull && docker exec caddy caddy reload --config /etc/caddy/Caddyfile` (or `docker compose -f infra/docker-compose.yml restart caddy`). No downtime with `reload`. Files already deleted do not come back; the 30 days build up from now.

## [1.0.2] - 2026-10-27

### Added
- **Traffic dashboard at `stats.ezycore.com`** (`goaccess/`). GoAccess reads Caddy's production access log and shows, live: visitors per day, top IPs, traffic per host (each store's domain, the API), 404s and scanner probes, status codes, crawlers vs browsers, country and network owner, referrers and busiest hours (Dhaka time). The frontend's internal calls to the API (Docker gateway) are left out so visitor counts are real. It keeps 30 days, like the logs, and survives restarts. Reached only through the Cloudflare Tunnel behind Access, like Dozzle; Caddy refuses the name so the server IP cannot be used to skip Access.

### Deploy notes
- Pull, validate and `docker compose restart caddy` (new `stats.ezycore.com` abort block).
- `cd /opt/easystock/goaccess && chmod +x *.sh && ./update-geoip.sh && ./import-history.sh && docker compose up -d`.
- Cloudflare Zero Trust: add public hostname `stats.ezycore.com` → `http://stats-web:80` on the existing tunnel, and an Access application for it with Dozzle's policy. Until then the dashboard runs but is unreachable.

## [1.0.1] - 2026-10-27

### Security
- **Caddy drops requests carrying `X-Middleware-Subrequest`**, a Next.js-internal header that only exploit scanners send (the middleware-bypass attack, CVE-2025-29927 — our Next is already patched). Applied to every frontend block: `app.`, the `*.ezycore.com` wildcard, `rc.` and custom domains. About 10,600 such probes arrived from one host in two hours on 2026-10-27; each now ends at Caddy instead of rendering a page.
- **`smsmv.com` is refused.** It is not our domain, but its DNS (behind Cloudflare) still points at this server, so its traffic, mostly exploit scanners, landed on Caddy's HTTP→HTTPS redirect. Plain-HTTP requests for `smsmv.com` and `*.smsmv.com` are now aborted. The block is HTTP-only so Caddy never tries to get a certificate for a domain we don't control. Checked on a throwaway Caddy: `app.`, workspace subdomains and `uriibaba.com` still redirect to HTTPS, and the certificate-challenge path answers the same as live.

### Deploy notes
- Pull on the VPS, validate, then `docker compose restart caddy` (single-file bind mount — a reload does not see the new file).

## [1.0.0] - 2026-10-26

### Security
- **Dozzle can no longer be reached around Cloudflare Access.** It is now served only through a
  Cloudflare Tunnel behind Access, but Caddy still proxied `dozzle.ezycore.com`, so a request sent
  straight to the server IP reached Dozzle's own login without passing Access. The Caddy block now
  `abort`s (kept, not deleted, so the `*.ezycore.com` wildcard does not answer for the name).

### Deploy notes
- Copy `infra/Caddyfile` to `/opt/easystock/infra/`, validate it with the `infra-caddy` image, then
  reload Caddy. Check afterwards: `curl --resolve dozzle.ezycore.com:443:<server IP>
  https://dozzle.ezycore.com/` must fail to connect, and `https://dozzle.ezycore.com/` must still
  show the Cloudflare Access login.
- The `cloudflared` tunnel container was started by hand (`docker run`) and is not in this repo yet.

### Changed
- `backend.env.example` documents the `INBOX_AI_*` vars for the inbox's AI replies (platform
  switch off by default; keep it off in production until AI credit ships).
- `backend.env.example` documents the five `INBOX_FACEBOOK_*` vars for the inbox's "Connect with
  Facebook" (switch off by default; keep it off in production until Meta's App Review), and
  `META_GRAPH_API_VERSION` now covers every Meta call.
- `backend.env.example` documents `RETENTION_INBOX_DAYS` (default 365): how long Messenger inbox
  chats are kept. `API_PUBLIC_URL` must be the public API origin — merchants paste the webhook URL
  built from it into Meta.
- `backend.env.example` documents `SIGNUP_ACCESS_KEY`: set it on production to
  close self-signup to the team's `/signup?key=…` link (empty = open, as before).
- `backend.env.example` documents `GIT_SHA` (baked into the image — do not set on the server).
- `frontend.env.example` documents `NEXT_PUBLIC_GIT_SHA` (build arg) and
  `NEXT_PUBLIC_APP_VERSION` (filled from package.json at build).
