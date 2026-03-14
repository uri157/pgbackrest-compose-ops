#!/usr/bin/env bash
set -euo pipefail

: "${S3_ENDPOINT:?Falta S3_ENDPOINT}"
: "${S3_BUCKET:?Falta S3_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"
: "${AWS_DEFAULT_REGION:?Falta AWS_DEFAULT_REGION}"
: "${BACKUP_KEY:?Falta BACKUP_KEY (path dentro del bucket)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.prod.yml}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-${COMPOSE_ENV:-${DEPLOY_DIR}/env/.env.compose}}"
PG_SERVICE="${PG_SERVICE:-postgres}"

local_path="/tmp/restore.sql.gz"

aws --endpoint-url "$S3_ENDPOINT" s3 cp "s3://${S3_BUCKET}/${BACKUP_KEY}" "$local_path"

gunzip -c "$local_path" | docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" exec -T "$PG_SERVICE" \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

rm -f "$local_path"

echo "Restore completado desde: s3://${S3_BUCKET}/${BACKUP_KEY}"
