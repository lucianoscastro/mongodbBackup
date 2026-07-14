#!/bin/bash
# Restaura uma base a partir de um backup local ou do S3.
#
#   restore <db> [arquivo.tar]   arquivo omitido = backup local mais recente
#   restore <db> --from-s3       baixa a key mais recente de s3://<bucket>/<prefix>/<db>/
#   restore <db> ... --drop      apaga as coleções antes de restaurar
#
# Atenção: a credencial de backup costuma ter só s3:PutObject — o download exige
# uma credencial com GetObject/ListBucket (ver README).
set -euo pipefail
source /usr/local/bin/s3.sh

BACKUP_DIR="${BACKUP_DIR:-/backups}"
S3_PREFIX="${S3_PREFIX:-mongo}"

: "${MONGO_URI:?MONGO_URI não definida}"

db="${1:-}"
[ -n "$db" ] || { echo "uso: restore <db> [arquivo.tar|--from-s3] [--drop]" >&2; exit 1; }
shift

source_arg=""
drop_args=()
for arg in "$@"; do
    case "$arg" in
        --drop) drop_args=(--drop) ;;
        *) source_arg="$arg" ;;
    esac
done

archive=""
if [ "$source_arg" = "--from-s3" ]; then
    s3_enabled || { echo "[Restore] ERRO: S3 não configurado (S3_ENABLED/S3_BUCKET)." >&2; exit 1; }

    key=$(s3_list "${S3_PREFIX}/${db}/" | sort | tail -1)
    [ -n "$key" ] || { echo "[Restore] ERRO: nenhum backup de '$db' no S3." >&2; exit 1; }

    archive="/tmp/$(basename "$key")"
    echo "[Restore] Baixando s3://${S3_BUCKET}/${key}"
    s3_download "$key" "$archive"
elif [ -n "$source_arg" ]; then
    archive="$source_arg"
    [ -f "$archive" ] || archive="$BACKUP_DIR/$db/$source_arg"
else
    archive=$(ls -1t "$BACKUP_DIR/$db"/${db}_*.tar 2>/dev/null | head -1 || true)
    [ -n "$archive" ] || { echo "[Restore] ERRO: nenhum backup local de '$db' em $BACKUP_DIR/$db." >&2; exit 1; }
fi

[ -f "$archive" ] || { echo "[Restore] ERRO: arquivo não encontrado: $archive" >&2; exit 1; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "[Restore] Restaurando '$db' a partir de $archive"
tar -xf "$archive" -C "$workdir"

mongorestore --uri="$MONGO_URI" --gzip "${drop_args[@]}" \
    --nsInclude="${db}.*" --dir="$workdir/$db" --db="$db"

echo "[Restore] Concluído: base '$db' restaurada."
