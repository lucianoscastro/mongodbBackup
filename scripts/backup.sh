#!/bin/bash
# Orquestra o ciclo de backup: roda cada driver habilitado em scripts/drivers/,
# ou só um engine se passado como argumento (backup.sh mongo).
set -euo pipefail

DRIVERS_DIR="${DRIVERS_DIR:-/usr/local/bin/drivers}"
only="${1:-}"

if [ -n "$only" ]; then
    drv="$DRIVERS_DIR/$only.sh"
    [ -x "$drv" ] || { echo "[Backup] ERRO: engine desconhecido: $only" >&2; exit 1; }
    "$drv" enabled || { echo "[Backup] ERRO: engine $only não configurado." >&2; exit 1; }
    exec "$drv" backup
fi

ran=0
failed=0
for drv in "$DRIVERS_DIR"/*.sh; do
    engine=$(basename "$drv" .sh)
    "$drv" enabled || continue
    ran=1
    "$drv" backup || { echo "[Backup] ERRO: ciclo do engine $engine falhou." >&2; failed=1; }
done

[ "$ran" -eq 1 ] || { echo "[Backup] ERRO: nenhum engine configurado (defina MONGO_URI e/ou MSSQL_HOST+MSSQL_PASSWORD)." >&2; exit 1; }
exit "$failed"
