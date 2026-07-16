#!/bin/bash
# Driver SQL Server. Mesmo contrato do mongo.sh: enabled | info | backup | restore.
#
# O BACKUP/RESTORE do SQL Server é sempre server-side: o .bak nasce no disco do
# próprio servidor. Por isso o diretório de backup do SQL Server precisa ser um
# volume montado TAMBÉM neste container:
#
#   no SQL Server:      volume em MSSQL_DIR_SERVER (padrão /var/opt/mssql/backup)
#   neste container:    o MESMO volume em MSSQL_DIR_LOCAL (padrão /mssql-backup)
#
# O driver manda o servidor gravar o .bak lá, move o arquivo para BACKUP_DIR
# e segue o mesmo fluxo dos demais engines (S3 + retenção).
#
# Habilitado quando MSSQL_HOST e MSSQL_PASSWORD estão definidas.
set -euo pipefail
source /usr/local/bin/s3.sh
source /usr/local/bin/lib.sh

ENGINE=mssql
BACKUP_DIR="${BACKUP_DIR:-/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-3}"
MSSQL_HOST="${MSSQL_HOST:-}"
MSSQL_PORT="${MSSQL_PORT:-1433}"
MSSQL_USER="${MSSQL_USER:-sa}"
MSSQL_PASSWORD="${MSSQL_PASSWORD:-}"
MSSQL_DATABASES="${MSSQL_DATABASES:-}"          # vazio = todas as bases de usuário
MSSQL_EXCLUDE_DBS="${MSSQL_EXCLUDE_DBS:-}"
MSSQL_DIR_SERVER="${MSSQL_DIR_SERVER:-/var/opt/mssql/backup}"
MSSQL_DIR_LOCAL="${MSSQL_DIR_LOCAL:-/mssql-backup}"
MSSQL_COMPRESS="${MSSQL_COMPRESS:-false}"       # COMPRESSION não existe na edição Express
MSSQL_TIMEOUT_MINUTES="${MSSQL_TIMEOUT_MINUTES:-60}"

enabled() { [ -n "$MSSQL_HOST" ] && [ -n "$MSSQL_PASSWORD" ]; }

info() {
    echo "SQL Server"
    echo "${MSSQL_HOST}:${MSSQL_PORT}"
}

# sqlrun é o nosso executor T-SQL (web/sqlrun): substitui o go-sqlcmd, que
# embutia dezenas de CVEs de dependências que nunca usamos. Ele lê a conexão
# do ambiente — a senha nunca passa pela linha de comando (ps/proc) — e sai
# com código != 0 quando o batch falha.
sql() {
    local limit
    limit=$(awk "BEGIN{printf \"%d\", $MSSQL_TIMEOUT_MINUTES * 60}")
    MSSQL_HOST="$MSSQL_HOST" MSSQL_PORT="$MSSQL_PORT" MSSQL_USER="$MSSQL_USER" \
        MSSQL_PASSWORD="$MSSQL_PASSWORD" sqlrun -t "$limit" -Q "$1"
}

list_dbs() {
    if [ -n "$MSSQL_DATABASES" ]; then
        echo "$MSSQL_DATABASES" | tr ' ' '\n'
    else
        # database_id > 4 pula master/tempdb/model/msdb; state 0 = ONLINE.
        sql "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0"
    fi
}

run_backup() {
    local timestamp failed=0
    timestamp=$(date +%Y%m%d_%H%M%S)

    [ -d "$MSSQL_DIR_LOCAL" ] || {
        echo "[MSSQL] ERRO: $MSSQL_DIR_LOCAL não existe. Monte o diretório de backup do SQL Server neste container (ver comentário no topo do driver)." >&2
        return 1
    }

    echo "[MSSQL] Iniciando ciclo em $(date -Iseconds)"

    local with_opts="INIT, FORMAT, CHECKSUM"
    [ "${MSSQL_COMPRESS,,}" = "true" ] && with_opts+=", COMPRESSION"

    local dbs=()
    local db
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        # shellcheck disable=SC2086
        is_excluded "$db" $MSSQL_EXCLUDE_DBS && continue
        if ! is_valid_dbname "$db"; then
            echo "[MSSQL] AVISO: pulando base com nome fora do padrão seguro: $db" >&2
            continue
        fi
        dbs+=("$db")
    done < <(list_dbs)

    if [ "${#dbs[@]}" -eq 0 ]; then
        echo "[MSSQL] ERRO: nenhuma base encontrada no servidor." >&2
        return 1
    fi

    for db in "${dbs[@]}"; do
        local bak="${db}_${timestamp}.bak"
        local src="$MSSQL_DIR_LOCAL/$bak"
        local dest="$BACKUP_DIR/$ENGINE/$db/$bak"

        if ! sql "BACKUP DATABASE [$db] TO DISK = N'${MSSQL_DIR_SERVER}/${bak}' WITH ${with_opts}"; then
            echo "[MSSQL] ERRO: BACKUP DATABASE falhou para a base $db" >&2
            failed=1
            continue
        fi

        # O BACKUP retornou OK mas o arquivo não está no volume local: o mount
        # não é o mesmo diretório que o servidor usou — erro de configuração.
        if [ ! -s "$src" ]; then
            echo "[MSSQL] ERRO: $bak não apareceu em $MSSQL_DIR_LOCAL. MSSQL_DIR_SERVER/MSSQL_DIR_LOCAL apontam para o mesmo volume?" >&2
            failed=1
            continue
        fi

        mkdir -p "$BACKUP_DIR/$ENGINE/$db"
        # cp+rm em vez de mv: o arquivo é de outro dono (uid do SQL Server) e
        # o mv cross-filesystem reclamaria ao preservar o ownership.
        cp "$src" "$dest"
        rm -f "$src"
        echo "[MSSQL] OK: $dest ($(du -h "$dest" | cut -f1))"

        if s3_enabled; then
            s3_upload "$dest" "$(s3_key "$ENGINE/$db/$bak")" || failed=1
        fi

        prune_backups "$BACKUP_DIR/$ENGINE/$db" "$db" bak
    done

    [ "$failed" -eq 0 ] || return 1
    echo "[MSSQL] Ciclo concluído em $(date -Iseconds)"
}

run_restore() {
    local db="$1" archive="$2"

    is_valid_dbname "$db" || { echo "[MSSQL] ERRO: nome de base inválido: $db" >&2; return 1; }
    [ -f "$archive" ] || { echo "[MSSQL] ERRO: arquivo não encontrado: $archive" >&2; return 1; }
    [ -d "$MSSQL_DIR_LOCAL" ] || {
        echo "[MSSQL] ERRO: $MSSQL_DIR_LOCAL não existe. Monte o diretório de backup do SQL Server neste container." >&2
        return 1
    }

    # O servidor só lê do próprio disco: copia o .bak para o volume compartilhado.
    # chmod explícito: o cp preserva o modo 640 com que o SQL Server cria os
    # .bak, e com dono diferente o próprio servidor não conseguiria reler.
    local staged
    staged="restore_$$_$(basename "$archive")"
    cp "$archive" "$MSSQL_DIR_LOCAL/$staged"
    chmod 0644 "$MSSQL_DIR_LOCAL/$staged"
    trap 'rm -f "$MSSQL_DIR_LOCAL/$staged"' RETURN

    echo "[MSSQL] Restaurando '$db' a partir de $archive"

    # SINGLE_USER derruba as conexões abertas; sem isso o RESTORE falha com
    # "database is in use". O MULTI_USER final roda mesmo se o RESTORE falhar,
    # para não deixar a base trancada.
    # ponytail: WITH REPLACE assume que os caminhos lógicos do .bak existem no
    # servidor de destino (mesmo servidor ou mesmo layout de disco). Restaurar
    # em instância com layout diferente exigiria RESTORE FILELISTONLY + MOVE.
    sql "IF DB_ID(N'$db') IS NOT NULL ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"

    local rc=0
    sql "RESTORE DATABASE [$db] FROM DISK = N'${MSSQL_DIR_SERVER}/${staged}' WITH REPLACE" || rc=$?

    sql "IF DB_ID(N'$db') IS NOT NULL ALTER DATABASE [$db] SET MULTI_USER" || true

    [ "$rc" -eq 0 ] || { echo "[MSSQL] ERRO: RESTORE DATABASE falhou (exit $rc)." >&2; return 1; }
    echo "[MSSQL] Concluído: base '$db' restaurada."
}

cmd="${1:-}"
shift || true
case "$cmd" in
    enabled) enabled ;;
    info)    enabled && info ;;
    backup)
        enabled || { echo "[MSSQL] ERRO: MSSQL_HOST/MSSQL_PASSWORD não definidas." >&2; exit 1; }
        run_backup
        ;;
    restore)
        enabled || { echo "[MSSQL] ERRO: MSSQL_HOST/MSSQL_PASSWORD não definidas." >&2; exit 1; }
        [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "uso: mssql.sh restore <db> <arquivo.bak>" >&2; exit 1; }
        run_restore "$1" "$2"
        ;;
    *) echo "uso: mssql.sh enabled|info|backup|restore" >&2; exit 1 ;;
esac
