#!/bin/bash
# Full + incremental physical backups with Percona XtraBackup.
# Restore a chain with: xtrabackup --prepare --apply-log-only on full, then
# each incHHMMSS with --incremental-dir, then a final --prepare.
set -o pipefail

echo "========================================================="
echo " Iniciando o Agendador de Backups Percona XtraBackup"
echo "========================================================="
echo ""

BACKUP_INTERVAL="${BACKUP_INTERVAL:-4h}"

if [ -z "${BACKUP_HOST}" ]; then
    echo "BACKUP_HOST is not set"
    exit 1
fi

echo "Host: ${BACKUP_HOST}"
echo "Interval: ${BACKUP_INTERVAL}"
echo ""

# =========================================================================
# WAIT FOR BACKUP_HOST (replaces depends_on, see compose.yaml)
# =========================================================================
wait_for_host() {
    until MYSQL_PWD="${BACKUP_HOST_PASSWORD}" mysqladmin ping --host="${BACKUP_HOST}" --user="${BACKUP_HOST_USER}" --connect-timeout=5 >/dev/null 2>&1; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')][${BACKUP_HOST}] waiting for the database to be reachable..."
        sleep 10
    done
}

# =========================================================================
# BACKUP FUNCTION (full when no base dir is given, incremental otherwise)
# =========================================================================
run_backup() {
    local type="$1"
    local target_dir="$2"
    local log_file="$3"
    local base_dir="$4"

    local incremental=()
    [ -n "${base_dir}" ] && incremental=(--incremental-basedir="${base_dir}")

    local start_time=$(date +%s)
    echo "[$(date -d "@${start_time}" '+%Y-%m-%d %H:%M:%S')][${BACKUP_HOST}][${type} backup][start ${type} backup${base_dir:+, base ${base_dir}}]" | tee -a "${log_file}"

    xtrabackup --backup \
        --target-dir="${target_dir}" \
        "${incremental[@]}" \
        --host="${BACKUP_HOST}" \
        --user="${BACKUP_HOST_USER}" \
        --password="${BACKUP_HOST_PASSWORD}" 2>&1 | tee -a "${log_file}"
    local status=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    if [ ${status} -eq 0 ]; then
        echo "[$(date -d "@${end_time}" '+%Y-%m-%d %H:%M:%S')][${BACKUP_HOST}][${type} backup][finished in ${duration} seconds]" | tee -a "${log_file}"
    else
        # never leave a broken backup behind: it would become the next base
        rm -rf "${target_dir}"
        echo "[$(date -d "@${end_time}" '+%Y-%m-%d %H:%M:%S')][${BACKUP_HOST}][${type} backup][FAILED after ${duration} seconds, removed ${target_dir}]" | tee -a "${log_file}"
    fi
    echo "" | tee -a "${log_file}"
}

# =========================================================================
# MAIN LOOP (TIME ORCHESTRATION)
# =========================================================================
while true; do
    wait_for_host

    TODAY=$(date +%F)

    # one folder per host: incrementals must never mix different servers
    TODAY_FOLDER="/backups/mysql/${BACKUP_HOST}/${TODAY}"
    LOG_FILE="${TODAY_FOLDER}/.log"

    mkdir -p "${TODAY_FOLDER}"
    touch "${LOG_FILE}"

    # no full backup today -> full, else incremental on top of the latest one
    if [ ! -d "${TODAY_FOLDER}/full" ]; then
        run_backup full "${TODAY_FOLDER}/full" "${LOG_FILE}"
    else
        BASE_DIR=$(ls -1d "${TODAY_FOLDER}"/full "${TODAY_FOLDER}"/inc* 2>/dev/null | sort | tail -n 1)
        run_backup incremental "${TODAY_FOLDER}/inc$(date '+%H%M%S')" "${LOG_FILE}" "${BASE_DIR}"
    fi

    sleep "${BACKUP_INTERVAL}"
done
