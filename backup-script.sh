#!/usr/bin/env bash
# backup-script.sh
# -------------------------------------------------------------------
# Usage:
#   backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]
#
# OPTIONS:
#   -h               Show this help message and exit.
#   -s               Deprecated/no-op (kept for backward compatibility).
#   -x cont1,cont2   Comma-separated list of Docker container names to exclude from stop/restart.
#                    Excluded containers are STILL inspected and their storage is STILL backed up live.
#   -e exclude_file  File containing rsync exclude patterns.
#   -n               Dry-run mode (true no-disruption mode: no container stop/start, rsync --dry-run).
#   -b MBPS          Bandwidth limit in MB/s for rsync.
#   -p streams       Number of parallel rsync streams. Accepted, but forced to 1 for safety.
#   -P file          Absolute path to Portainer's own docker-compose.yml on the target host.
#                    When set, the script also discovers additional compose files stored inside
#                    Portainer's data area and backs them up with full absolute paths.
#
# DESCRIPTION:
#   Live backup only.
#
#   1) Inspect running Docker containers on the remote host.
#   2) Discover their persistent storage locations:
#        - bind mounts
#        - named/anonymous Docker volumes
#      (Intentionally skips overlay2 writable layer paths)
#   3) Optionally discover Portainer-managed compose files when -P is set.
#   4) Stop all running containers except those excluded via -x.
#      (Skipped completely in dry-run mode.)
#   5) Back up all discovered storage paths, preserving absolute paths.
#   6) Also back up any additional absolute paths supplied on the CLI.
#   7) Restart previously stopped containers automatically.
#   8) Prune old backups/logs (keep 4).
#
# REQUIREMENTS ON TARGET:
#   backup_user must be able to run at least these without a password:
#     sudo -n docker ...
#     sudo -n rsync ...
#     sudo -n test ...
#     sudo -n find ...
#
# NOTES:
#   - Excluded containers are NOT stopped, so their storage is backed up live and may be inconsistent.
#   - tmpfs mounts are ignored because they are not persistent host storage.
#   - overlay2/.../diff is intentionally skipped.
#   - docker.sock, /etc/localtime, and /etc/timezone are intentionally ignored.
#   - Additional CLI paths passed on CLI should be ABSOLUTE paths on the target host.
# -------------------------------------------------------------------

set -euo pipefail
shopt -s nullglob

print_help() {
  cat <<'EOF'
Usage:
  backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]

Options:
  -h               Show this help message and exit.
  -s               Deprecated/no-op (live backup only; kept for compatibility).
  -x cont1,cont2   Comma-separated list of Docker container names to exclude from stop/restart.
                   Excluded containers are still inspected and their storage is still backed up live.
  -e exclude_file  File containing rsync exclude patterns.
  -n               Dry-run mode (true no-disruption mode: no container stop/start, rsync --dry-run).
  -b MBPS          Bandwidth limit in MB/s for rsync.
  -p streams       Number of parallel rsync streams (accepted, but forced to 1 for safety).
  -P file          Absolute path to Portainer's own docker-compose.yml on the target host.
                   When set, the script also discovers additional compose files inside Portainer.

Description:
  Performs a live backup from a remote host by:
    - inspecting all running Docker containers,
    - discovering host-side persistent storage paths,
    - optionally discovering Portainer-managed compose files,
    - optionally stopping non-excluded containers,
    - backing up all discovered paths while preserving absolute paths,
    - backing up any additional absolute paths specified on the command line,
    - restarting previously stopped containers,
    - pruning old backups/logs/manifests/source lists (keeping the 4 most recent).

Examples:
  backup-script.sh backup-user [BACKUP-TARGET-IP] ./backups

  backup-script.sh -x pihole backup-user [BACKUP-TARGET-IP] ./backups

  backup-script.sh -n -x pihole -P /path/to/portainer/docker-compose.yml backup-user [BACKUP-TARGET-IP] ./backups

  backup-script.sh -x pihole -P /path/to/portainer/docker-compose.yml backup-user [BACKUP-TARGET-IP] ./backups /etc

Notes:
  - Additional CLI paths must be absolute paths on the target host.
  - Excluded containers keep running; their data is backed up live and may be inconsistent.
  - overlay2 writable layers are intentionally skipped.
  - docker.sock, /etc/localtime, and /etc/timezone are intentionally ignored.
EOF
}

# Early help
for arg in "$@"; do
  [[ "$arg" == "-h" ]] && { print_help; exit 0; }
done

# Defaults
EXCLUDES=()
EXCL_FILE=""
DRY_RUN=""
DRY_RUN_MODE=false
BWLIMIT=""
PARALLEL=1
LIVE_ONLY=true
PORTAINER_COMPOSE_FILE=""

while getopts ":hsx:e:nb:p:P:" opt; do
  case "$opt" in
    h) print_help; exit 0 ;;
    s)
      # Kept for compatibility only
      LIVE_ONLY=true
      ;;
    x) IFS=',' read -r -a EXCLUDES <<< "$OPTARG" ;;
    e) EXCL_FILE="$OPTARG" ;;
    n)
      DRY_RUN="--dry-run"
      DRY_RUN_MODE=true
      ;;
    b) BWLIMIT="--bwlimit=$((OPTARG * 1024))" ;;
    p) PARALLEL="$OPTARG" ;;
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
EXTRA_PATHS=("$@")

HOST_DIR="$BACKUP_ROOT/$TARGET_HOST"
LOG_DIR="$HOST_DIR/logs"
mkdir -p "$HOST_DIR" "$LOG_DIR"

TS=$(date +%F-%H-%M)
LOG="$LOG_DIR/bklog_$TS.log"
STOPPED_FILE="$HOST_DIR/stopped_containers_$TS.lst"
MANIFEST_FILE="$HOST_DIR/manifest_$TS.tsv"
SOURCE_LIST_FILE="$HOST_DIR/source_list_$TS.lst"

# SSH options: let SSH choose the right key automatically
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# Redirect all output to log and console
exec > >(tee -a "$LOG") 2>&1

echo "=== Backup started at $(date '+%F %T') ==="
echo "Options: live-only=true, dry-run=${DRY_RUN:-no}, exclude-file=${EXCL_FILE:-none}, bwlimit=${BWLIMIT:-none}, streams=$PARALLEL, excludes=${EXCLUDES[*]:-none}, portainer-compose=${PORTAINER_COMPOSE_FILE:-none}"

if (( PARALLEL > 1 )); then
  echo "Warning: forcing streams=1 because concurrent rsync into one destination is unsafe in this design."
  PARALLEL=1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

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

remote_exists() {
  local p="$1"
  remote_ssh "sudo -n test -e $(shell_quote "$p")"
}

# Ignore explicitly unwanted paths
is_ignored_source() {
  local p="$1"

  case "$p" in
    /var/run/docker.sock) return 0 ;;
    /etc/localtime) return 0 ;;
    /etc/timezone) return 0 ;;
    *) return 1 ;;
  esac
}

# Use an associative array to deduplicate actual backup sources
declare -A UNIQUE_SOURCES=()
declare -A SOURCE_REASON=()

add_source() {
  local path="$1"
  local reason="$2"

  [[ -n "$path" ]] || return 0

  # Only absolute host paths make sense for this backup design
  if [[ "$path" != /* ]]; then
    echo "Skipping non-absolute path: $path (reason: $reason)"
    return 0
  fi

  # Explicit ignore list
  if is_ignored_source "$path"; then
    echo "Ignoring path by policy: $path (reason: $reason)"
    return 0
  fi

  # Skip overlay2 writable layer paths entirely
  case "$path" in
    /var/lib/docker/overlay2/*/diff|/var/lib/docker/overlay2/*)
      echo "Ignoring overlay2 path by policy: $path (reason: $reason)"
      return 0
      ;;
  esac

  if [[ -z "${UNIQUE_SOURCES[$path]+x}" ]]; then
    UNIQUE_SOURCES["$path"]=1
    SOURCE_REASON["$path"]="$reason"
  else
    case " ${SOURCE_REASON[$path]} " in
      *" $reason "*) ;;
      *) SOURCE_REASON["$path"]="${SOURCE_REASON[$path]}; $reason" ;;
    esac
  fi
}

add_manifest_entry() {
  local container="$1"
  local state="$2"
  local kind="$3"
  local path="$4"
  local notes="$5"
  printf "%s\t%s\t%s\t%s\t%s\n" "$container" "$state" "$kind" "$path" "$notes" >> "$MANIFEST_FILE"
}

RESTART_DONE=false

restart_containers() {
  # No stop/start at all in dry-run mode
  if $DRY_RUN_MODE; then
    rm -f "$STOPPED_FILE"
    RESTART_DONE=true
    return 0
  fi

  # Avoid running twice
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

# Fallback restart on abnormal exits
cleanup_on_exit() {
  local rc=$?
  restart_containers || true
  return "$rc"
}
trap cleanup_on_exit EXIT

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

echo "=== Pre-flight checks ==="
remote_ssh "true"
remote_ssh "sudo -n docker ps >/dev/null"
remote_ssh "sudo -n rsync --version >/dev/null"
remote_ssh "sudo -n test -d /var/lib/docker >/dev/null || true"

if [[ -n "$PORTAINER_COMPOSE_FILE" ]]; then
  if [[ "$PORTAINER_COMPOSE_FILE" != /* ]]; then
    echo "Error: -P requires an absolute target path to Portainer's docker-compose.yml" >&2
    exit 1
  fi
  remote_ssh "sudo -n find / >/dev/null 2>&1 || true"
fi

# -----------------------------------------------------------------------------
# Discover running containers
# -----------------------------------------------------------------------------

declare -a RUNNING_CONTAINERS=()
mapfile -t RUNNING_CONTAINERS < <(remote_ssh "sudo -n docker ps --format '{{.Names}}'")

echo "=== Running containers detected: ${#RUNNING_CONTAINERS[@]} ==="
if (( ${#RUNNING_CONTAINERS[@]} > 0 )); then
  printf ' - %s\n' "${RUNNING_CONTAINERS[@]}"
else
  echo "No running containers found."
fi

# Manifest header
printf "container\tstate\tkind\tpath\tnotes\n" > "$MANIFEST_FILE"

# -----------------------------------------------------------------------------
# Discover storage used by running containers
# -----------------------------------------------------------------------------

echo "=== Discovering container storage on target ==="

for c in "${RUNNING_CONTAINERS[@]}"; do
  container_state="stopped-for-backup"
  if is_excluded "$c"; then
    container_state="live-excluded"
  elif $DRY_RUN_MODE; then
    container_state="would-stop-for-backup"
  fi

  echo "--- Inspecting container: $c ($container_state) ---"

  # Discover mounts
  # Output format per line:
  #   TYPE <US> SOURCE
  # where <US> = unit separator 0x1F
  mapfile -t mount_lines < <(
    remote_ssh "sudo -n docker inspect $(shell_quote "$c") --format '{{range .Mounts}}{{if and .Source (or (eq .Type \"bind\") (eq .Type \"volume\"))}}{{printf \"%s\\x1f%s\\n\" .Type .Source}}{{end}}{{end}}'"
  )

  if (( ${#mount_lines[@]} > 0 )); then
    for line in "${mount_lines[@]}"; do
      IFS=$'\x1f' read -r mtype msource <<< "$line"
      [[ -n "${msource:-}" ]] || continue

      add_source "$msource" "container=$c kind=$mtype state=$container_state"

      if ! is_ignored_source "$msource" && [[ "$msource" != /var/lib/docker/overlay2/* ]]; then
        add_manifest_entry "$c" "$container_state" "$mtype" "$msource" "-"
        echo "  found $mtype: $msource"
      fi
    done
  else
    echo "  no persistent bind/volume mounts found"
  fi
done

# -----------------------------------------------------------------------------
# Optional: discover Portainer environments compose files
# -----------------------------------------------------------------------------

if [[ -n "$PORTAINER_COMPOSE_FILE" ]]; then
  echo "=== Discovering Portainer compose files ==="

  # Always back up Portainer's own docker-compose.yml
  add_source "$PORTAINER_COMPOSE_FILE" "portainer-root-compose"
  add_manifest_entry "portainer" "config" "compose-file" "$PORTAINER_COMPOSE_FILE" "Portainer own docker-compose.yml"
  echo "  added Portainer compose file: $PORTAINER_COMPOSE_FILE"

  # Find a Portainer container among running containers
  PORTAINER_CONTAINER=""
  for c in "${RUNNING_CONTAINERS[@]}"; do
    if [[ "$c" == *portainer* ]]; then
      PORTAINER_CONTAINER="$c"
      break
    fi
  done

  if [[ -z "$PORTAINER_CONTAINER" ]]; then
    echo "Warning: no running Portainer container found; cannot auto-discover Portainer-managed compose files." >&2
  else
    echo "  using Portainer container: $PORTAINER_CONTAINER"

    # Find the host-side source mounted to /data in Portainer
    PORTAINER_DATA_SOURCE="$(
      remote_ssh "sudo -n docker inspect $(shell_quote "$PORTAINER_CONTAINER") --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{printf \"%s\" .Source}}{{end}}{{end}}'" \
        || true
    )"

    if [[ -z "$PORTAINER_DATA_SOURCE" ]]; then
      echo "Warning: could not determine Portainer data source mount (/data) from container $PORTAINER_CONTAINER" >&2
    else
      echo "  Portainer data source: $PORTAINER_DATA_SOURCE"

      # Find compose files inside Portainer data source
      mapfile -t PORTAINER_COMPOSE_FILES < <(
        remote_ssh "sudo -n find $(shell_quote "$PORTAINER_DATA_SOURCE") -type f \\( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \\) 2>/dev/null" \
          || true
      )

      if (( ${#PORTAINER_COMPOSE_FILES[@]} > 0 )); then
        echo "  found ${#PORTAINER_COMPOSE_FILES[@]} Portainer-managed compose file(s)"
        for f in "${PORTAINER_COMPOSE_FILES[@]}"; do
          add_source "$f" "portainer-managed-compose"
          add_manifest_entry "portainer" "config" "compose-file" "$f" "Discovered inside Portainer data source"
          echo "    compose file: $f"
        done
      else
        echo "  no additional compose files found inside Portainer data source"
      fi
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Add extra CLI paths
# -----------------------------------------------------------------------------

if (( ${#EXTRA_PATHS[@]} > 0 )); then
  echo "=== Processing additional CLI paths ==="
  for p in "${EXTRA_PATHS[@]}"; do
    if [[ "$p" != /* ]]; then
      echo "Skipping additional path because it is not absolute: $p"
      add_manifest_entry "-" "-" "extra" "$p" "skipped: not absolute"
      continue
    fi
    add_source "$p" "extra-cli-path"
    if ! is_ignored_source "$p" && [[ "$p" != /var/lib/docker/overlay2/* ]]; then
      add_manifest_entry "-" "-" "extra" "$p" "from CLI"
      echo "  added extra path: $p"
    fi
  done
fi

# -----------------------------------------------------------------------------
# Validate collected sources on target
# -----------------------------------------------------------------------------

echo "=== Validating discovered sources on target ==="

: > "$SOURCE_LIST_FILE"

mapfile -t SORTED_SOURCES < <(printf '%s\n' "${!UNIQUE_SOURCES[@]}" | sort)

if (( ${#SORTED_SOURCES[@]} == 0 )); then
  echo "No sources were discovered and no valid extra paths were provided."
  echo "Nothing to back up."
  exit 1
fi

for src in "${SORTED_SOURCES[@]}"; do
  if remote_exists "$src"; then
    printf "%s\n" "$src" >> "$SOURCE_LIST_FILE"
    echo "  OK: $src"
  else
    echo "  MISSING: $src (reason: ${SOURCE_REASON[$src]})"
    add_manifest_entry "-" "-" "missing" "$src" "${SOURCE_REASON[$src]}"
  fi
done

mapfile -t FINAL_SOURCES < "$SOURCE_LIST_FILE"

if (( ${#FINAL_SOURCES[@]} == 0 )); then
  echo "All discovered sources were missing or inaccessible on the target."
  exit 1
fi

echo "=== Final backup source count: ${#FINAL_SOURCES[@]} ==="
printf ' - %s\n' "${FINAL_SOURCES[@]}"

# -----------------------------------------------------------------------------
# Stop non-excluded running containers
# -----------------------------------------------------------------------------

if $DRY_RUN_MODE; then
  echo "=== Dry-run mode: skipping container stop/start (no-disruption) ==="
else
  echo "=== Stopping non-excluded containers ==="
  : > "$STOPPED_FILE"

  for c in "${RUNNING_CONTAINERS[@]}"; do
    if is_excluded "$c"; then
      echo "Skipping stop for excluded container: $c"
      echo "Warning: $c remains running, so its data is backed up live and may be inconsistent."
      continue
    fi

    echo "Stopping $c"
    if remote_ssh "sudo -n docker stop $(shell_quote "$c") >/dev/null"; then
      echo "$c" >> "$STOPPED_FILE"
    else
      echo "Warning: failed to stop $c; proceeding, but backup consistency may be affected." >&2
    fi
  done
fi

# -----------------------------------------------------------------------------
# Prepare destination
# -----------------------------------------------------------------------------

DEST="$HOST_DIR/full-$TS"
mkdir -p "$DEST"

# -----------------------------------------------------------------------------
# Build rsync options
# -----------------------------------------------------------------------------

RS_OPTS=(
  -aHAX
  --numeric-ids
  --relative
  --protect-args
  --info=progress2
)

[[ -n "$DRY_RUN" ]] && RS_OPTS+=("$DRY_RUN")
[[ -n "$BWLIMIT" ]] && RS_OPTS+=("$BWLIMIT")
[[ -n "$EXCL_FILE" ]] && RS_OPTS+=(--exclude-from="$EXCL_FILE")

SSH_RSYNC="ssh ${SSH_OPTS[*]}"

# -----------------------------------------------------------------------------
# Run rsync for each source sequentially
# -----------------------------------------------------------------------------

echo "=== Running rsync at $(date '+%F %T') ==="

FAILED=0

for src in "${FINAL_SOURCES[@]}"; do
  REMOTE_SRC="${BACKUP_USER}@${TARGET_HOST}:/./${src#/}"

  CMD=(
    rsync
    "${RS_OPTS[@]}"
    -e "$SSH_RSYNC"
    --rsync-path="sudo -n rsync"
    "$REMOTE_SRC"
    "$DEST/"
  )

  echo "+ ${CMD[*]}"
  if ! "${CMD[@]}"; then
    echo "Warning: rsync failed for source: $src" >&2
    FAILED=1
  fi
done

# -----------------------------------------------------------------------------
# Explicitly restart containers now (trap remains as fallback)
# -----------------------------------------------------------------------------

restart_containers || true

# -----------------------------------------------------------------------------
# Prune old backups (keep 4) and corresponding logs/manifests/source lists
# -----------------------------------------------------------------------------

cd "$HOST_DIR"

echo "=== Pruning old backups/logs (keep 4) ==="

# Prune backups
fulls=(full-*)
if (( ${#fulls[@]} > 4 )); then
  IFS=$'\n' sorted=( $(printf "%s\n" "${fulls[@]}" | sort) )
  unset IFS
  to_remove=( "${sorted[@]:0:${#sorted[@]}-4}" )
  for old in "${to_remove[@]}"; do
    echo "Removing old backup: $old"
    rm -rf -- "$old"
  done
fi

# Prune logs
logs=(logs/bklog_*.log)
if (( ${#logs[@]} > 4 )); then
  IFS=$'\n' sorted_logs=( $(printf "%s\n" "${logs[@]}" | sort) )
  unset IFS
  old_logs=( "${sorted_logs[@]:0:${#sorted_logs[@]}-4}" )
  for lf in "${old_logs[@]}"; do
    echo "Removing old log: $lf"
    rm -f -- "$lf"
  done
fi

# Prune manifests
manifests=(manifest_*.tsv)
if (( ${#manifests[@]} > 4 )); then
  IFS=$'\n' sorted_manifests=( $(printf "%s\n" "${manifests[@]}" | sort) )
  unset IFS
  old_manifests=( "${sorted_manifests[@]:0:${#sorted_manifests[@]}-4}" )
  for mf in "${old_manifests[@]}"; do
    echo "Removing old manifest: $mf"
    rm -f -- "$mf"
  done
fi

# Prune source lists
source_lists=(source_list_*.lst)
if (( ${#source_lists[@]} > 4 )); then
  IFS=$'\n' sorted_lists=( $(printf "%s\n" "${source_lists[@]}" | sort) )
  unset IFS
  old_lists=( "${sorted_lists[@]:0:${#sorted_lists[@]}-4}" )
  for sf in "${old_lists[@]}"; do
    echo "Removing old source list: $sf"
    rm -f -- "$sf"
  done
fi

echo "=== Backup finished at $(date '+%F %T') ==="

exit "$FAILED"
