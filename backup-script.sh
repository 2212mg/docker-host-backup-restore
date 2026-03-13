#!/usr/bin/env bash
# backup-script.sh
# -------------------------------------------------------------------
# Usage:
#   backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> <path1> [<path2> ...]
#
# OPTIONS:
#   -h               Show this help message and exit.
#   -s               Skip LVM/ZFS snapshot creation.
#   -x cont1,cont2   Comma-separated list of Docker container names to exclude from stop/restart.
#   -e exclude_file  File containing rsync exclude patterns.
#   -n               Dry-run mode (rsync --dry-run).
#   -b MBPS          Bandwidth limit in MB/s for rsync.
#   -p streams       Number of parallel rsync streams (default: 1).
#
# DESCRIPTION:
#   1) Optionally snapshot LVM or ZFS root filesystem.
#   2) Stop all Docker containers on remote except excludes.
#   3) Perform a full backup via rsync with a live progress bar.
#   4) Restart previously stopped containers and remove the record.
#   5) Cleanup snapshot and prune older backups/logs (keep 4).
# -------------------------------------------------------------------

set -euo pipefail

print_help() {
  cat <<EOF
Usage: backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> <path1> [<path2> ...]

Options:
  -h               Show this help message and exit.
  -s               Skip LVM/ZFS snapshot creation.
  -x cont1,cont2   Comma-separated list of Docker container names to exclude from stop/restart.
  -e exclude_file  File containing rsync exclude patterns.
  -n               Dry-run mode (rsync --dry-run).
  -b MBPS          Bandwidth limit in MB/s for rsync.
  -p streams       Number of parallel rsync streams (default: 1).

Description:
  Creates an optional LVM or ZFS snapshot of the root filesystem, stops selected
  Docker containers on the remote host, performs a full backup using rsync
  (with a live progress bar), restarts previously stopped containers,
  cleans up the snapshot, and prunes old backups and logs (keeping the 4 most recent).
EOF
}

# Early help
for arg in "$@"; do
  [[ "$arg" == "-h" ]] && { print_help; exit 0; }
done

# Defaults
SKIP_SNAP=false
EXCLUDES=()
EXCL_FILE=""
DRY_RUN=""
BWLIMIT=""
PARALLEL=1
while getopts ":hsx:e:nb:p:" opt; do
  case $opt in
    s) SKIP_SNAP=true ;;
    x) IFS=',' read -r -a EXCLUDES <<<"$OPTARG" ;;
    e) EXCL_FILE="$OPTARG" ;;
    n) DRY_RUN="--dry-run" ;;
    b) BWLIMIT="--bwlimit=$((OPTARG * 1024))" ;;
    p) PARALLEL="$OPTARG" ;;
    *) print_help; exit 1 ;;
  esac
done
shift $((OPTIND-1))

(( $# >= 4 )) || { echo "Insufficient arguments" >&2; print_help; exit 1; }
BACKUP_USER="$1"; TARGET_HOST="$2"; BACKUP_ROOT="${3%/}"; shift 3; PATHS=("$@")

HOST_DIR="$BACKUP_ROOT/$TARGET_HOST"
LOG_DIR="$HOST_DIR/logs"
mkdir -p "$HOST_DIR" "$LOG_DIR"

TS=$(date +%F-%H-%M)
LOG="$LOG_DIR/bklog_$TS.log"
STOPPED_FILE="$HOST_DIR/stopped_containers_$TS.lst"
SSH_OPTS="-o StrictHostKeyChecking=no"

# Ensure containers are restarted on exit (and remove the record file)
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

# Redirect all output to log and console
exec > >(tee -a "$LOG") 2>&1

echo "=== Backup started at $(date '+%F %T') ==="
echo "Options: skip-snap=$SKIP_SNAP, dry-run=${DRY_RUN:-no}, exclude-file=${EXCL_FILE:-none}, bwlimit=${BWLIMIT:-none}, streams=$PARALLEL, excludes=${EXCLUDES[*]:-none}"

# 1) Snapshot
SNAP="snap-$TS"
SRC="/"
if ! $SKIP_SNAP; then
  if sudo -n lvdisplay &>/dev/null; then
    sudo -n lvcreate -L1G -s -n "$SNAP" /dev/vg0/lv_root
    sudo -n mkdir -p /mnt/"$SNAP"
    sudo -n mount /dev/vg0/"$SNAP" /mnt/"$SNAP"
    SRC="/mnt/$SNAP"
  elif sudo -n zfs list &>/dev/null; then
    sudo -n zfs snapshot pool/root@"$SNAP"
    sudo -n zfs clone pool/root@"$SNAP" pool/backup/"$SNAP"
    SRC="/pool/backup/$SNAP"
  fi
else
  echo "Skipping filesystem snapshot"
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

# 3) Always full backup
DEST="$HOST_DIR/full-$TS"
mkdir -p "$DEST"

# 4) Rsync with live progress & parallelism
RS_OPTS=( -aHAX --relative --info=progress2 --delete $DRY_RUN $BWLIMIT )
[ -n "$EXCL_FILE" ] && RS_OPTS+=( --exclude-from="$EXCL_FILE" )
for ex in "${EXCLUDES[@]}"; do RS_OPTS+=( --exclude="$ex" ); done
RSYNC_BASE=( rsync "${RS_OPTS[@]}" -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" )

echo "=== Running rsync (full) at $(date '+%F %T') with up to $PARALLEL streams ==="

if (( PARALLEL > 1 )); then
  declare -a jobs=()
  for p in "${PATHS[@]}"; do
    CMD=("${RSYNC_BASE[@]}" "$BACKUP_USER@$TARGET_HOST:$SRC$p" "$DEST/")
    echo "+ ${CMD[*]} &"
    ("${CMD[@]}" && echo "=== Done $p ===") &
    jobs+=( $! )
    if (( ${#jobs[@]} >= PARALLEL )); then
      if ! wait "${jobs[0]}"; then echo "Warning: job ${jobs[0]} failed"; fi
      jobs=( "${jobs[@]:1}" )
    fi
  done
  for pid in "${jobs[@]}"; do
    if ! wait "$pid"; then echo "Warning: job $pid failed"; fi
  done
else
  CMD=( "${RSYNC_BASE[@]}" )
  for p in "${PATHS[@]}"; do CMD+=( "$BACKUP_USER@$TARGET_HOST:$SRC$p" ); done
  CMD+=( "$DEST/" )
  echo "+ ${CMD[*]}"
  "${CMD[@]}" || echo "Warning: rsync exited with code $?"
fi

# 5) Cleanup snapshot
if ! $SKIP_SNAP; then
  if [[ $SRC == /mnt/* ]]; then
    sudo -n umount "$SRC"
    sudo -n lvremove -f vg0/"$SNAP"
  else
    sudo -n zfs destroy pool/backup/"$SNAP"
  fi
fi

# 6) Prune old backups (keep 4) and corresponding logs
cd "$HOST_DIR"

# Prune backups
fulls=(full-*)
if (( ${#fulls[@]} > 4 )); then
  IFS=$'\n' sorted=( $(printf "%s\n" "${fulls[@]}" | sort) )
  unset IFS
  to_remove=( "${sorted[@]:0:${#sorted[@]}-4}" )
  for old in "${to_remove[@]}"; do rm -rf -- "$old"; done
fi

# Prune logs
logs=(logs/bklog_*.log)
if (( ${#logs[@]} > 4 )); then
  IFS=$'\n' sorted_logs=( $(printf "%s\n" "${logs[@]}" | sort) )
  unset IFS
  old_logs=( "${sorted_logs[@]:0:${#sorted_logs[@]}-4}" )
  for lf in "${old_logs[@]}"; do rm -f -- "$lf"; done
fi

echo "=== Backup finished at $(date '+%F %T') ==="
