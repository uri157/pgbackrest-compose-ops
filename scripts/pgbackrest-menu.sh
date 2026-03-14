#!/usr/bin/env bash
# scripts/pgbackrest-menu.sh
# Minimal interactive menu wrapper for pgbackrest-ops.sh (+ restore + promote)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
RESTORE_VOLUME_PREFIX="${RESTORE_VOLUME_PREFIX:-pgrestore_}"

OPS="${SCRIPT_DIR}/pgbackrest-ops.sh"
RESTORE_NEW_VOL="${SCRIPT_DIR}/pgbackrest-restore-new-volume.sh"
SWITCH_VOL="${SCRIPT_DIR}/postgres-switch-volume.sh"
DELETE_VOL="${SCRIPT_DIR}/postgres-delete-volume.sh"

if [ ! -f "$OPS" ]; then
  echo "ERROR: Missing ops script: $OPS" >&2
  echo "Put pgbackrest-ops.sh next to this menu (scripts/pgbackrest-ops.sh)." >&2
  exit 1
fi

# Ensure executability (best-effort)
if [ ! -x "$OPS" ]; then
  chmod +x "$OPS" 2>/dev/null || true
fi
if [ -f "$RESTORE_NEW_VOL" ] && [ ! -x "$RESTORE_NEW_VOL" ]; then
  chmod +x "$RESTORE_NEW_VOL" 2>/dev/null || true
fi
if [ -f "$SWITCH_VOL" ] && [ ! -x "$SWITCH_VOL" ]; then
  chmod +x "$SWITCH_VOL" 2>/dev/null || true
fi
if [ -f "$DELETE_VOL" ] && [ ! -x "$DELETE_VOL" ]; then
  chmod +x "$DELETE_VOL" 2>/dev/null || true
fi

read_default() {
  local prompt="$1"
  local def="${2:-}"
  local val=""
  if [ -n "$def" ]; then
    read -r -p "${prompt} [${def}]: " val
    echo "${val:-$def}"
  else
    read -r -p "${prompt}: " val
    echo "$val"
  fi
}

pause() {
  read -r -p "Press Enter to continue..." _ || true
}

header() {
  echo
  echo "========================================"
  echo " pgBackRest Ops Menu"
  echo "========================================"
}

show_help() {
  cat <<'HELP'
pgBackRest Ops Menu (interactive)

This script is a wrapper around:
- scripts/pgbackrest-ops.sh
- scripts/pgbackrest-restore-new-volume.sh (optional, restore into a new Docker volume)
- scripts/postgres-switch-volume.sh        (optional, promote restored volumes)
- scripts/postgres-delete-volume.sh        (optional, delete Docker volumes by name)

What each option does:
  1) Snapshot (backup)
     - Creates a new pgBackRest backup (type depends on your ops script/config).
     - You can give it a label to easily identify it later.

  2) List backups
     - Shows existing backups in the repository (what you can restore to).

  3) List restore points
     - Shows restore points logged on the host (from state/restorepoints.log).

  4) Create restore point (Postgres)
     - Creates a Postgres restore point (pg_create_restore_point) and logs it.

  5) Show last logs
     - Prints tail of host-side logs (restorepoints, pgbackrest info, restores, volume switches).

  6) Self-check
     - Runs a lightweight check to confirm the ops script can run.

  7) Restore backup to NEW volume (parallel restore)
     - Calls scripts/pgbackrest-restore-new-volume.sh restoring into a brand new Docker volume.
     - Lets you choose ONE restore mode:
         (a) --latest
         (b) --backup <backup_set>
         (c) --time <timestamp>          (PITR)
         (d) --restore-point <name>      (PITR)
     - This does NOT change production automatically.

  8) Switch production Postgres volume (promote a restored volume)
     - Calls scripts/postgres-switch-volume.sh to change POSTGRES_VOLUME in env/.env.compose
       and restart the stack.
     - Optionally can auto-stop the shadow stack that is using the target volume (recommended).

  9) List Postgres Docker volumes
     - Calls scripts/postgres-list-volumes.sh to show known Postgres-related volumes.

 10) Delete Postgres Docker volume by name
     - Calls scripts/postgres-delete-volume.sh --name <volume>.
     - Refuses to delete current production volume by default.
     - Refuses to delete in-use volumes unless force is explicitly requested in the script.

Usage:
  bash scripts/pgbackrest-menu.sh

Debug:
  bash -x scripts/pgbackrest-menu.sh
HELP
}

# Best-effort: locate state dir the same way we used in deploy.
guess_state_dir() {
  local deploy_dir="$DEPLOY_DIR"
  if [ -d "${deploy_dir}/state" ]; then
    echo "${deploy_dir}/state"
    return 0
  fi
  local repo_root
  repo_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
  if [ -d "${repo_root}/state" ]; then
    echo "${repo_root}/state"
    return 0
  fi
  echo ""
}

run_ops() {
  # shellcheck disable=SC2068
  bash "$OPS" "$@"
}

run_restore_new_volume() {
  if [ ! -f "$RESTORE_NEW_VOL" ]; then
    echo "ERROR: Missing script: $RESTORE_NEW_VOL" >&2
    echo "Add scripts/pgbackrest-restore-new-volume.sh to enable parallel restore." >&2
    return 1
  fi

  local new_vol_default=""
  local new_vol=""
  local mode_choice=""
  local backup_id=""
  local pitr_time=""
  local pitr_rp=""
  local cmd=()

  new_vol_default="${RESTORE_VOLUME_PREFIX}$(date -u +%Y%m%dT%H%M%SZ)"
  new_vol="$(read_default "New Docker volume name (will be created)" "$new_vol_default")"
  if [ -z "${new_vol}" ]; then
    echo "No volume provided."
    return 1
  fi

  echo
  echo "Restore mode (pick ONE):"
  echo "  1) Latest backup             (--latest)"
  echo "  2) Specific backup set       (--backup <backup_set>)"
  echo "  3) PITR by timestamp         (--time <timestamp>)"
  echo "  4) PITR by restore point     (--restore-point <name>)"
  echo
  mode_choice="$(read_default "Choose (1/2/3/4)" "2")"

  case "${mode_choice}" in
    1)
      cmd=( bash "$RESTORE_NEW_VOL" --latest --new-volume "$new_vol" )
      ;;
    2)
      backup_id="$(read_default "Backup ID to restore (example: 20260128-064946F_20260202-043005D)" "")"
      if [ -z "${backup_id}" ]; then
        echo "No backup id provided."
        return 1
      fi
      cmd=( bash "$RESTORE_NEW_VOL" --backup "$backup_id" --new-volume "$new_vol" )
      ;;
    3)
      echo
      echo "Timestamp format example: 2026-02-02 04:35:29+00 (UTC recommended)"
      pitr_time="$(read_default "Target timestamp" "")"
      if [ -z "$pitr_time" ]; then
        echo "No timestamp provided."
        return 1
      fi
      cmd=( bash "$RESTORE_NEW_VOL" --time "$pitr_time" --new-volume "$new_vol" )
      ;;
    4)
      pitr_rp="$(read_default "Restore point name (exact)" "")"
      if [ -z "$pitr_rp" ]; then
        echo "No restore point provided."
        return 1
      fi
      cmd=( bash "$RESTORE_NEW_VOL" --restore-point "$pitr_rp" --new-volume "$new_vol" )
      ;;
    *)
      echo "Invalid choice: ${mode_choice}"
      return 1
      ;;
  esac

  echo
  echo "About to run:"
  printf '  '; printf '%q ' "${cmd[@]}"; printf '\n'
  echo
  echo "This should restore into a NEW volume without touching production."
  echo

  local confirm=""
  confirm="$(read_default "Type 'restore' to confirm" "")"
  if [ "${confirm}" != "restore" ]; then
    echo "Cancelled."
    return 0
  fi

  echo
  "${cmd[@]}"
}

run_switch_volume() {
  if [ ! -f "$SWITCH_VOL" ]; then
    echo "ERROR: Missing script: $SWITCH_VOL" >&2
    echo "Add scripts/postgres-switch-volume.sh to enable volume switching." >&2
    return 1
  fi

  local new_vol=""
  local confirm=""
  local auto_stop="N"

  new_vol="$(read_default "Target Docker volume name (promote to prod)" "")"
  if [ -z "${new_vol}" ]; then
    echo "No volume provided."
    return 1
  fi

  echo
  echo "About to run: $SWITCH_VOL --to \"$new_vol\""
  echo "This will update env/.env.compose and restart the stack."
  echo

  auto_stop="$(read_default "Auto-stop shadow stacks using this volume? (y/N)" "N")"
  echo

  confirm="$(read_default "Type 'switch' to confirm" "")"
  if [ "${confirm}" != "switch" ]; then
    echo "Cancelled."
    return 0
  fi

  echo
  if [[ "${auto_stop}" =~ ^[Yy]$ ]]; then
    bash "$SWITCH_VOL" --to "$new_vol" --stop-shadow
  else
    bash "$SWITCH_VOL" --to "$new_vol"
  fi
}

run_delete_volume() {
  if [ ! -f "$DELETE_VOL" ]; then
    echo "ERROR: Missing script: $DELETE_VOL" >&2
    echo "Add scripts/postgres-delete-volume.sh to enable volume deletion." >&2
    return 1
  fi

  local vol=""
  vol="$(read_default "Docker volume name to delete" "")"
  if [ -z "${vol}" ]; then
    echo "No volume provided."
    return 1
  fi

  echo
  echo "Running: $DELETE_VOL --name \"$vol\""
  bash "$DELETE_VOL" --name "$vol"
}

main_menu() {
  while true; do
    header
    echo "1) Snapshot (backup)"
    echo "2) List backups"
    echo "3) List restore points"
    echo "4) Create restore point (Postgres)"
    echo "5) Show last logs"
    echo "6) Self-check"
    echo "7) Restore backup to NEW volume (parallel restore)"
    echo "8) Switch production Postgres volume (promote restored volume)"
    echo "9) List Postgres Docker volumes"
    echo "10) Delete Postgres Docker volume by name"
    echo "h) Help"
    echo "q) Quit"
    echo
    read -r -p "Select an option: " choice

    case "${choice:-}" in
      1)
        label="$(read_default "Label for snapshot" "manual_snapshot_$(date -u +%Y%m%dT%H%M%SZ)")"
        echo
        echo "Running: $OPS snapshot --label \"$label\""
        run_ops snapshot --label "$label"
        pause
        ;;
      2)
        echo
        echo "Running: $OPS list-backups"
        run_ops list-backups
        pause
        ;;
      3)
        last="$(read_default "How many entries (last N)" "50")"
        echo
        echo "Running: $OPS list-restorepoints --last $last"
        run_ops list-restorepoints --last "$last"
        pause
        ;;
      4)
        label="$(read_default "Restore point label" "manual_rp_$(date -u +%Y%m%dT%H%M%SZ)")"
        echo
        echo "Running: $OPS create-restorepoint --label \"$label\""
        run_ops create-restorepoint --label "$label"
        pause
        ;;
      5)
        state_dir="$(guess_state_dir)"
        echo
        if [ -z "$state_dir" ]; then
          echo "No state directory found (expected ${DEPLOY_DIR}/state or ./state)." >&2
          echo "If you use a different location, open your logs manually." >&2
          pause
          continue
        fi

        echo "State dir: $state_dir"
        echo
        for f in restorepoints.log pgbackrest-info.log restores.log volume-switches.log; do
          path="${state_dir}/${f}"
          echo "---- tail: ${path} ----"
          if [ -f "$path" ]; then
            tail -n 80 "$path" || true
          else
            echo "(missing)"
          fi
          echo
        done
        pause
        ;;
      6)
        echo
        echo "Running: $OPS help (sanity check)"
        set +e
        run_ops help
        rc=$?
        if [ $rc -ne 0 ]; then
          run_ops --help || true
        fi
        set -e
        pause
        ;;
      7)
        echo
        run_restore_new_volume || true
        pause
        ;;
      8)
        echo
        run_switch_volume || true
        pause
        ;;
      9)
        echo
        echo "Running: ${SCRIPT_DIR}/postgres-list-volumes.sh"
        bash "${SCRIPT_DIR}/postgres-list-volumes.sh"
        pause
        ;;
      10)
        echo
        run_delete_volume || true
        pause
        ;;
      h|H|help|HELP)
        echo
        show_help
        pause
        ;;
      q|Q|quit|exit)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "Invalid option."
        pause
        ;;
    esac
  done
}

main_menu
