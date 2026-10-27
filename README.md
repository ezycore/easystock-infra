# easystock-infra

Infrastructure for the EasyStock ecosystem. This repo **mirrors `/opt/easystock/`**
on the server, so the deploy flow is just:

```
edit locally → git push → (on server) git pull → docker compose up -d
```

## Layout

```
infra/        # shared Caddy reverse proxy (HTTPS front door) — §9
├── Caddyfile
└── docker-compose.yml
staging/      # staging app stack            — §10 (compose only; .env.* live on server)
production/   # production app stack         — §10 (compose only; .env.* live on server)
dozzle/       # live container log viewer (read-only Docker socket, Caddy Basic Auth)
goaccess/     # traffic dashboard (GoAccess) from Caddy's access log, behind Cloudflare Access
templates/    # the ecosystem's ENV REGISTRY — copy to the server and fill the blanks
bootstrap.sh  # provision a blank Ubuntu 24.04 VPS (idempotent, provider-agnostic)
```

## `templates/` is the env registry

The real `.env.*` files are gitignored and exist **only on the server**, so these templates are the
only written record of what an environment needs. **A var that isn't listed here doesn't exist**, as
far as whoever provisions the next box is concerned.

| Template | Service | Read at |
|---|---|---|
| `backend.env.example`  | `inventory-backend` → `.env.backend`  | runtime |
| `mc-api.env.example`   | `mission-control` API → `.env.mc-api` | runtime |
| `frontend.env.example` | `inventory-frontend` → `.env.frontend` | **build** (`NEXT_PUBLIC_*` baked into the image) |
| `mc-admin.env.example` | `mission-control/admin` → `.env.mc-admin` | **build** (same) |
| `infra.env.example`    | Caddy → `infra/.env`                  | runtime |
| `marketing.env.example`| `easystock-marketing` → Cloudflare Pages | build (no server, no container) |

**The sync rule is symmetric and mandatory:** an app repo adding, removing or renaming a var updates
its template here in the same commit, and vice versa. Each app repo's `CLAUDE.md` carries the matching
"Infra env templates (mandatory)" section. Details, the cross-file constants that must match
(`DOMAIN_CHECK_SECRET`, `ADMIN_DELETE_GRACE_MINUTES`, the ports), and the drift-audit commands are in
[`CLAUDE.md`](CLAUDE.md).

## Rules

- **Never commit secrets.** All `.env.*` files live only on the server and are gitignored;
  `templates/` holds placeholders and prose only.
- **Container names in `{staging,production}/docker-compose.yml` must match the upstreams in
  `infra/Caddyfile`** — renaming one without the other 502s the tier.
- The `edge` Docker network is shared by Caddy and every app stack. Create it once:
  `docker network create edge`.

## Bring up Caddy (§9)

```bash
docker network create edge                 # once
cd /opt/easystock/infra
docker compose up -d
docker compose logs -f caddy               # watch it obtain certs
curl -I https://rc-mc-api.ezycore.com      # valid TLS + 502 (until §10) = success
```
