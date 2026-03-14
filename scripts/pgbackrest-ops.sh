#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# pgbackrest-ops.sh
# Operaciones básicas + menú interactivo (host-side)
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.prod.yml}"
ENV_DIR="${ENV_DIR:-$DEPLOY_DIR/env}"
COMPOSE_ENV="${COMPOSE_ENV:-$ENV_DIR/.env.compose}"
STATE_DIR="${STATE_DIR:-$DEPLOY_DIR/state}"

# Servicios (docker compose)
PG_SERVICE="${PG_SERVICE:-postgres}"
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"

# pgBackRest stanza/config
PGBR_STANZA="${PGBR_STANZA:-${STANZA:-main}}"
PGBR_CONFIG="${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"

# Backup type default (diff suele ser buen “snapshot”)
DEFAULT_BACKUP_TYPE="${DEFAULT_BACKUP_TYPE:-diff}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_paths() {
  [ -f "$COMPOSE_FILE" ] || die "No encuentro compose file en: $COMPOSE_FILE"
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/restorepoints.log" "$STATE_DIR/pgbackrest-info.log" "$STATE_DIR/restores.log" 2>/dev/null || true
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  chmod 600 "$STATE_DIR/restorepoints.log" "$STATE_DIR/pgbackrest-info.log" "$STATE_DIR/restores.log" 2>/dev/null || true
}

has_compose_env() {
  [ -f "$COMPOSE_ENV" ] && grep -qE '^POSTGRES_VOLUME=' "$COMPOSE_ENV"
}

dc() {
  # docker compose wrapper: aplica --env-file solo si existe .env.compose
  if has_compose_env; then
    docker compose --env-file "$COMPOSE_ENV" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

pg_exec() {
  # ejecuta shell dentro del contenedor postgres (sin TTY)
  dc exec -T "$PG_SERVICE" sh -lc "$1"
}

pbr_exec() {
  # ejecuta pgbackrest-env dentro del contenedor pgbackrest (sin TTY)
  dc exec -T "$PGBACKREST_SERVICE" sh -lc "pgbackrest-env --stanza=$PGBR_STANZA --config=$PGBR_CONFIG $1"
}

utc_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sanitize_label() {
  # Solo A-Za-z0-9_- y largo <= 63
  local s="$1"
  s="$(echo "$s" | tr -cd 'A-Za-z0-9_-')"
  s="$(printf '%s' "$s" | cut -c1-63)"
  [ -n "$s" ] || die "Label vacío o inválido"
  printf '%s' "$s"
}

default_label() {
  # snapshot_YYYYmmddTHHMMSSZ
  echo "snapshot_$(date -u +%Y%m%dT%H%M%SZ)"
}

require_running() {
  # asegura que postgres + pgbackrest estén arriba
  dc up -d "$PG_SERVICE" "$PGBACKREST_SERVICE" >/dev/null
}

cmd_help() {
  cat <<EOF
Uso:
  bash scripts/pgbackrest-ops.sh <comando> [args]

Comandos:
  menu
  snapshot [--label LBL] [--type full|diff|incr]
  create-restorepoint --label LBL
  list-backups
  list-restorepoints [--last N]
  show-config

Variables opcionales (si querés):
  PGBR_OPS_CONFIG
  DEPLOY_DIR, COMPOSE_FILE, COMPOSE_ENV, STATE_DIR
  PG_SERVICE, PGBACKREST_SERVICE
  PGBR_STANZA, PGBR_CONFIG
EOF
}

cmd_show_config() {
  ensure_paths
  echo "DEPLOY_DIR=$DEPLOY_DIR"
  echo "COMPOSE_FILE=$COMPOSE_FILE"
  echo "COMPOSE_ENV=$COMPOSE_ENV"
  echo "STATE_DIR=$STATE_DIR"
  echo "PG_SERVICE=$PG_SERVICE"
  echo "PGBACKREST_SERVICE=$PGBACKREST_SERVICE"
  echo "PGBR_STANZA=$PGBR_STANZA"
  echo "PGBR_CONFIG=$PGBR_CONFIG"
  echo "DEFAULT_BACKUP_TYPE=$DEFAULT_BACKUP_TYPE"
  echo
  if has_compose_env; then
    echo ".env.compose OK:"
    sed -n '1,120p' "$COMPOSE_ENV"
  else
    echo "Aviso: no detecté POSTGRES_VOLUME en $COMPOSE_ENV (igual funciona, pero no vas a poder hacer cutover por env)."
  fi
}

cmd_create_restorepoint() {
  ensure_paths
  require_running

  local label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label="${2:-}"; shift 2;;
      *) die "Arg desconocido: $1";;
    esac
  done

  [ -n "$label" ] || die "Falta --label"
  label="$(sanitize_label "$label")"

  # Ejecuta dentro del contenedor postgres, usando POSTGRES_USER/DB del contenedor.
  # Pasamos el label como env var para evitar quilombo de comillas.
  docker compose -f "$COMPOSE_FILE" exec -T \
    -e RESTORE_POINT_LABEL="$label" \
    "$PG_SERVICE" sh -c '
      set -euo pipefail
      : "${POSTGRES_USER:?missing POSTGRES_USER inside container}";
      : "${POSTGRES_DB:?missing POSTGRES_DB inside container}";
      : "${RESTORE_POINT_LABEL:?missing RESTORE_POINT_LABEL}";
      psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "SELECT pg_create_restore_point('\''${RESTORE_POINT_LABEL}'\'');" \
        -c "SELECT pg_switch_wal();"
    ' </dev/null

  local ts; ts="$(utc_ts)"
  echo "$ts | restore_point | $label" >> "$STATE_DIR/restorepoints.log"
  echo "OK: restore point creado: $label"
}


cmd_list_restorepoints() {
  ensure_paths
  local last="50"
  while [ $# -gt 0 ]; do
    case "$1" in
      --last) last="${2:-}"; shift 2;;
      *) die "Arg desconocido: $1";;
    esac
  done
  [ -f "$STATE_DIR/restorepoints.log" ] || die "No existe $STATE_DIR/restorepoints.log"
  tail -n "$last" "$STATE_DIR/restorepoints.log"
}

cmd_list_backups() {
  ensure_paths
  require_running

  # info “humano”
  echo "---- pgbackrest info (humano) ----"
  pbr_exec "info" | tee -a "$STATE_DIR/pgbackrest-info.log"
  echo "---------------------------------"
  echo "Log guardado en: $STATE_DIR/pgbackrest-info.log"
}

cmd_snapshot() {
  ensure_paths
  require_running

  local label=""
  local btype="$DEFAULT_BACKUP_TYPE"

  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label="${2:-}"; shift 2;;
      --type)  btype="${2:-}"; shift 2;;
      *) die "Arg desconocido: $1";;
    esac
  done

  if [ -z "$label" ]; then
    label="$(default_label)"
  fi
  label="$(sanitize_label "$label")"

  case "$btype" in
    full|diff|incr) : ;;
    *) die "--type inválido ($btype). Usá: full|diff|incr";;
  esac

  echo "Creando restore point: $label"
  cmd_create_restorepoint --label "$label" >/dev/null

  echo "Corriendo backup pgbackrest --type=$btype"
  pbr_exec "backup --type=$btype" | tee -a "$STATE_DIR/restores.log"

  local ts; ts="$(utc_ts)"
  echo "$ts | snapshot | label=$label | type=$btype" >> "$STATE_DIR/restores.log"

  echo "OK: snapshot listo (restorepoint + backup): $label"
  echo "Log: $STATE_DIR/restores.log"
}

# ------------------------------------------------------------
# Menú interactivo
# ------------------------------------------------------------

menu_header() {
  echo
  echo "==============================================="
  echo " pgBackRest OPS (modo menú) - $DEPLOY_DIR"
  echo "==============================================="
  echo "Stanza: $PGBR_STANZA | Compose: $COMPOSE_FILE"
  if has_compose_env; then
    echo "Compose env: $COMPOSE_ENV"
  else
    echo "Compose env: (no detectado)  [POSTGRES_VOLUME no seteado]"
  fi
  echo "State/logs: $STATE_DIR"
  echo "-----------------------------------------------"
}

prompt() {
  # prompt "texto" varname
  local msg="$1"
  local __var="$2"
  local val=""
  read -r -p "$msg" val
  printf -v "$__var" '%s' "$val"
}

cmd_menu() {
  ensure_paths

  # Chequeo de TTY
  if [ ! -t 0 ]; then
    die "Este menú necesita TTY. Usá subcomandos: snapshot, list-backups, etc."
  fi

  while true; do
    menu_header
    echo "1) Snapshot (restorepoint + backup)"
    echo "2) Crear restore point (solo restorepoint)"
    echo "3) Listar backups (pgbackrest info)"
    echo "4) Listar restore points (log)"
    echo "5) Ver configuración detectada"
    echo "0) Salir"
    echo

    local opt=""
    read -r -p "Elegí una opción: " opt
    echo

    case "$opt" in
      1)
        local lbl="" typ=""
        prompt "Label (ENTER para default): " lbl
        prompt "Backup type [full|diff|incr] (ENTER para ${DEFAULT_BACKUP_TYPE}): " typ
        [ -n "$typ" ] || typ="$DEFAULT_BACKUP_TYPE"
        if [ -n "$lbl" ]; then
          cmd_snapshot --label "$lbl" --type "$typ"
        else
          cmd_snapshot --type "$typ"
        fi
        read -r -p "ENTER para volver al menú..." _;;
      2)
        local lbl2=""
        prompt "Label (obligatorio): " lbl2
        cmd_create_restorepoint --label "$lbl2"
        read -r -p "ENTER para volver al menú..." _;;
      3)
        cmd_list_backups
        read -r -p "ENTER para volver al menú..." _;;
      4)
        local n="50"
        prompt "Cuántas líneas? (ENTER para 50): " n
        [ -n "$n" ] || n="50"
        cmd_list_restorepoints --last "$n"
        read -r -p "ENTER para volver al menú..." _;;
      5)
        cmd_show_config
        read -r -p "ENTER para volver al menú..." _;;
      0)
        echo "Chau. Volvé cuando quieras sufrir otra vez."
        break;;
      *)
        echo "Opción inválida. No muerde, pero tampoco adivino."
        sleep 1;;
    esac
  done
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) cmd_help ;;
    menu) cmd_menu ;;
    snapshot) cmd_snapshot "$@" ;;
    create-restorepoint) cmd_create_restorepoint "$@" ;;
    list-backups) cmd_list_backups ;;
    list-restorepoints) cmd_list_restorepoints "$@" ;;
    show-config) cmd_show_config ;;
    *) die "Comando desconocido: $cmd (probá help)" ;;
  esac
}

main "$@"
