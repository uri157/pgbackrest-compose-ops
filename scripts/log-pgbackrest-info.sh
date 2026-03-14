#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# log-pgbackrest-info.sh
# Guarda info útil de pgBackRest (backups disponibles, status, etc.)
# en logs/pgbackrest/ con timestamp.
# ------------------------------------------------------------

# Repo root = .. del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.prod.yml}"
ENV_DIR="${ENV_DIR:-$DEPLOY_DIR/env}"

COMPOSE_ENV="${COMPOSE_ENV:-$ENV_DIR/.env.compose}"
DEPLOY_ENV="${DEPLOY_ENV:-$DEPLOY_DIR/.env.deploy}"

STANZA="${STANZA:-${PGBR_STANZA:-main}}"
PGBR_CONF="${PGBR_CONF:-${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}}"
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"

LOG_DIR="${LOG_DIR:-$DEPLOY_DIR/logs/pgbackrest}"
RUN_CHECK="${RUN_CHECK:-1}"   # 1 = corre pgbackrest check (recomendado), 0 = no

# Best-effort por defecto (no rompas deploy por un log). Seteá STRICT=1 si querés que falle.
STRICT="${STRICT:-0}"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
base="$LOG_DIR/pgbackrest_${ts}"
OUT_TXT="${base}.log"
OUT_JSON="${base}.json"

mkdir -p "$LOG_DIR"

soft_fail() {
  local code="$1"
  shift || true
  echo "[WARN] $*" >&2
  if [ "$STRICT" = "1" ]; then
    exit "$code"
  fi
  return 0
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || soft_fail 127 "Falta comando '$1'"
}

need_cmd docker

# Cargar envs para interpolación de compose (POSTGRES_VOLUME, TAGS, etc.)
set -a
[ -f "$COMPOSE_ENV" ] && . "$COMPOSE_ENV" || true
[ -f "$DEPLOY_ENV" ] && . "$DEPLOY_ENV" || true
set +a

run_section() {
  local title="$1"
  shift || true
  {
    echo
    echo "============================================================"
    echo "== $title"
    echo "============================================================"
    "$@"
  } >>"$OUT_TXT" 2>&1 || soft_fail $? "Falló: $title"
}

# Header
{
  echo "== pgBackRest snapshot =="
  echo "utc: $(date -u --iso-8601=seconds 2>/dev/null || date -u)"
  echo "host: $(hostname -f 2>/dev/null || hostname)"
  echo "repo: $DEPLOY_DIR"
  if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "git: $(git -C "$DEPLOY_DIR" rev-parse --short HEAD 2>/dev/null || echo '<unknown>')"
  fi
  echo "compose_file: $COMPOSE_FILE"
  echo "compose_env:  $COMPOSE_ENV $([ -f "$COMPOSE_ENV" ] && echo '(loaded)' || echo '(missing)')"
  echo "deploy_env:   $DEPLOY_ENV $([ -f "$DEPLOY_ENV" ] && echo '(loaded)' || echo '(missing)')"
  echo "POSTGRES_VOLUME: ${POSTGRES_VOLUME:-<unset>}"
  echo "STANZA: $STANZA"
  echo "PGBR_CONF: $PGBR_CONF"
} >"$OUT_TXT" 2>&1

run_section "docker versions" docker --version
run_section "docker compose version" docker compose version

run_section "compose ps" docker compose -f "$COMPOSE_FILE" ps -a

run_section "pgbackrest info (text)" \
  docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" sh -lc \
  "pgbackrest-env --stanza='$STANZA' --config='$PGBR_CONF' info" </dev/null

# JSON si está disponible (no siempre, pero normalmente sí)
if docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" sh -lc \
  "pgbackrest-env --stanza='$STANZA' --config='$PGBR_CONF' info --output=json" </dev/null >"$OUT_JSON" 2>>"$OUT_TXT"
then
  echo "" >>"$OUT_TXT"
  echo "JSON: $OUT_JSON" >>"$OUT_TXT"
else
  rm -f "$OUT_JSON" 2>/dev/null || true
  echo "" >>"$OUT_TXT"
  echo "JSON: (no disponible o falló) ver log" >>"$OUT_TXT"
fi

if [ "$RUN_CHECK" = "1" ]; then
  run_section "pgbackrest check" \
    docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" sh -lc \
    "pgbackrest-env --stanza='$STANZA' --config='$PGBR_CONF' check" </dev/null
fi

echo "OK: log generado -> $OUT_TXT"
