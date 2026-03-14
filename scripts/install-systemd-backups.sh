#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
UNIT_SRC_DIR="${UNIT_SRC_DIR:-${SCRIPT_DIR}/../systemd}"
UNIT_TEMPLATE_PREFIX="${UNIT_TEMPLATE_PREFIX:-pgbackrest}"
SYSTEMD_UNIT_PREFIX="${SYSTEMD_UNIT_PREFIX:-pgbackrest}"
UNIT_DST_DIR="${UNIT_DST_DIR:-/etc/systemd/system}"
SCRIPT_SRC_DIR="${SCRIPT_SRC_DIR:-${SCRIPT_DIR}}"
SCRIPT_DST_DIR="${SCRIPT_DST_DIR:-${DEPLOY_DIR}/scripts}"

if [ ! -d "$UNIT_SRC_DIR" ]; then
  echo "Missing unit source dir: $UNIT_SRC_DIR" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found; cannot install timers" >&2
  exit 1
fi

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    echo "Need root or sudo to install systemd units" >&2
    exit 1
  fi
fi

unit_names=(daily weekly maintenance)

"${SUDO[@]}" mkdir -p "$SCRIPT_DST_DIR" "${SCRIPT_DST_DIR}/lib"

render_unit() {
  local src="$1"
  local dst="$2"
  local esc_deploy esc_script esc_prefix

  esc_deploy="$(printf '%s' "$DEPLOY_DIR" | sed 's/[&|]/\\&/g')"
  esc_script="$(printf '%s' "$SCRIPT_DST_DIR" | sed 's/[&|]/\\&/g')"
  esc_prefix="$(printf '%s' "$SYSTEMD_UNIT_PREFIX" | sed 's/[&|]/\\&/g')"

  sed \
    -e "s|__DEPLOY_DIR__|${esc_deploy}|g" \
    -e "s|__SCRIPT_DST_DIR__|${esc_script}|g" \
    -e "s|__UNIT_PREFIX__|${esc_prefix}|g" \
    "$src" | "${SUDO[@]}" tee "$dst" >/dev/null
}

for name in "${unit_names[@]}"; do
  for kind in service timer; do
    src="${UNIT_SRC_DIR}/${UNIT_TEMPLATE_PREFIX}-${name}.${kind}"
    dst="${UNIT_DST_DIR}/${SYSTEMD_UNIT_PREFIX}-${name}.${kind}"
    if [ ! -f "$src" ]; then
      echo "Missing unit template: $src" >&2
      exit 1
    fi
    render_unit "$src" "$dst"
  done
done

script_paths=(
  pgbackrest-backup.sh
  pgbackrest-maintenance.sh
  lib/load-ops-config.sh
)

for relpath in "${script_paths[@]}"; do
  src="$SCRIPT_SRC_DIR/$relpath"
  dst="$SCRIPT_DST_DIR/$relpath"
  if [ ! -f "$src" ]; then
    echo "Missing script: $src" >&2
    exit 1
  fi
  "${SUDO[@]}" mkdir -p "$(dirname "$dst")"
  src_real="$src"
  dst_real="$dst"
  if command -v realpath >/dev/null 2>&1; then
    src_real="$(realpath "$src")"
    dst_real="$(realpath -m "$dst")"
  fi
  if [ "$src_real" != "$dst_real" ]; then
    "${SUDO[@]}" cp -f "$src" "$dst"
  fi
  "${SUDO[@]}" chmod 0755 "$dst"
done

"${SUDO[@]}" systemctl daemon-reload
"${SUDO[@]}" systemctl enable --now \
  "${SYSTEMD_UNIT_PREFIX}-daily.timer" \
  "${SYSTEMD_UNIT_PREFIX}-weekly.timer" \
  "${SYSTEMD_UNIT_PREFIX}-maintenance.timer"

"${SUDO[@]}" systemctl list-timers --all | grep -E "${SYSTEMD_UNIT_PREFIX}-(daily|weekly|maintenance)" || true
