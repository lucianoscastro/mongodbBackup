#!/bin/bash
# Faz o dump de todas as bases do cluster, um arquivo por base em $BACKUP_DIR/<db>/,
# e (opcionalmente) envia cada arquivo para o S3.
set -euo pipefail
source /usr/local/bin/s3.sh

BACKUP_DIR="${BACKUP_DIR:-/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-3}"
EXCLUDE_DBS="${EXCLUDE_DBS:-admin config local}"
S3_PREFIX="${S3_PREFIX:-mongo}"
# Teto de tempo do dump: com o cluster fora do ar o mongodump fica pendurado
# indefinidamente (nem o serverSelectionTimeoutMS da URI o interrompe), e sem
# isso o daemon travaria para sempre em vez de reagendar o ciclo.
DUMP_TIMEOUT_MINUTES="${DUMP_TIMEOUT_MINUTES:-60}"

: "${MONGO_URI:?MONGO_URI não definida}"

is_excluded() {
    local db="$1"
    for skip in $EXCLUDE_DBS; do
        [ "$db" = "$skip" ] && return 0
    done
    return 1
}

# Retenção local por base. Só roda depois que o dump novo está validado,
# para nunca ficar sem nenhum backup se o ciclo falhar no meio.
prune() {
    local db="$1"
    ls -1t "$BACKUP_DIR/$db" 2>/dev/null \
        | grep -E "^${db}_[0-9]{8}_[0-9]{6}\.tar$" \
        | tail -n +"$((MAX_BACKUPS + 1))" \
        | while read -r old; do
            echo "[Backup] Removendo backup antigo: $old"
            rm -f "$BACKUP_DIR/$db/$old"
        done
}

run_backup() {
    local timestamp staging failed=0
    timestamp=$(date +%Y%m%d_%H%M%S)
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' RETURN

    echo "[Backup] Iniciando ciclo em $(date -Iseconds)"

    # Sem --db, o mongodump descobre e dumpa todas as bases do cluster —
    # é assim que a lista de bases sai de graça, sem precisar do mongosh
    # (Node.js, ~200 MB, que era morto por OOM na VPS).
    # Em segundos: o timeout do busybox não aceita fração de minuto ("0.5m").
    # -k: o mongodump ignora SIGTERM enquanto procura o servidor, então é
    # preciso escalar para SIGKILL — sem isso um cluster que aceita a conexão
    # mas nunca responde penduraria o daemon para sempre.
    local rc=0 limit
    limit=$(awk "BEGIN{printf \"%d\", $DUMP_TIMEOUT_MINUTES * 60}")
    timeout -k 30 "$limit" mongodump --uri="$MONGO_URI" --out="$staging" --gzip --quiet || rc=$?

    case "$rc" in
        0) ;;
        124 | 137 | 143)
            echo "[Backup] ERRO: mongodump excedeu ${DUMP_TIMEOUT_MINUTES}min e foi abortado." >&2
            return 1
            ;;
        *)
            echo "[Backup] ERRO: mongodump falhou (exit $rc)." >&2
            return 1
            ;;
    esac

    local dbs=()
    for dir in "$staging"/*/; do
        [ -d "$dir" ] || continue
        local db
        db=$(basename "$dir")
        is_excluded "$db" || dbs+=("$db")
    done

    if [ "${#dbs[@]}" -eq 0 ]; then
        echo "[Backup] ERRO: nenhuma base encontrada no cluster." >&2
        return 1
    fi

    for db in "${dbs[@]}"; do
        local file="$BACKUP_DIR/$db/${db}_${timestamp}.tar"
        mkdir -p "$BACKUP_DIR/$db"

        # tar sem compressão: o mongodump --gzip já comprimiu cada coleção.
        if ! tar -cf "$file" -C "$staging" "$db" || [ ! -s "$file" ]; then
            echo "[Backup] ERRO: falha ao empacotar a base $db" >&2
            rm -f "$file"
            failed=1
            continue
        fi

        echo "[Backup] OK: $file ($(du -h "$file" | cut -f1))"

        if s3_enabled; then
            s3_upload "$file" "${S3_PREFIX}/${db}/$(basename "$file")" || failed=1
        fi

        prune "$db"
    done

    [ "$failed" -eq 0 ] || return 1
    echo "[Backup] Ciclo concluído em $(date -Iseconds)"
}

run_backup
