#!/usr/bin/env bash

# Load shared config for pgBackRest ops scripts.
# Caller must pass its script directory.
load_ops_config() {
  local script_dir="${1:-}"
  local repo_root=""
  local default_config=""
  local config_file=""

  [ -n "$script_dir" ] || return 0

  repo_root="$(cd "${script_dir}/.." && pwd)"
  default_config="${repo_root}/config/ops.env"
  config_file="${PGBR_OPS_CONFIG:-$default_config}"

  if [ -f "$config_file" ]; then
    # shellcheck disable=SC1090
    . "$config_file"
  fi
}
