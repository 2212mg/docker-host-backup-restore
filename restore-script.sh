#!/usr/bin/env bash
# restore-script.sh
# -------------------------------------------------------------------
# Usage:
#   restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> ...]
#
# OPTIONS:
#   -h               Show this help message and exit.
#   -t TIMESTAMP     Timestamp of the backup to restore (format YYYY-MM-DD-HH-MM).
#                    Defaults to latest full backup.
#   -n               Dry-run mode (rsync --dry-run).
#   -b MBPS          Bandwidth limit in MB/s for rsync.
#   -p streams       Number of parallel rsync streams (default: 1).
#   -x cont1,cont2   Comma-separated Docker container names to exclude from stop/restart.
#   -e exclude_file  File containing rsync exclude patterns for restore.
#
# DESCRIPTION:
#   1) Determine which full backup to restore (latest or specified).
#   2) Stop all Docker containers on target except excludes.
#   3) Push data via rsync from backup server to target host.
#   4) Restart previously stopped containers and remove the record.
# -------------------------------------------------------------------

set -euo pipefail

print_help() {
  cat <<EOF
Usage: restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> ...]

Options:
  -h               Show this help message and exit.
  -t TIMESTAMP     Timestamp of the backup to restore (YYYY-MM-DD-HH-MM). Defaults to latest full backup.
  -n               Dry-run mode (rsync --dry-run).
  -b MBPS          Bandwidth limit in MB/s for rsync.
  -p streams       Number of parallel rsync streams (default: 1).
  -x cont1,cont2   Comma-separated Docker container names to exclude from stop/restart.
  -e exclude_file  File containing rsync exclude patterns for restore.

If no <path1>… are given, the entire backup is restored. Otherwise only the specified paths are.
EOF
}

# Early help
for arg in "$@"; do
  [[ "$arg" == "-h" ]] && { print_help; exit 0; }
done

# Defaults
TIMESTAMP=""
DRY_RUN=""
BWLIMIT=""
PARALLEL=1
EXCLUDES=()
EXCL_FILE=""

while getopts ":ht:n b:p:x:e:" opt; do
  case $opt in
    t) TIMESTAMP="$OPTARG" ;;
    n) DRY_RUN="--dry-run" ;;
    b) BWLIMIT="--bwlimit=$((OPTARG * 1024))" ;;
    p) PARALLEL="$OPTARG" ;;
    x) IFS=',' read -r -a EXCLUDES <<<"$OPTARG" ;;
    e) EXCL_FILE="$OPTARG" ;;
    *) print_help; exit 1 ;;
  esac
done
shift $((OPTIND -1))

(( $# >= 3 )) || { echo "Insufficient arguments" >&2; print_help; exit 1; }
BACKUP_USER="$1"; TARGET_HOST="$2"; BACKUP_ROOT="${3%/}"; shift 3
# Remaining args are optional specific paths to restore
if (( $# )); then
  PATHS=("$@")
else
  PATHS=("/")  # interpret "/" as "everything under backup dir"
fi

HOST_DIR="$BACKUP_ROOT/$TARGET_HOST"
LOG_DIR="$HOST_DIR/logs"
mkdir -p "$HOST_DIR" "$LOG_DIR"

TS=$(date +%F-%H-%M)
LOG="$LOG_DIR/restore_$TS.log"
STOPPED_FILE="$HOST_DIR/restore_stopped_${TS}.lst"
SSH_OPTS="-i $HOME/.ssh/id_rsa -o StrictHostKeyChecking=no"

# On exit, restart containers and delete the record
restart_containers() {
  if [[ -s "$STOPPED_FILE" ]]; then
    echo "=== Restarting containers at $(date '+%F %T') ==="
    mapfile -t STOPPED < "$STOPPED_FILE"
    for c in "${STOPPED[@]}"; do
      echo "Starting $c"
      if ! ssh $SSH_OPTS $BACKUP_USER@$TARGET_HOST sudo -n docker start "$c"; then
        echo "Error: failed to start $c" >&2
      fi
    done
    rm -f "$STOPPED_FILE"
  fi
}
trap restart_containers EXIT

# Log to both console and logfile
exec > >(tee -a "$LOG") 2>&1

echo "=== Restore started at $(date '+%F %T') ==="
echo "Options: timestamp=${TIMESTAMP:-latest}, dry-run=${DRY_RUN:-no}, bwlimit=${BWLIMIT:-none}, streams=$PARALLEL, excludes=${EXCLUDES[*]:-none}, exclude-file=${EXCL_FILE:-none}"
echo "Paths to restore: ${PATHS[*]}"

# 1) Determine source backup directory
if [[ -n "$TIMESTAMP" ]]; then
  SRC_DIR="$HOST_DIR/full-$TIMESTAMP"
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: backup '$SRC_DIR' not found" >&2
    exit 1
  fi
else
  # find latest full-*
  mapfile -t ALL_FULLS < <(printf '%s\n' "$HOST_DIR"/full-* | sort)
  if (( ${#ALL_FULLS[@]} == 0 )); then
    echo "Error: no full backups found in $HOST_DIR" >&2
    exit 1
  fi
  SRC_DIR="${ALL_FULLS[-1]}"
fi

# 2) Stop Docker containers & record
: > "$STOPPED_FILE"
mapfile -t RUNNING < <(ssh $SSH_OPTS $BACKUP_USER@$TARGET_HOST sudo -n docker ps --format '{{.Names}}')
for c in "${RUNNING[@]}"; do
  skip=false
  for ex in "${EXCLUDES[@]}"; do
    [[ "$c" == "$ex" || "$c" == *"$ex"* ]] && { skip=true; break; }
  done
  if ! $skip; then
    echo "Stopping $c"
    if ssh $SSH_OPTS $BACKUP_USER@$TARGET_HOST sudo -n docker stop "$c"; then
      echo "$c" >> "$STOPPED_FILE"
    fi
  else
    echo "Skipping $c"
  fi
done

# 3) Rsync from backup to target
RS_OPTS=( -aHAX --relative --info=progress2 $DRY_RUN $BWLIMIT )
[ -n "$EXCL_FILE" ] && RS_OPTS+=( --exclude-from="$EXCL_FILE" )
for ex in "${EXCLUDES[@]}"; do RS_OPTS+=( --exclude="$ex" ); done
RSYNC_BASE=( rsync "${RS_OPTS[@]}" -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" )

echo "=== Running rsync restore at $(date '+%F %T') with up to $PARALLEL streams ==="

if (( PARALLEL > 1 )); then
  declare -a jobs=()
  for p in "${PATHS[@]}"; do
    # Source is local backup dir; dest is remote target host
    CMD=( "${RSYNC_BASE[@]}" "$SRC_DIR$p" "$BACKUP_USER@$TARGET_HOST:$p" )
    echo "+ ${CMD[*]} &"
    ("${CMD[@]}" && echo "=== Done $p ===") &
    jobs+=( $! )
    if (( ${#jobs[@]()
