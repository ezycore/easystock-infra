# Changelog

All notable changes to the EzyCore deploy infrastructure (`easystock-infra`). One entry per production release.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions:
[Semantic Versioning](https://semver.org/) — see "Releasing" in [`CLAUDE.md`](CLAUDE.md).

## [Unreleased]

## [1.0.0] - 2026-10-23

### Added
- `SSR_API_KEY` in `backend.env.example` **and** `frontend.env.example` (same value per
  environment): the storefront server's key past the backend's global per-IP rate limit. The
  frontend's first runtime var. See "Cross-file constants that must match".

### Fixed
- `backend.env.example` set `RATE_LIMIT_MAX_REQUESTS=1000` against the code's sized default of
  5000; production was provisioned from it and ran out on 2026-10-23. Now 5000.

### Deploy notes
- On the server, in both `production/` and `staging/`: generate a key (`openssl rand -hex 32`), put
  the SAME value as `SSR_API_KEY=` in `.env.backend` and `.env.frontend`, set
  `RATE_LIMIT_MAX_REQUESTS=5000` in `.env.backend`, then recreate both containers
  (`docker compose up -d`; a plain restart does not reload `env_file`).

### Changed
- `backend.env.example` documents `SIGNUP_ACCESS_KEY`: set it on production to
  close self-signup to the team's `/signup?key=…` link (empty = open, as before).
- `backend.env.example` documents `GIT_SHA` (baked into the image — do not set on the server).
- `frontend.env.example` documents `NEXT_PUBLIC_GIT_SHA` (build arg) and
  `NEXT_PUBLIC_APP_VERSION` (filled from package.json at build).
