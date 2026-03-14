# pgbackrest-compose-ops

Toolkit Bash para operar backups y restores de PostgreSQL con pgBackRest en Docker Compose, priorizando seguridad operativa: restore a volumen nuevo, validación shadow, cutover controlado y rollback simple.

English version: [README.md](README.md)

## Por Qué Existe

Ejecutar comandos de `pgbackrest` no es lo más difícil. Lo realmente delicado es operar restores y cutovers de forma segura en producción.

Este toolkit existe para estandarizar ese flujo operativo:

- creación de backups y restore points
- restore a un volumen nuevo (sin tocar producción in-place)
- validación en stack shadow antes del cutover
- switch controlado de volumen y rollback simple

Para la operación diaria, la interfaz principal es el menú interactivo (`scripts/pgbackrest-menu.sh`), así evitás ejecutar secuencias manuales de comandos.

## Alcance

El proyecto está pensado para un stack concreto:

- Docker Compose
- servicio `postgres`
- servicio `pgbackrest`
- `PGDATA` sobre volúmenes Docker

No busca ser un framework universal para cualquier base de datos.

## Safe By Default

- Confirmaciones explícitas antes de acciones sensibles
- Bloqueo al borrar volumen productivo (salvo override explícito)
- Restore a volumen nuevo para evitar sobreescritura directa de producción
- Validación shadow antes de promover/cambiar volumen
- Limpieza best-effort de recursos shadow ante fallos

## Quick Start

1. Crear configuración local:

```bash
cp config/ops.env.example config/ops.env
```

2. Ajustar `config/ops.env` para tu host (`DEPLOY_DIR`, `COMPOSE_FILE`, `COMPOSE_ENV`, `PGBR_STANZA`, prefijos).

3. Verificar configuración efectiva:

```bash
bash scripts/pgbackrest-ops.sh show-config
```

4. Ejecutar menú interactivo:

```bash
bash scripts/pgbackrest-menu.sh
```

5. Ejecutar operaciones desde el menú:

- `1` snapshot backup
- `2` listar backups
- `7` restore a volumen nuevo
- `8` switch de volumen productivo
- `9`/`10` inspeccionar o borrar volúmenes con guardas

## Flujo Menu-First (Recomendado)

Usá el menú para operaciones habituales. Encapsula restore, validación y cutover en un flujo guiado con confirmaciones.

Los scripts directos siguen disponibles, pero principalmente para:

- automatización
- ejecuciones no interactivas
- troubleshooting avanzado

## Ejemplos Directos por CLI (Avanzado)

Crear snapshot:

```bash
bash scripts/pgbackrest-ops.sh snapshot --label "pre_deploy_$(date -u +%Y%m%dT%H%M%SZ)"
```

Listar backups:

```bash
bash scripts/pgbackrest-ops.sh list-backups
```

Restaurar último backup a un volumen nuevo y levantar shadow para validar:

```bash
bash scripts/pgbackrest-restore-new-volume.sh --latest --new-volume pgrestore_20260314T120000Z
```

Promover volumen restaurado a producción:

```bash
bash scripts/postgres-switch-volume.sh --to pgrestore_20260314T120000Z --stop-shadow
```

Rollback al volumen anterior:

```bash
bash scripts/postgres-switch-volume.sh --to <nombre_volumen_anterior>
```

## Estructura

- `config/ops.env.example`: defaults centralizados
- `scripts/pgbackrest-menu.sh`: menú interactivo
- `scripts/pgbackrest-ops.sh`: operaciones base (`snapshot`, `list-backups`, `create-restorepoint`)
- `scripts/pgbackrest-restore-new-volume.sh`: restore paralelo + validación shadow
- `scripts/postgres-switch-volume.sh`: switch controlado de volumen productivo
- `scripts/postgres-delete-volume.sh`: borrado de volúmenes con guardas
- `scripts/install-systemd-backups.sh`: instalación/render de timers/services
- `systemd/pgbackrest-*.service|timer`: templates systemd

## Configuración

Los scripts cargan `config/ops.env` automáticamente si existe.

También podés usar un archivo externo:

```bash
export PGBR_OPS_CONFIG=/ruta/absoluta/ops.env
```

## Automatización con systemd

Instalar timers/services:

```bash
bash scripts/install-systemd-backups.sh
```

Variables útiles del instalador:

- `DEPLOY_DIR`
- `SCRIPT_DST_DIR`
- `UNIT_DST_DIR`
- `SYSTEMD_UNIT_PREFIX`
- `UNIT_TEMPLATE_PREFIX` (default: `pgbackrest`)

## Requisitos

- Linux + Bash
- Docker Engine
- Docker Compose v2 (`docker compose`)
- Permisos para administrar contenedores, redes y volúmenes Docker

## Licencia

MIT. Ver [LICENSE](LICENSE).
