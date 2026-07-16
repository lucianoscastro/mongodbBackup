#!/bin/bash
# Driver MongoDB. Contrato comum a todos os drivers:
#
#   mongo.sh enabled                          exit 0 se o engine está configurado
#   mongo.sh info                             2 linhas: rótulo e host:porta (para a UI)
#   mongo.sh backup                           ciclo completo (todas as bases + S3 + retenção)
#   mongo.sh restore <db> <arquivo> [--drop]  restaura a partir de um .tar local
#
# Habilitado quando MONGO_URI está definida.
set -euo pipefail
source /usr/local/bin/s3.sh
source /usr/local/bin/lib.sh

ENGINE=mongo
BACKUP_DIR="${BACKUP_DIR:-/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-3}"
EXCLUDE_DBS="${EXCLUDE_DBS:-admin config local}"
MONGO_URI="${MONGO_URI:-}"
# Teto de tempo do dump: com o cluster fora do ar o mongodump fica pendurado
# indefinidamente (nem o serverSelectionTimeoutMS da URI o interrompe), e sem
# isso o daemon travaria para sempre em vez de reagendar o ciclo.
DUMP_TIMEOUT_MINUTES="${DUMP_TIMEOUT_MINUTES:-60}"

enabled() { [ -n "$MONGO_URI" ]; }

info() {
    echo "MongoDB"
    # host:porta sem esquema nem credenciais; host sem porta = mongodb+srv
    echo "$MONGO_URI" | sed -E 's#^mongodb(\+srv)?://##; s#^[^@/]*@##; s#[/?].*$##'
}

run_backup() {
    local timestamp staging failed=0
    timestamp=$(date +%Y%m%d_%H%M%S)
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' RETURN

    echo "[Mongo] Iniciando ciclo em $(date -Iseconds)"

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
            echo "[Mongo] ERRO: mongodump excedeu ${DUMP_TIMEOUT_MINUTES}min e foi abortado." >&2
            return 1
            ;;
        *)
            echo "[Mongo] ERRO: mongodump falhou (exit $rc)." >&2
            return 1
            ;;
    esac

    local dbs=()
    for dir in "$staging"/*/; do
        [ -d "$dir" ] || continue
        local db
        db=$(basename "$dir")
        # shellcheck disable=SC2086
        is_excluded "$db" $EXCLUDE_DBS || dbs+=("$db")
    done

    if [ "${#dbs[@]}" -eq 0 ]; then
        echo "[Mongo] ERRO: nenhuma base encontrada no cluster." >&2
        return 1
    fi

    for db in "${dbs[@]}"; do
        local file="$BACKUP_DIR/$ENGINE/$db/${db}_${timestamp}.tar"
        mkdir -p "$BACKUP_DIR/$ENGINE/$db"

        # tar sem compressão: o mongodump --gzip já comprimiu cada coleção.
        if ! tar -cf "$file" -C "$staging" "$db" || [ ! -s "$file" ]; then
            echo "[Mongo] ERRO: falha ao empacotar a base $db" >&2
            rm -f "$file"
            failed=1
            continue
        fi

        echo "[Mongo] OK: $file ($(du -h "$file" | cut -f1))"

        if s3_enabled; then
            s3_upload "$file" "$(s3_key "$ENGINE/$db/$(basename "$file")")" || failed=1
        fi

        prune_backups "$BACKUP_DIR/$ENGINE/$db" "$db" tar
    done

    [ "$failed" -eq 0 ] || return 1
    echo "[Mongo] Ciclo concluído em $(date -Iseconds)"
}

run_restore() {
    local db="${1:-}" archive="${2:-}"
    shift 2 || true
    local drop_args=()
    for arg in "$@"; do
        [ "$arg" = "--drop" ] && drop_args=(--drop)
    done

    [ -f "$archive" ] || { echo "[Mongo] ERRO: arquivo não encontrado: $archive" >&2; return 1; }

    local workdir
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' RETURN

    echo "[Mongo] Restaurando '$db' a partir de $archive"
    tar -xf "$archive" -C "$workdir"

    mongorestore --uri="$MONGO_URI" --gzip ${drop_args[@]+"${drop_args[@]}"} \
        --nsInclude="${db}.*" --dir="$workdir/$db" --db="$db"

    echo "[Mongo] Concluído: base '$db' restaurada."
}

cmd="${1:-}"
shift || true
case "$cmd" in
    enabled) enabled ;;
    info)    enabled && info ;;
    backup)
        enabled || { echo "[Mongo] ERRO: MONGO_URI não definida." >&2; exit 1; }
        run_backup
        ;;
    restore)
        enabled || { echo "[Mongo] ERRO: MONGO_URI não definida." >&2; exit 1; }
        [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "uso: mongo.sh restore <db> <arquivo.tar> [--drop]" >&2; exit 1; }
        run_restore "$@"
        ;;
    *) echo "uso: mongo.sh enabled|info|backup|restore" >&2; exit 1 ;;
esac
