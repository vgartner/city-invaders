#!/usr/bin/env bash
# =============================================================================
# Deploy the City Invaders LFS server (Forgejo) to the VGData server
# (vmd171796 / 167.86.67.205). Same pattern as deploy-city-invaders.sh.
#
#   1. checks the shared infrastructure, and that it will not overwrite a file
#      it did not write
#   2. creates /srv/city-invaders-lfs/{data,.env} on the FIRST deploy only: the
#      .env (mode 600) holds fresh random secrets and is never overwritten
#   3. copies infra/city-invaders-lfs.yml and the vhost file into
#      /srv/docker/nginx-proxy/
#   4. docker compose pull + up -d city-invaders-lfs (only this service)
#   5. on the first deploy, creates the admin user; its password goes to
#      /srv/city-invaders-lfs/admin-password (mode 600), never to the terminal
#   6. smoke test through the public URL
#
# Run from server/:  ./deploy-city-invaders-lfs.sh
# Never: down, --remove-orphans, prune (other projects share this compose project).
# =============================================================================
set -euo pipefail

SERVER="${SERVER:-root@167.86.67.205}"
TARGET="${TARGET:-/srv/city-invaders-lfs}"
PROXY_DIR="${PROXY_DIR:-/srv/docker/nginx-proxy}"
HOST="lfs.cityinvaders.vgdata.net"
YML="city-invaders-lfs.yml"
ADMIN="${ADMIN:-vilson}"
ADMIN_EMAIL="${ADMIN_EMAIL:-vilson@vgdata.net}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${G}[$(date +'%H:%M:%S')] $*${N}"; }
warn() { echo -e "${Y}[$(date +'%H:%M:%S')] WARN: $*${N}"; }
err()  { echo -e "${R}[$(date +'%H:%M:%S')] ERR: $*${N}"; exit 1; }

cd "$(dirname "$0")"
[ -f "infra/$YML" ] || err "infra/$YML missing - run from the server/ folder"
[ -f "infra/vhost.d/$HOST" ] || err "infra/vhost.d/$HOST missing"

log "Checking the shared infrastructure on the server..."
ssh "$SERVER" "set -e
  docker network inspect webnet >/dev/null 2>&1 || { echo '[ERR] network webnet missing - wrong server?'; exit 1; }
  docker ps --format '{{.Names}}' | grep -q '^nginx-proxy\$' || { echo '[ERR] nginx-proxy is not running'; exit 1; }
  test -f $PROXY_DIR/docker-compose.yml || { echo '[ERR] $PROXY_DIR/docker-compose.yml missing'; exit 1; }
  if [ -f $PROXY_DIR/$YML ] && ! grep -q 'City Invaders LFS' $PROXY_DIR/$YML; then
    echo '[ERR] $PROXY_DIR/$YML exists and was not written by this script'; exit 1
  fi
"
log "webnet, nginx-proxy and the base compose are there"

log "[1/5] $TARGET/data and .env (only created if missing)"
ssh "$SERVER" "set -e
  mkdir -p $TARGET/data
  chown 1000:1000 $TARGET/data
  if [ ! -f $TARGET/.env ]; then
    umask 077
    b64() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '='; }
    {
      echo \"FORGEJO__security__SECRET_KEY=\$(openssl rand -hex 32)\"
      echo \"FORGEJO__security__INTERNAL_TOKEN=\$(openssl rand -hex 48)\"
      echo \"FORGEJO__server__LFS_JWT_SECRET=\$(b64)\"
      echo \"FORGEJO__oauth2__JWT_SECRET=\$(b64)\"
    } > $TARGET/.env
    chmod 600 $TARGET/.env
    echo 'created $TARGET/.env'
  else
    echo 'kept the existing $TARGET/.env'
  fi
"

log "[2/5] $YML and the vhost settings -> $PROXY_DIR"
scp -q "infra/$YML" "$SERVER:$PROXY_DIR/$YML"
scp -q "infra/vhost.d/$HOST" "$SERVER:$PROXY_DIR/vhost.d/$HOST"

log "[3/5] pull + up -d city-invaders-lfs"
ssh "$SERVER" "set -e
  cd $PROXY_DIR
  export COMPOSE_IGNORE_ORPHANS=true
  docker compose -f docker-compose.yml -f $YML pull city-invaders-lfs
  docker compose -f docker-compose.yml -f $YML up -d city-invaders-lfs
  for i in \$(seq 1 30); do
    [ \"\$(docker inspect -f '{{.State.Health.Status}}' city-invaders-lfs)\" = healthy ] && break
    sleep 3
  done
  docker ps --filter name=city-invaders-lfs --format 'table {{.Names}}\t{{.Status}}'
"

log "[4/5] admin user (first deploy only)"
ssh "$SERVER" "set -e
  if [ ! -f $TARGET/admin-password ]; then
    umask 077
    pw=\$(openssl rand -base64 24 | tr -d '/+=')
    docker exec -u git city-invaders-lfs forgejo admin user create --admin \
      --username '$ADMIN' --email '$ADMIN_EMAIL' --password \"\$pw\" --must-change-password=false >/dev/null
    echo \"\$pw\" > $TARGET/admin-password
    chmod 600 $TARGET/admin-password
    echo 'created the admin user $ADMIN; password in $TARGET/admin-password'
  else
    echo 'admin user already there'
  fi
"

log "[5/5] smoke test https://$HOST/api/healthz"
for i in $(seq 1 20); do
  if out=$(curl -fsS --max-time 5 "https://$HOST/api/healthz" 2>/dev/null); then
    log "OK: $(echo "$out" | tr -d '\n' | cut -c1-120)"
    exit 0
  fi
  sleep 6
done
warn "https://$HOST/api/healthz not answering yet (the certificate can take a couple of minutes)"
