# Changelog

All notable changes to the EzyCore deploy infrastructure (`easystock-infra`). One entry per production release.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions:
[Semantic Versioning](https://semver.org/) — see "Releasing" in [`CLAUDE.md`](CLAUDE.md).

## [Unreleased]

### Fixed
- **The production access log really keeps 30 days.** `roll_keep 20` (a file count) beat `roll_keep_for 720h`: storefront and scanner traffic fills a 50 MiB file every 1.5–2 h, so only about two days were kept. Found when two Messenger webhooks Meta never delivered (13–14 Nov) could not be looked up. Now `roll_keep 450` (≈ 34 days at today's rate, ≈ 1.7 GB of the 54 GB free), so the 30-day limit applies again. GoAccess's dashboard gains the same history.

### Changed
- **Production backend logs survive a deploy.** `backend-prod` logs to the host's journal (`logging: driver: journald`, tag `backend-prod`) instead of Docker's json-file, which kept only 30 MB and lost everything each time a deploy recreated the container. `docker logs` and Dozzle still work (Docker's dual logging). Read old logs with `journalctl CONTAINER_TAG=backend-prod --since … -o cat`.

### Deploy notes
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
