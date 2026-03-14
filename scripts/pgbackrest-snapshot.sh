#!/usr/bin/env bash
set -euo pipefail

# Uso:
#   scripts/pgbackrest-snapshot.sh --label "post-check"
#
# Qué hace:
#   - Snapshot de pgBackRest (info + check) y lo apendea en /state/pgbackrest-info.log
#   - No toca backups, no restaura, solo registra estado.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${script_dir}/lib/load-ops-config.sh"
load_ops_config "$script_dir"

repo_root="$(cd "${script_dir}/.." && pwd)"
deploy_dir="${DEPLOY_DIR:-$repo_root}"
env_dir="${ENV_DIR:-${deploy_dir}/env}"
state_dir="${STATE_DIR:-${deploy_dir}/state}"
compose_file="${COMPOSE_FILE:-${deploy_dir}/docker-compose.prod.yml}"
compose_env="${COMPOSE_ENV:-${env_dir}/.env.compose}"
deploy_env="${DEPLOY_ENV:-${deploy_dir}/.env.deploy}"
pgbackrest_service="${PGBACKREST_SERVICE:-pgbackrest}"
pgbr_conf="${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"

LABEL="snapshot"
STANZA="${PGBR_STANZA:-main}"

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:-snapshot}"; shift 2;;
    --stanza) STANZA="${2:-${PGBR_STANZA:-main}}"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

mkdir -p "$state_dir"
touch "${state_dir}/pgbackrest-info.log" || true
chmod 700 "$state_dir" || true
chmod 600 "${state_dir}/pgbackrest-info.log" || true

# Cargar envs para interpolación (POSTGRES_VOLUME, TAGS, etc)
set -a
if [ -f "$compose_env" ]; then . "$compose_env"; fi
if [ -f "$deploy_env" ]; then . "$deploy_env"; fi
set +a

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "===== ${ts} | ${LABEL} ====="
  echo "POSTGRES_VOLUME=${POSTGRES_VOLUME:-<unset>}"

  echo "--- pgbackrest info ---"
  docker compose -f "$compose_file" exec -T "$pgbackrest_service" pgbackrest-env \
    --stanza="$STANZA" --config="$pgbr_conf" \
    info </dev/null

  echo "--- pgbackrest check ---"
  docker compose -f "$compose_file" exec -T "$pgbackrest_service" pgbackrest-env \
    --stanza="$STANZA" --config="$pgbr_conf" \
    check </dev/null

  echo
} >> "${state_dir}/pgbackrest-info.log"
