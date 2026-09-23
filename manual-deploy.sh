#!/usr/bin/env bash
# Manual deploy — no GitHub Actions, no GHCR.
#
# Ships the exact committed tree of a branch to the VPS, builds the image there
# (native amd64), tags it with the SAME name docker-compose.yml expects, runs
# migrations, then recreates the container.
#
# Usage:
#   ./manual-deploy.sh backend               # production (branch: main)
#   ./manual-deploy.sh frontend staging      # staging    (branch: rc)
#   ./manual-deploy.sh all
#
# NEVER run `docker compose pull` while on this path: it would overwrite the
# image you just built with the stale one still sitting in GHCR.

set -euo pipefail

VPS="${VPS:-deploy@139.99.90.41}"
REPOS_ROOT="${REPOS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_ROOT="/opt/easystock/manual-build"

APP="${1:?usage: ./manual-deploy.sh <backend|frontend|mc-api|mc-admin|all> [production|staging]}"
ENVIRON="${2:-production}"

case "$ENVIRON" in
  production) BRANCH=main; DIR=production; SFX=prod ;;
  staging)    BRANCH=rc;   DIR=staging;    SFX=staging ;;
  *) echo "env must be production|staging" >&2; exit 1 ;;
esac

# The remote script is written to a file and executed, NOT piped to `bash -s`:
# `docker compose run` attaches stdin, and on a piped script it swallows every
# remaining line (the `up -d` never runs and the deploy silently no-ops).
ssh_run() {
  ssh "$VPS" "cat > /tmp/manual-deploy-step.sh && bash /tmp/manual-deploy-step.sh" <<< "$1"
}

# repo dir | build context inside repo | image name | migrate? 
meta() {
  case "$1" in
    backend)   echo "inventory-backend . ghcr.io/ezycore/easystock-backend yes" ;;
    frontend)  echo "inventory-frontend . ghcr.io/ezycore/easystock-frontend no" ;;
    mc-api)    echo "mission-control . ghcr.io/ezycore/mission-control yes" ;;
    mc-admin)  echo "mission-control admin ghcr.io/ezycore/mission-control-admin no" ;;
    *) echo "unknown app: $1" >&2; exit 1 ;;
  esac
}

build_args() {
  case "$1:$ENVIRON" in
    frontend:production)
      echo "--build-arg NEXT_PUBLIC_API_URL=https://api.ezycore.com/api --build-arg NEXT_PUBLIC_ROOT_DOMAIN=ezycore.com --build-arg NEXT_PUBLIC_STOREFRONT_ROOT_DOMAIN=ezycore.com" ;;
    frontend:staging)
      echo "--build-arg NEXT_PUBLIC_API_URL=https://rc-api.ezycore.com/api" ;;
    mc-admin:production)
      echo "--build-arg NEXT_PUBLIC_API_URL=https://mc-api.ezycore.com/api" ;;
    mc-admin:staging)
      echo "--build-arg NEXT_PUBLIC_API_URL=https://rc-mc-api.ezycore.com/api" ;;
    *) echo "" ;;
  esac
}

# compose service name for an app
service() {
  case "$1" in
    backend)  echo "backend-$SFX" ;;
    frontend) echo "frontend-$SFX" ;;
    mc-api)   echo "mc-api-$SFX" ;;
    mc-admin) echo "mc-admin-$SFX" ;;
  esac
}

deploy_one() {
  local app="$1"
  read -r repo ctx image migrate <<< "$(meta "$app")"
  local repo_path="$REPOS_ROOT/$repo"
  local svc; svc="$(service "$app")"
  local remote="$BUILD_ROOT/$app"

  [ -d "$repo_path/.git" ] || { echo "no git repo at $repo_path" >&2; exit 1; }
  local sha; sha="$(git -C "$repo_path" rev-parse --short "origin/$BRANCH")"

  echo "==> $app ($ENVIRON) @ origin/$BRANCH $sha"

  # 1. ship the exact committed tree (tracked files only — no node_modules, no .env, no .git)
  ssh_run "rm -rf '$remote' && mkdir -p '$remote'"
  git -C "$repo_path" archive --format=tar "origin/$BRANCH" \
    | ssh "$VPS" "tar -x -C '$remote'"

  # 2. build natively on the VPS, tagged exactly as docker-compose.yml expects
  ssh_run "set -e
    cd '$remote/$ctx'
    docker build $(build_args "$app") -t '$image:$ENVIRON' -t '$image:$sha' ."

  # 3. migrate + recreate, under the same lock the workflow uses
  ssh_run "set -e
    exec 9>/opt/easystock/.deploy.lock
    flock -w 600 9
    cd /opt/easystock/$DIR
    $( [ "$migrate" = yes ] && echo "docker compose run --rm -T $svc npx migrate-mongo up </dev/null" )
    docker compose up -d $svc
    docker image prune -f || true"

  echo "==> $app done"
}

if [ "$APP" = all ]; then
  for a in backend mc-api frontend mc-admin; do deploy_one "$a"; done
else
  deploy_one "$APP"
fi

# builder cache eats the 4 GB box's disk fast when building on the server
ssh_run "docker builder prune -f --filter until=48h || true"
echo "ALL DONE ($ENVIRON)"
