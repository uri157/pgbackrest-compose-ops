# pgbackrest-compose-ops

Bash toolkit for safe PostgreSQL backup/restore operations with pgBackRest in Docker Compose, including restore-to-new-volume, shadow validation, controlled cutover, and rollback-friendly workflows.

Spanish version: [README.es.md](README.es.md)

## Why This Exists

Running `pgbackrest` commands is not the hard part. The hard part is operating restores and cutovers safely in production.

This toolkit exists to standardize that operational path:

- backup and restore-point creation
- restore to a new volume (instead of touching production in place)
- shadow validation before cutover
- controlled volume switch and simple rollback

For day-to-day operations, the primary interface is the interactive menu (`scripts/pgbackrest-menu.sh`), so operators do not need to remember low-level command sequences.

## Scope

This project is intentionally opinionated for:

- Docker Compose
- a `postgres` service
- a `pgbackrest` service
- Docker volume-based `PGDATA`

It is not trying to be a universal database framework.

## Safe By Default

- Explicit confirmations for destructive actions
- Refuses deleting current production volume unless explicitly overridden
- Restore-to-new-volume workflow to avoid in-place production overwrite
- Shadow validation before promotion/cutover
- Best-effort cleanup of shadow resources on failure

## Quick Start

1. Create local config:

```bash
cp config/ops.env.example config/ops.env
```

2. Edit `config/ops.env` for your host (`DEPLOY_DIR`, `COMPOSE_FILE`, `COMPOSE_ENV`, `PGBR_STANZA`, prefixes).

3. Verify effective config:

```bash
bash scripts/pgbackrest-ops.sh show-config
```

4. Run the interactive menu:

```bash
bash scripts/pgbackrest-menu.sh
```

5. Execute operations from the menu:

- `1` snapshot backup
- `2` list backups
- `7` restore to new volume
- `8` switch production volume
- `9`/`10` inspect or delete volumes safely

## Menu-First Workflow (Recommended)

Use the menu for regular operations. It wraps restore, validation, and cutover helpers in a guided flow with confirmations.

Direct scripts are still available, but mainly for:

- automation
- non-interactive runs
- advanced troubleshooting

## Direct CLI Examples (Advanced)

Create snapshot:

```bash
bash scripts/pgbackrest-ops.sh snapshot --label "pre_deploy_$(date -u +%Y%m%dT%H%M%SZ)"
```

List backups:

```bash
bash scripts/pgbackrest-ops.sh list-backups
```

Restore latest backup into a new volume and start a shadow Postgres for validation:

```bash
bash scripts/pgbackrest-restore-new-volume.sh --latest --new-volume pgrestore_20260314T120000Z
```

Promote restored volume to production:

```bash
bash scripts/postgres-switch-volume.sh --to pgrestore_20260314T120000Z --stop-shadow
```

Rollback to previous production volume:

```bash
bash scripts/postgres-switch-volume.sh --to <previous_volume_name>
```

## Project Structure

- `config/ops.env.example`: centralized defaults
- `scripts/pgbackrest-menu.sh`: interactive operations menu
- `scripts/pgbackrest-ops.sh`: base operations (`snapshot`, `list-backups`, `create-restorepoint`)
- `scripts/pgbackrest-restore-new-volume.sh`: parallel restore + optional shadow validation
- `scripts/postgres-switch-volume.sh`: controlled production volume switch
- `scripts/postgres-delete-volume.sh`: guarded volume deletion
- `scripts/install-systemd-backups.sh`: installs/render systemd timers/services
- `systemd/pgbackrest-*.service|timer`: systemd templates

## Configuration

Scripts automatically load `config/ops.env` if it exists.

You can also use an external config file:

```bash
export PGBR_OPS_CONFIG=/absolute/path/to/ops.env
```

## systemd Automation

Install timers/services:

```bash
bash scripts/install-systemd-backups.sh
```

Useful installer variables:

- `DEPLOY_DIR`
- `SCRIPT_DST_DIR`
- `UNIT_DST_DIR`
- `SYSTEMD_UNIT_PREFIX`
- `UNIT_TEMPLATE_PREFIX` (default: `pgbackrest`)

## Requirements

- Linux + Bash
- Docker Engine
- Docker Compose v2 (`docker compose`)
- Permissions to manage Docker containers, networks, and volumes

## License

MIT. See [LICENSE](LICENSE).
