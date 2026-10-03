# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this is

Infrastructure for the EasyStock ecosystem. This repo **mirrors `/opt/easystock/` on the server**, so
the deploy flow is: edit locally → git push → (on server) git pull → `docker compose up -d`.

> **Cross-repo master reference:** `mission-control/docs/EZYCORE_MASTER_REFERENCE.md` — the full
> cross-product reference across all five repos, including this one. It cites this repo directly for
> backup/env-template claims (Parts XII.3, the infra env audit). **Update it in the same PR** if you
> add/remove a backup mechanism, change what's in `templates/*.env.example`, or otherwise change a
> fact it documents about deploy/infra.

```
infra/         # shared Caddy reverse proxy (HTTPS front door), Caddyfile + compose
staging/       # staging app stack   (compose only; .env.* live on the server)
production/    # production app stack (compose only; .env.* live on the server)
dozzle/        # live container log viewer (read-only socket; replaced Portainer)
templates/     # ⭐ the env registry — see below
bootstrap.sh   # provision a blank Ubuntu 24.04 VPS (idempotent)
```

Full runbook: `mission-control/docs/DEPLOYMENT.md` and `docs/deployment/DEPLOYMENT-RUNBOOK.md`.

## `templates/` is the env registry (mandatory)

Real `.env.*` files are gitignored and live **only on the server**. That makes `templates/` the only
written record of what an environment needs — provisioning a new box means copying these files and
filling the blanks. **A var missing here does not exist**, as far as the next operator is concerned.

| Template | Consumed by | Read at |
|---|---|---|
| `backend.env.example` | `inventory-backend` → `/opt/easystock/{production,staging}/.env.backend` | runtime |
| `mc-api.env.example` | `mission-control` (API) → `.env.mc-api` | runtime |
| `frontend.env.example` | `inventory-frontend` → `.env.frontend` (`NODE_ENV` only) | **build** — `NEXT_PUBLIC_*` baked into the image |
| `mc-admin.env.example` | `mission-control/admin` → `.env.mc-admin` (`NODE_ENV` only) | **build** — same |
| `infra.env.example` | Caddy → `/opt/easystock/infra/.env` | runtime (compose `${VAR}` substitution) |
| `marketing.env.example` | `easystock-marketing` → Cloudflare Pages env vars (**no server, no container**) | build |

### The sync contract

Each app repo's `CLAUDE.md` carries an "Infra env templates (mandatory)" section pointing back here.
The rule is symmetric — **whichever side you are editing, the other side changes in the same commit.**

- **App repo adds/removes/renames a var** → update the matching template here.
- **A template changes** → update the app repo's `.env.example` (and, for the two Next tiers, the
  `Dockerfile` `ARG` + the workflow `build-arg`), and apply the value on the server.
- **Never commit a real secret.** Placeholders only, in every file in this repo.
- **Delete vars the code no longer reads.** A template listing a dead var teaches every future
  operator to keep setting it.
- **Comment what breaks when a var is empty**, and give the production *and* staging values whenever
  they differ. That is the whole reason these files are prose-heavy — a bare `KEY=` is a trap.

### Cross-file constants that must match

These are not per-service settings; a mismatch is a silent outage, so change them in lockstep:

| Value | Must be identical in |
|---|---|
| `DOMAIN_CHECK_SECRET` | `infra.env.example` (Caddy) **and** `backend.env.example` (backend-prod) — the on-demand-TLS `ask` endpoint fails closed otherwise, and every custom domain stops issuing certs |
| `ADMIN_DELETE_GRACE_MINUTES` | `backend.env.example` **and** MC's own value — otherwise the two disagree on the workspace-delete undo window |
| `PORT` | The template **and** the container name/port in `infra/Caddyfile` (backend 5000, mc-api 6000, frontend 3000, mc-admin 4000). These are not free choices |
| Marketing deploy hook | MC's `MARKETING_DEPLOY_HOOK_URL` ↔ the Cloudflare Pages hook for the marketing project |

### Auditing for drift

From the workspace root, for each service, every name printed must appear in its template:

```bash
# backend
grep -rhoE 'process\.env\.[A-Z0-9_]+' inventory-backend/src | sed 's/process\.env\.//' | sort -u
# mission-control — the Zod schema is authoritative, not grep
sed -n '/envSchema = z.object/,/^});/p' mission-control/src/config/env.ts
# frontend / marketing
grep -rhoE 'process\.env\.[A-Z0-9_]+' inventory-frontend --include='*.ts' --include='*.tsx' \
  --exclude-dir=node_modules --exclude-dir=.next | sort -u
```

## Access logs (Caddy)

Every site block in `infra/Caddyfile` imports an `access_log` snippet. Before 2026-09-23 none did,
and Caddy's default is silence — so a probe against `app.ezycore.com` and `mc.ezycore.com` that day
left no IP, no user agent, nothing. Assume any host you add is invisible until you add the import.

- **Where:** `/opt/easystock/infra/logs/access.log` (production, custom domains, dozzle) and
  `access-staging.log`. Bind-mounted, so read them on the host — no `docker exec` needed.
- **Format:** JSON, one object per line. `jq` is the right tool:
  ```bash
  # who hit a host, busiest first
  jq -r 'select(.request.host=="mc.ezycore.com") | .request.client_ip' access.log | sort | uniq -c | sort -rn
  # the server-action probe shape
  jq -r 'select(.request.headers["Next-Action"]) | [.ts, .request.client_ip, .request.uri] | @tsv' access.log
  ```
- **Retention:** Caddy rolls and gzips by itself — 30 days production, 7 days staging. No logrotate.
  Thirty days is also the furthest back any visitor rollup could ever be rebuilt.
- **Real client IPs depend on DNS staying "DNS only"** (grey cloud, DEPLOYMENT.md §6). Flip a record
  to the orange cloud and `client_ip` becomes a Cloudflare IP — the log keeps working, it just starts
  lying — until you add `trusted_proxies` + `client_ip_headers` to the snippet.
- **These files are sensitive and `infra/logs/` is gitignored.** Credentials in *headers* are redacted
  by Caddy (`log_credentials` is off — leave it off). Credentials in the *URL* are not, so the snippet
  carries an explicit redaction pattern for `/t/<token>` (order tracking), the courier webhook token
  and the phone number in `/orders/track?…`. **Ship a new tokenized or PII-bearing public URL and you
  must add it to that pattern in the same commit**, or its secret starts landing in plaintext.
  Caddy allows one `regexp` filter per field, so they share a single alternation.

## Releasing (versions + changelog)

Infra changes are released with their own version, like every EzyCore repo since **2026-10-03** (`inventory-backend` and
`inventory-frontend` started at 1.0.0 that day). Each repo versions independently.
**Not yet released under this scheme:** the next change applied to a server after 2026-10-03 is cut as **1.0.0**.

- **There is no `package.json`: the version is the git tag plus the `CHANGELOG.md` heading.** A
  template-only change (a new env var documented) is still a PATCH — it is what tells the operator
  a server file needs editing.
- **Semver:** PATCH = fixes only · MINOR = new features, nothing breaks · MAJOR = a
  breaking change (a sibling repo must deploy in lockstep, a contract field removed,
  a migration that must run first).
- **`CHANGELOG.md` is kept as you go — every change, every session.** Each change adds
  one line under `## [Unreleased]` → Added / Changed / Removed / Fixed, written for
  whoever reads the deploy, not as a commit log. Migrations, new env vars and
  cross-repo ordering ("needs inventory-backend ≥ 1.2.0") go under **Deploy notes**.
  A change with no changelog line is unfinished — the same as a missing test or doc.
- **Cutting a release** (the owner pushes and tags — never push or tag unasked):
  1. Pick the bump from what is under Unreleased.
  2. no version file to bump — the heading and the tag are the version; rename `[Unreleased]` to `[x.y.z] - YYYY-MM-DD` and open a fresh
     empty `[Unreleased]` above it.
  3. Commit `chore(release): vX.Y.Z`; merge to the deploy branch.
  4. On the deployed commit: `git tag -a vX.Y.Z -m "vX.Y.Z"` and push the tag.

## Rules for changing this repo

- **Container names in `{staging,production}/docker-compose.yml` MUST match the upstreams in
  `infra/Caddyfile`.** Renaming one without the other 502s the whole tier.
- **A new site block in `infra/Caddyfile` needs `import access_log` (or `access_log_staging`) as its
  first line.** Caddy logs nothing by default, so a host without it is unobservable — see Access logs.
- The `edge` Docker network is shared by Caddy and every app stack; it is external and created once
  (`docker network create edge`, done by `bootstrap.sh`).
- `bootstrap.sh` is idempotent and provider-agnostic — keep it that way. It is the recovery path when
  a server is rebuilt, and skipping it is what cost a day during the 2026-08-01 OVH migration
  (`mission-control/docs/deployment/SERVER-MIGRATION.md`).
- Clock sync is load-bearing, not hygiene: MC↔backend HMAC rejects drift over 5 minutes.
- **Never set `TZ` on a container or in an env template.** Every service runs in UTC on purpose; the
  apps decide calendars themselves (organization timezone in the product, Asia/Dhaka in Mission
  Control — see each repo's CLAUDE.md → Timezones). A `TZ=Asia/Dhaka` would silently move every cron,
  and change how zone-less date-times parse and print in ways no test runs under (tests pin UTC).
