#!/usr/bin/env bash
set -euo pipefail

: "${S3_ENDPOINT:?Falta S3_ENDPOINT}"
: "${S3_BUCKET:?Falta S3_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"
: "${AWS_DEFAULT_REGION:?Falta AWS_DEFAULT_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.prod.yml}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-${COMPOSE_ENV:-${DEPLOY_DIR}/env/.env.compose}}"
PG_SERVICE="${PG_SERVICE:-postgres}"

prefix="${S3_PREFIX:-}"
prefix="${prefix#/}"
if [ -n "$prefix" ]; then
  prefix="${prefix%/}/"
fi

timestamp="$(date -u +"%Y%m%d_%H%M%S")"
filename="pg_${timestamp}.sql.gz"
local_path="/tmp/${filename}"

# Ejecuta pg_dump dentro del contenedor para evitar exponer Postgres al host.
docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T "$PG_SERVICE" \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$local_path"

aws --endpoint-url "$S3_ENDPOINT" s3 cp "$local_path" "s3://${S3_BUCKET}/${prefix}${filename}"
rm -f "$local_path"

echo "Backup subido: s3://${S3_BUCKET}/${prefix}${filename}"
