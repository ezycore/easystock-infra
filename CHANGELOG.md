# Changelog

All notable changes to the EzyCore deploy infrastructure (`easystock-infra`). One entry per production release.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions:
[Semantic Versioning](https://semver.org/) — see "Releasing" in [`CLAUDE.md`](CLAUDE.md).

## [Unreleased]

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
