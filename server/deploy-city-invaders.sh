#!/usr/bin/env bash
# =============================================================================
# Deploy the City Invaders API to the VGData server (vmd171796 / 167.86.67.205).
# Follows vgdata-infra/runbooks/new-project.md (model: TurisHub/deploy-turishub.sh).
#
#   1. checks that the shared infrastructure is there and that it will not
#      overwrite a file it did not write
#   2. rsync server/ to /srv/city-invaders/
#   3. creates /srv/city-invaders/.env (mode 600) on the FIRST deploy only, with
#      a fresh ADMIN_TOKEN and the game's public key - never overwrites it
#   4. copies infra/city-invaders.yml and the vhost file into /srv/docker/nginx-proxy/
#   5. docker compose build + up -d city-invaders-api (only this service)
#   6. smoke test through the public URL
#
# Run from server/:  ./deploy-city-invaders.sh
# Never: down, --remove-orphans, prune (other projects share this compose project).
# =============================================================================
set -euo pipefail

SERVER="${SERVER:-root@167.86.67.205}"
TARGET="${TARGET:-/srv/city-invaders}"
PROXY_DIR="${PROXY_DIR:-/srv/docker/nginx-proxy}"
HOST="api.cityinvaders.vgdata.net"
YML="city-invaders.yml"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[$(date +'%H:%M:%S')] $*${N}"; }
warn() { echo -e "${Y}[$(date +'%H:%M:%S')] WARN: $*${N}"; }
err()  { echo -e "${R}[$(date +'%H:%M:%S')] ERR: $*${N}"; exit 1; }

cd "$(dirname "$0")"
[ -f "infra/$YML" ] || err "infra/$YML missing - run from the server/ folder"
[ -f Dockerfile ] || err "Dockerfile missing"
GAME_KEY=$(python3 -c "import json;print(json.load(open('../godot/assets/online.json'))['game_key'])")
[ -n "$GAME_KEY" ] || err "no game_key in godot/assets/online.json"

log "Bah's knowledge: the player guides and the tablet FAQ from the repository"
cp ../docs/GAMEPLAY.md ../docs/MODDING.md knowledge/
cp ../godot/assets/rio_grande_do_sul/gadgets/tablet/bah_faq.json knowledge/

log "Checking the shared infrastructure on the server..."
ssh "$SERVER" "set -e
  docker network inspect webnet >/dev/null 2>&1 || { echo '[ERR] network webnet missing - wrong server?'; exit 1; }
  docker ps --format '{{.Names}}' | grep -q '^nginx-proxy\$' || { echo '[ERR] nginx-proxy is not running'; exit 1; }
  test -f $PROXY_DIR/docker-compose.yml || { echo '[ERR] $PROXY_DIR/docker-compose.yml missing'; exit 1; }
  if [ -f $PROXY_DIR/$YML ] && ! grep -q 'City Invaders API' $PROXY_DIR/$YML; then
    echo '[ERR] $PROXY_DIR/$YML exists and was not written by this script'; exit 1
  fi
"
log "webnet, nginx-proxy and the base compose are there"

log "[1/5] rsync server/ -> $SERVER:$TARGET/"
ssh "$SERVER" "mkdir -p $TARGET"
rsync -az --delete \
  --exclude=node_modules --exclude=dist --exclude=data --exclude='*.db*' \
  --exclude=.env --exclude=.env.local --exclude=.env.production --exclude='*.pem' --exclude='*.log' \
  ./ "$SERVER:$TARGET/"

log "[2/5] .env (only created if missing)"
ssh "$SERVER" "set -e
  if [ ! -f $TARGET/.env ]; then
    umask 077
    sed -e 's|^GAME_CLIENT_KEY=.*|GAME_CLIENT_KEY=$GAME_KEY|' \
        -e \"s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=\$(openssl rand -hex 32)|\" \
        $TARGET/.env.example > $TARGET/.env
    chmod 600 $TARGET/.env
    echo 'created $TARGET/.env (fill in LLM_API_KEY for Bah)'
  else
    echo 'kept the existing $TARGET/.env'
  fi
"

log "[3/5] $YML and the vhost settings -> $PROXY_DIR"
scp -q "infra/$YML" "$SERVER:$PROXY_DIR/$YML"
scp -q "infra/vhost.d/$HOST" "$SERVER:$PROXY_DIR/vhost.d/$HOST"

log "[4/5] build + up -d city-invaders-api"
ssh "$SERVER" "set -e
  cd $PROXY_DIR
  export COMPOSE_IGNORE_ORPHANS=true
  docker compose -f docker-compose.yml -f $YML build city-invaders-api
  docker compose -f docker-compose.yml -f $YML up -d city-invaders-api
  docker ps --filter name=city-invaders- --format 'table {{.Names}}\t{{.Status}}'
"

log "[5/5] smoke test https://$HOST/healthz"
for i in $(seq 1 20); do
  if out=$(curl -fsS --max-time 5 "https://$HOST/healthz" 2>/dev/null); then
    log "OK: $out"
    exit 0
  fi
  sleep 6
done
warn "https://$HOST/healthz not answering yet (the certificate can take a couple of minutes)"
