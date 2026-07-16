#!/bin/bash
# Helpers compartilhados pelos drivers. Sourcear, não executar.

# Retenção local por base: mantém os MAX_BACKUPS arquivos mais novos
# <db>_<timestamp>.<ext> em <dir>. Só deve rodar depois que o backup novo
# está validado, para nunca ficar sem nenhum backup se o ciclo falhar no meio.
prune_backups() {
    local dir="$1" db="$2" ext="$3"
    # shellcheck disable=SC2010  # nomes controlados (db validado + timestamp); ls -1t é o sort por data
    ls -1t "$dir" 2>/dev/null \
        | grep -E "^${db}_[0-9]{8}_[0-9]{6}\.${ext}$" \
        | tail -n +"$((${MAX_BACKUPS:-3} + 1))" \
        | while read -r old; do
            echo "[Backup] Removendo backup antigo: $old"
            rm -f "$dir/$old"
        done
}

# is_excluded <db> <lista de exclusão separada por espaço>
is_excluded() {
    local db="$1"
    shift
    local skip
    for skip in "$@"; do
        [ "$db" = "$skip" ] && return 0
    done
    return 1
}

# Nomes de base viram caminhos de arquivo e entram em comandos SQL entre
# colchetes — validar aqui é a fronteira que evita path traversal e injeção.
is_valid_dbname() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}
