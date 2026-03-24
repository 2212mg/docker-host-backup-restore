#!/usr/bin/env bash
# restore-script.sh
# -------------------------------------------------------------------
# Usage:
#   restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]
#
# OPTIONS:
#   -h               Show this help message and exit.
#   -t TIMESTAMP     Timestamp of the backup to restore (format YYYY-MM-DD-HH-MM).
#                    Defaults to latest full backup.
#   -n               Dry-run mode (true no-disruption mode: no container stop/start, rsync --dry-run).
#   -b MBPS          Bandwidth limit in MB/s for rsync.
#   -p streams       Number of parallel rsync streams. Accepted, but forced to 1 for safety.
#   -x cont1,cont2   Comma-separated Docker container names to exclude from stop/restart.
#                    Excluded containers are NOT stopped and NOT restarted by this script.
#   -e exclude_file  File containing rsync exclude patterns for restore.
#   -P file          Absolute path to Portainer's own docker-compose.yml on the target host.
#                    When set, the script also restores additional compose files discovered
#                    inside Portainer's data area from the selected backup set.
#
# DESCRIPTION:
#   Restore data created by the current live-only backup script.
#
#   1) Determine which backup set to restore (latest or specified timestamp).
#   2) If no explicit restore paths are given:
#        - use source_list_<timestamp>.lst if present, otherwise
#        - restore the whole full-<timestamp>/ tree.
#   3) Optionally include Portainer compose files when -P is used.
#   4) Stop all running Docker containers on target except excludes.
#      (Skipped completely in dry-run mode.)
#   5) Restore data via rsync from backup storage to the target host.
#   6) Restart previously stopped containers automatically.
#
# NOTES:
#   - Restore paths, if provided, must be ABSOLUTE target paths.
#   - Excluded containers remain running; restoring into their live storage may be inconsistent.
#   - This script intentionally does NOT use --delete during restore.
#   - Requires passwordless sudo on the target for:
#       sudo -n docker ...
#       sudo -n rsync ...
#       sudo -n test ...
# -------------------------------------------------------------------

set -euo pipefail
shopt -s nullglob

print_help() {
  cat <<'EOF'
Usage:
  restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]

Options:
  -h               Show this help message and exit.
  -t TIMESTAMP     Timestamp of the backup to restore (YYYY-MM-DD-HH-MM).
                   Defaults to latest full backup.
  -n               Dry-run mode (true no-disruption mode: no container stop/start, rsync --dry-run).
  -b MBPS          Bandwidth limit in MB/s for rsync.
  -p streams       Number of parallel rsync streams (accepted, but forced to 1 for safety).
  -x cont1,cont2   Comma-separated list of Docker container names to exclude from stop/restart.
                   Excluded containers remain running during restore.
  -e exclude_file  File containing rsync exclude patterns for restore.
  -P file          Absolute path to Portainer's own docker-compose.yml on the target host.
                   When set, the script also restores additional compose files from Portainer data.

Behavior:
  - If no restore paths are given, the script restores:
      1) the exact paths listed in source_list_<timestamp>.lst, if that file exists, else
      2) the entire full-<timestamp>/ backup tree.
  - If restore paths are given, they must be absolute target paths such as:
      /etc
      /var/lib/docker/volumes
      /home/user/portainer
  - If -P is supplied, the script also includes Portainer compose files discovered
    inside Portainer's data area in the selected backup set.

Examples:
  restore-script.sh backup-user [RESTORE-TARGET-IP] ./backups

  restore-script.sh -t 2026-03-13-13-28 backup-user [RESTORE-TARGET-IP] ./backups

  restore-script.sh -x pihole backup-user [RESTORE-TARGET-IP] ./backups /etc /var/lib/docker/volumes

  restore-script.sh -n -t 2026-03-13-13-28 backup-user [RESTORE-TARGET-IP] ./backups /home/user/portainer

  restore-script.sh -P /path/to/docker-compose.yml -t 2026-03-13-13-28 backup-user [RESTORE-TARGET-IP] ./backups
EOF
}

# Early help
for arg in "$@"; do
  [[ "$arg" == "-h" ]] && { print_help; exit 0; }
done

# Defaults
TIMESTAMP=""
DRY_RUN=""
DRY_RUN_MODE=false
BWLIMIT=""
PARALLEL=1
EXCLUDES=()
EXCL_FILE=""
PORTAINER_COMPOSE_FILE=""

while getopts ":ht:nb:p:x:e:P:" opt; do
  case "$opt" in
    h) print_help; exit 0 ;;
    t) TIMESTAMP="$OPTARG" ;;
    n)
      DRY_RUN="--dry-run"
      DRY_RUN_MODE=true
      ;;
    b) BWLIMIT="--bwlimit=$((OPTARG * 1024))" ;;
    p) PARALLEL="$OPTARG" ;;
    x) IFS=',' read -r -a EXCLUDES <<< "$OPTARG" ;;
    e) EXCL_FILE="$OPTARG" ;;
    P) PORTAINER_COMPOSE_FILE="$OPTARG" ;;
    *) print_help; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

(( $# >= 3 )) || { echo "Insufficient arguments" >&2; print_help; exit 1; }

BACKUP_USER="$1"
TARGET_HOST="$2"
BACKUP_ROOT="${3%/}"
shift 3

REQUESTED_PATHS=("$@")

HOST_DIR="$BACKUP_ROOT/$TARGET_HOST"
LOG_DIR="$HOST_DIR/logs"
mkdir -p "$HOST_DIR" "$LOG_DIR"

NOW_TS=$(date +%F-%H-%M)
LOG="$LOG_DIR/restore_$NOW_TS.log"
STOPPED_FILE="$HOST_DIR/restore_stopped_$NOW_TS.lst"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

remote_ssh() {
  ssh "${SSH_OPTS[@]}" "$BACKUP_USER@$TARGET_HOST" "$@"
}

shell_quote() {
  printf "%q" "$1"
}

is_excluded() {
  local name="$1"
  local ex
  for ex in "${EXCLUDES[@]}"; do
    [[ "$name" == "$ex" || "$name" == *"$ex"* ]] && return 0
  done
  return 1
}

RESTART_DONE=false

restart_containers() {
  # True no-disruption dry-run: no start/stop at all
  if $DRY_RUN_MODE; then
    rm -f "$STOPPED_FILE"
    RESTART_DONE=true
    return 0
  fi

  if $RESTART_DONE; then
    return 0
  fi

  if [[ -s "$STOPPED_FILE" ]]; then
    echo "=== Restarting containers at $(date '+%F %T') ==="
    mapfile -t STOPPED < "$STOPPED_FILE"
    local c
    for c in "${STOPPED[@]}"; do
      echo "Starting $c"
      if ! remote_ssh "sudo -n docker start $(shell_quote "$c") >/dev/null"; then
        echo "Error: failed to start $c" >&2
      fi
    done
  fi

  rm -f "$STOPPED_FILE"
  RESTART_DONE=true
}

cleanup_on_exit() {
  local rc=$?
  restart_containers || true
  return "$rc"
}
trap cleanup_on_exit EXIT

# Log to console + logfile
exec > >(tee -a "$LOG") 2>&1

echo "=== Restore started at $(date '+%F %T') ==="
echo "Options: timestamp=${TIMESTAMP:-latest}, dry-run=${DRY_RUN:-no}, bwlimit=${BWLIMIT:-none}, streams=$PARALLEL, excludes=${EXCLUDES[*]:-none}, exclude-file=${EXCL_FILE:-none}, portainer-compose=${PORTAINER_COMPOSE_FILE:-none}"

if (( PARALLEL > 1 )); then
  echo "Warning: forcing streams=1 because concurrent restore into one target is unsafe."
  PARALLEL=1
fi

# -----------------------------------------------------------------------------
# Determine source backup set
# -----------------------------------------------------------------------------

if [[ -n "$TIMESTAMP" ]]; then
  BACKUP_TS="$TIMESTAMP"
  SRC_DIR="$HOST_DIR/full-$BACKUP_TS"
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: backup directory '$SRC_DIR' not found" >&2
    exit 1
  fi
else
  mapfile -t ALL_FULLS < <(printf '%s\n' "$HOST_DIR"/full-* | sort)
  if (( ${#ALL_FULLS[@]} == 0 )); then
    echo "Error: no full backups found in '$HOST_DIR'" >&2
    exit 1
  fi
  SRC_DIR="${ALL_FULLS[-1]}"
  BACKUP_TS="${SRC_DIR##*/full-}"
fi

SOURCE_LIST_FILE="$HOST_DIR/source_list_$BACKUP_TS.lst"
MANIFEST_FILE="$HOST_DIR/manifest_$BACKUP_TS.tsv"

echo "Selected backup set: $SRC_DIR"
if [[ -f "$SOURCE_LIST_FILE" ]]; then
  echo "Using source list metadata: $SOURCE_LIST_FILE"
else
  echo "No source list found for this backup set."
fi
if [[ -f "$MANIFEST_FILE" ]]; then
  echo "Manifest available: $MANIFEST_FILE"
fi

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

echo "=== Pre-flight checks ==="
remote_ssh "true"
remote_ssh "sudo -n docker ps >/dev/null"
remote_ssh "sudo -n rsync --version >/dev/null"

if [[ -n "$PORTAINER_COMPOSE_FILE" ]]; then
  if [[ "$PORTAINER_COMPOSE_FILE" != /* ]]; then
    echo "Error: -P requires an absolute target path to Portainer's docker-compose.yml" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Build restore path list
# -----------------------------------------------------------------------------

RESTORE_ALL=false
declare -a RESTORE_PATHS=()

if (( ${#REQUESTED_PATHS[@]} == 0 )); then
  if [[ -s "$SOURCE_LIST_FILE" ]]; then
    echo "No explicit restore paths provided; restoring paths from source list."
    mapfile -t RESTORE_PATHS < "$SOURCE_LIST_FILE"
  else
    echo "No explicit restore paths and no source list found; restoring entire backup tree."
    RESTORE_ALL=true
  fi
else
  echo "Explicit restore paths requested:"
  printf ' - %s\n' "${REQUESTED_PATHS[@]}"

  for p in "${REQUESTED_PATHS[@]}"; do
    if [[ "$p" == "/" ]]; then
      RESTORE_ALL=true
      continue
    fi
    if [[ "$p" != /* ]]; then
      echo "Skipping non-absolute restore path: $p"
      continue
    fi
    RESTORE_PATHS+=("$p")
  done
fi

# -----------------------------------------------------------------------------
# Optional: include Portainer compose files in restore set
# -----------------------------------------------------------------------------

if [[ -n "$PORTAINER_COMPOSE_FILE" && "$RESTORE_ALL" == false ]]; then
  echo "=== Including Portainer compose files in restore set ==="

  # Always include Portainer's own docker-compose.yml
  RESTORE_PATHS+=("$PORTAINER_COMPOSE_FILE")
  echo "  added Portainer compose file: $PORTAINER_COMPOSE_FILE"

  # Find a Portainer container on the target
  declare -a RUNNING_FOR_PORTAINER=()
  mapfile -t RUNNING_FOR_PORTAINER < <(remote_ssh "sudo -n docker ps --format '{{.Names}}'")

  PORTAINER_CONTAINER=""
  for c in "${RUNNING_FOR_PORTAINER[@]}"; do
    if [[ "$c" == *portainer* ]]; then
      PORTAINER_CONTAINER="$c"
      break
    fi
  done

  if [[ -z "$PORTAINER_CONTAINER" ]]; then
    echo "Warning: no running Portainer container found; cannot auto-discover Portainer-managed compose files on target." >&2
  else
    echo "  using Portainer container: $PORTAINER_CONTAINER"

    PORTAINER_DATA_SOURCE="$(
      remote_ssh "sudo -n docker inspect $(shell_quote "$PORTAINER_CONTAINER") --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{printf \"%s\" .Source}}{{end}}{{end}}'" \
        || true
    )"

    if [[ -z "$PORTAINER_DATA_SOURCE" ]]; then
      echo "Warning: could not determine Portainer data source mount (/data) from container $PORTAINER_CONTAINER" >&2
    else
      echo "  Portainer data source on target: $PORTAINER_DATA_SOURCE"

      # Look inside the selected backup set for compose files located in the Portainer data source path
      if [[ -d "$SRC_DIR/${PORTAINER_DATA_SOURCE#/}" ]]; then
        mapfile -t PORTAINER_BACKUP_COMPOSE_PATHS < <(
          find "$SRC_DIR/${PORTAINER_DATA_SOURCE#/}" -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null \
            | sed "s#^$SRC_DIR##" \
            | sort
        )

        if (( ${#PORTAINER_BACKUP_COMPOSE_PATHS[@]} > 0 )); then
          echo "  found ${#PORTAINER_BACKUP_COMPOSE_PATHS[@]} Portainer-managed compose file(s) in selected backup set"
          for p in "${PORTAINER_BACKUP_COMPOSE_PATHS[@]}"; do
            RESTORE_PATHS+=("$p")
            echo "    compose file: $p"
          done
        else
          echo "  no additional Portainer-managed compose files found in selected backup set"
        fi
      else
        echo "  Portainer data path does not exist in selected backup set: $SRC_DIR/${PORTAINER_DATA_SOURCE#/}"
      fi
    fi
  fi
fi

# Deduplicate explicit/source-list/Portainer restore paths
if ! $RESTORE_ALL; then
  if (( ${#RESTORE_PATHS[@]} == 0 )); then
    echo "No valid restore paths remain after validation."
    exit 1
  fi

  mapfile -t RESTORE_PATHS < <(printf '%s\n' "${RESTORE_PATHS[@]}" | awk '!seen[$0]++')
fi

# -----------------------------------------------------------------------------
# Validate requested restore paths against local backup set
# -----------------------------------------------------------------------------

declare -a FINAL_RESTORE_PATHS=()

if ! $RESTORE_ALL; then
  echo "=== Validating restore paths against backup set ==="
  for p in "${RESTORE_PATHS[@]}"; do
    local_src="$SRC_DIR/${p#/}"
    if [[ -e "$local_src" ]]; then
      echo "  OK: $p"
      FINAL_RESTORE_PATHS+=("$p")
    else
      echo "  MISSING IN BACKUP: $p"
    fi
  done

  if (( ${#FINAL_RESTORE_PATHS[@]} == 0 )); then
    echo "None of the requested paths exist in the selected backup set."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Stop running containers except exclusions
# -----------------------------------------------------------------------------

if $DRY_RUN_MODE; then
  echo "=== Dry-run mode: skipping container stop/start (no-disruption) ==="
else
  echo "=== Stopping non-excluded running containers ==="
  : > "$STOPPED_FILE"

  declare -a RUNNING_CONTAINERS=()
  mapfile -t RUNNING_CONTAINERS < <(remote_ssh "sudo -n docker ps --format '{{.Names}}'")

  if (( ${#RUNNING_CONTAINERS[@]} == 0 )); then
    echo "No running containers found on target."
  else
    printf 'Running: %s\n' "${RUNNING_CONTAINERS[@]}"
  fi

  for c in "${RUNNING_CONTAINERS[@]}"; do
    if is_excluded "$c"; then
      echo "Skipping stop for excluded container: $c"
      echo "Warning: if restored data belongs to $c, it will be overwritten while the container is live."
      continue
    fi

    echo "Stopping $c"
    if remote_ssh "sudo -n docker stop $(shell_quote "$c") >/dev/null"; then
      echo "$c" >> "$STOPPED_FILE"
    else
      echo "Warning: failed to stop $c; proceeding, but restore consistency may be affected." >&2
    fi
  done
fi

# -----------------------------------------------------------------------------
# Build rsync options
# -----------------------------------------------------------------------------

RS_OPTS=(
  -aHAX
  --numeric-ids
  --protect-args
  --info=progress2
)

[[ -n "$DRY_RUN" ]] && RS_OPTS+=("$DRY_RUN")
[[ -n "$BWLIMIT" ]] && RS_OPTS+=("$BWLIMIT")
[[ -n "$EXCL_FILE" ]] && RS_OPTS+=(--exclude-from="$EXCL_FILE")

SSH_RSYNC="ssh ${SSH_OPTS[*]}"

FAILED=0

echo "=== Running restore rsync at $(date '+%F %T') ==="

# -----------------------------------------------------------------------------
# Restore everything
# -----------------------------------------------------------------------------

if $RESTORE_ALL; then
  CMD=(
    rsync
    "${RS_OPTS[@]}"
    -e "$SSH_RSYNC"
    --rsync-path="sudo -n rsync"
    "$SRC_DIR"/
    "$BACKUP_USER@$TARGET_HOST:/"
  )

  echo "+ ${CMD[*]}"
  if ! "${CMD[@]}"; then
    echo "Warning: full restore rsync exited with a non-zero code" >&2
    FAILED=1
  fi

# -----------------------------------------------------------------------------
# Restore specific absolute paths
# -----------------------------------------------------------------------------

else
  for p in "${FINAL_RESTORE_PATHS[@]}"; do
    # Use /./ anchor so rsync preserves the absolute path layout beneath /
    LOCAL_SRC="$SRC_DIR/./${p#/}"

    CMD=(
      rsync
      "${RS_OPTS[@]}"
      --relative
      -e "$SSH_RSYNC"
      --rsync-path="sudo -n rsync"
      "$LOCAL_SRC"
      "$BACKUP_USER@$TARGET_HOST:/"
    )

    echo "+ ${CMD[*]}"
    if ! "${CMD[@]}"; then
      echo "Warning: restore rsync failed for path: $p" >&2
      FAILED=1
    fi
  done
fi

# -----------------------------------------------------------------------------
# Explicitly restart containers now (trap remains as fallback)
# -----------------------------------------------------------------------------

restart_containers || true

echo "=== Restore finished at $(date '+%F %T') ==="
exit "$FAILED"
