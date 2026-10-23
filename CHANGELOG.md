# Changelog

All notable changes to the EzyCore deploy infrastructure (`easystock-infra`). One entry per production release.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions:
[Semantic Versioning](https://semver.org/) — see "Releasing" in [`CLAUDE.md`](CLAUDE.md).

## [Unreleased]

### Changed
- `backend.env.example` documents `RETENTION_INBOX_DAYS` (default 365): how long Messenger inbox
  chats are kept. `API_PUBLIC_URL` must be the public API origin — merchants paste the webhook URL
  built from it into Meta.
- `backend.env.example` documents `SIGNUP_ACCESS_KEY`: set it on production to
  close self-signup to the team's `/signup?key=…` link (empty = open, as before).
- `backend.env.example` documents `GIT_SHA` (baked into the image — do not set on the server).
- `frontend.env.example` documents `NEXT_PUBLIC_GIT_SHA` (build arg) and
  `NEXT_PUBLIC_APP_VERSION` (filled from package.json at build).
