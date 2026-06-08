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
```

## Rules

- **Never commit secrets.** All `.env.*` files live only on the server and are gitignored.
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
