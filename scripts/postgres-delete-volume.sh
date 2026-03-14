#!/usr/bin/env bash
set -euo pipefail

# scripts/postgres-delete-volume.sh
# Delete a Docker volume by name with basic safety checks.

usage() {
  cat <<'TXT'
Postgres Volume Delete

Delete a Docker volume by name.

USAGE:
  bash scripts/postgres-delete-volume.sh --name <volume> [options]

REQUIRED:
  --name <volume>         Docker volume name to delete

OPTIONS:
  --deploy-dir <path>     Default: repo root (or DEPLOY_DIR from config)
  --yes                   Non-interactive (no prompt)
  --force                 Force delete even if volume is in use by containers
  --allow-prod            Allow deleting current POSTGRES_VOLUME (dangerous)
  --help                  Show this help

EXAMPLES:
  bash scripts/postgres-delete-volume.sh --name pgrestore_20260210T200000Z
  bash scripts/postgres-delete-volume.sh --name my_volume --force --yes
TXT
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAME=""
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
YES=0
FORCE=0
ALLOW_PROD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --deploy-dir) DEPLOY_DIR="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --allow-prod) ALLOW_PROD=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "${NAME}" ]; then
  echo "Missing --name <volume>" >&2
  usage
  exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need docker

if ! docker volume inspect "${NAME}" >/dev/null 2>&1; then
  echo "Volume does not exist: ${NAME}" >&2
  exit 1
fi

COMPOSE_ENV="${DEPLOY_DIR}/env/.env.compose"
PROD_VOL=""
if [ -f "${COMPOSE_ENV}" ]; then
  PROD_VOL="$(grep -E '^POSTGRES_VOLUME=' "${COMPOSE_ENV}" | tail -n1 | cut -d= -f2- || true)"
fi

if [ -n "${PROD_VOL}" ] && [ "${NAME}" = "${PROD_VOL}" ] && [ "${ALLOW_PROD}" -ne 1 ]; then
  echo "Refusing to delete current production volume: ${NAME}" >&2
  echo "Rerun with --allow-prod only if you are absolutely sure." >&2
  exit 1
fi

IN_USE="$(docker ps -a --filter "volume=${NAME}" --format '{{.Names}} ({{.Status}})' | sed '/^[[:space:]]*$/d' || true)"
if [ -n "${IN_USE}" ] && [ "${FORCE}" -ne 1 ]; then
  echo "Volume is in use by container(s):" >&2
  echo "${IN_USE}" | sed 's/^/  - /' >&2
  echo "Stop/remove these containers first, or rerun with --force." >&2
  exit 1
fi

echo "About to delete Docker volume:"
echo "  Name: ${NAME}"
if [ -n "${PROD_VOL}" ] && [ "${NAME}" = "${PROD_VOL}" ]; then
  echo "  WARNING: this is current production POSTGRES_VOLUME"
fi
if [ "${FORCE}" -eq 1 ]; then
  echo "  Mode: force"
else
  echo "  Mode: normal"
fi
echo

if [ "${YES}" -ne 1 ]; then
  confirm=""
  read -r -p "Type the exact volume name to confirm deletion: " confirm
  if [ "${confirm}" != "${NAME}" ]; then
    echo "Cancelled."
    exit 0
  fi
fi

if [ "${FORCE}" -eq 1 ]; then
  docker volume rm -f "${NAME}"
else
  docker volume rm "${NAME}"
fi

echo "Deleted volume: ${NAME}"
