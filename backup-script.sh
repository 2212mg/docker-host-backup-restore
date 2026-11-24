#!/usr/bin/env bash
# backup-script.sh

set -euo pipefail
shopt -s nullglob
umask 077
export LC_ALL=C

print_help() {
    cat <<'EOF'
Usage:
  backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<absolute_remote_path> ...]

Options:
  -h              Show help.
  -s              Deprecated; accepted for compatibility.
  -x name1,name2  Exclude matching containers from stop/start, not from backup.
  -e file         Local rsync exclude file.
  -n              Dry run: no container changes, pruning or published backup.
  -b MBPS         Limit rsync bandwidth in MB/s.
  -p streams      Accepted for compatibility; transfers are sequential.
  -P file         Remote Portainer Compose file; also discover managed Compose files.

Environment:
  BACKUP_MOUNTPOINT   Required local mount point (default: /mnt/sdb).
  BACKUP_AUTO_PRUNE   1: allow space-driven pruning before backup (default);
                      0: abort on insufficient space without pre-pruning.

Retention:
  Keep up to four published generations after a successful backup.
  Space-driven pruning protects at least the two newest published directories.
  Logs and metadata are removed with their corresponding pruned generation.

Example:
  backup-script.sh -n -x pihole \
    -P /home/marco/portainer/docker-compose.yml \
    backup_worker 192.168.0.229 /mnt/sdb/backups
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

DRY_RUN=false
EXCLUDES=()
EXCL_FILE=''
BWLIMIT=''
PORTAINER_COMPOSE=''
MOUNTPOINT=${BACKUP_MOUNTPOINT:-/mnt/sdb}
AUTO_PRUNE=${BACKUP_AUTO_PRUNE:-1}
KEEP=4
PROTECT=2
RESERVE_PERCENT=20

while getopts ':hsx:e:nb:p:P:' opt; do
    case "$opt" in
        h) print_help; exit 0 ;;
        s) : ;;
        x) IFS=',' read -r -a EXCLUDES <<< "$OPTARG" ;;
        e) EXCL_FILE=$OPTARG ;;
        n) DRY_RUN=true ;;
        b)
            [[ $OPTARG =~ ^[1-9][0-9]{0,6}$ ]] \
                || die '-b requires a positive integer in MB/s.'
            BWLIMIT=$((OPTARG * 1024))
            ;;
        p)
            [[ $OPTARG =~ ^[1-9][0-9]*$ ]] \
                || die '-p requires a positive integer.'
            [[ $OPTARG == 1 ]] || warn 'Transfers are sequential; ignoring -p.'
            ;;
        P) PORTAINER_COMPOSE=$OPTARG ;;
        :) die "Missing argument for -$OPTARG." ;;
        *) die "Unknown option: -$OPTARG." ;;
    esac
done
shift "$((OPTIND - 1))"

(( $# >= 3 )) || { print_help >&2; exit 1; }
BACKUP_USER=$1
TARGET_HOST=$2
BACKUP_ROOT=$3
shift 3
EXTRA_PATHS=("$@")

[[ $BACKUP_USER =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] \
    || die 'Invalid SSH username.'
[[ $TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] \
    || die 'Use a DNS hostname or an IPv4 address as target.'
[[ $AUTO_PRUNE == 0 || $AUTO_PRUNE == 1 ]] \
    || die 'BACKUP_AUTO_PRUNE must be 0 or 1.'
[[ -z $EXCL_FILE || -r $EXCL_FILE ]] \
    || die "Cannot read rsync exclude file: $EXCL_FILE"

# Check the mount before creating anything on the destination.
mountpoint -q -- "$MOUNTPOINT" || die "Not mounted: $MOUNTPOINT"
MOUNTPOINT=$(realpath -e -- "$MOUNTPOINT")
BACKUP_ROOT=$(realpath -e -- "$BACKUP_ROOT") \
    || die 'Backup root must already exist.'
[[ -d $BACKUP_ROOT && -w $BACKUP_ROOT ]] \
    || die "Backup root is not a writable directory: $BACKUP_ROOT"
[[ $BACKUP_ROOT == "$MOUNTPOINT/"* ]] \
    || die "Backup root must be below $MOUNTPOINT."

check_destination_mount() {
    local actual
    mountpoint -q -- "$MOUNTPOINT" \
        || die "Required mount is unavailable: $MOUNTPOINT"
    actual=$(findmnt -n -o TARGET --target "$1") \
        || die "Cannot determine the filesystem for $1."
    [[ $actual == "$MOUNTPOINT" ]] \
        || die "Unexpected filesystem for $1: $actual"
}

check_destination_mount "$BACKUP_ROOT"

HOST_DIR="$BACKUP_ROOT/$TARGET_HOST"
LOG_DIR="$HOST_DIR/logs"

[[ ! -L $HOST_DIR && ! -L $LOG_DIR ]] \
    || die 'The host backup or log directory is a symbolic link.'
mkdir -p -- "$HOST_DIR" "$LOG_DIR"
check_destination_mount "$HOST_DIR"
check_destination_mount "$LOG_DIR"

# Protect direct invocations as well as invocations through the systemd runner.
[[ ! -L $HOST_DIR/.backup-script.lock ]] || die 'Unsafe lock file.'
exec 9>>"$HOST_DIR/.backup-script.lock"
flock -n 9 || die "Another backup is already running for $TARGET_HOST."

TS=$(date +%F-%H-%M)
DEST="$HOST_DIR/full-$TS"
STOPPED_FILE="$HOST_DIR/stopped_containers_$TS.lst"
MANIFEST_OUT="$HOST_DIR/manifest_$TS.tsv"
SOURCE_OUT="$HOST_DIR/source_list_$TS.lst"

if $DRY_RUN; then
    LOG=$(mktemp "$LOG_DIR/dryrun_${TS}.XXXXXX.log")
else
    LOG="$LOG_DIR/bklog_$TS.log"
    for path in "$DEST" "$STOPPED_FILE" "$MANIFEST_OUT" "$SOURCE_OUT" "$LOG"; do
        [[ ! -e $path && ! -L $path ]] \
            || die "Output already exists: $path. Retry in a new minute."
    done
    : > "$LOG"
fi

# Continue forwarding output to the journal if the local log file fills up.
exec > >(tee --output-error=warn -a -- "$LOG") 2>&1

SSH_OPTS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
)
SSH_RSYNC="ssh ${SSH_OPTS[*]}"

remote_ssh() {
    ssh "${SSH_OPTS[@]}" "$BACKUP_USER@$TARGET_HOST" "$@"
}

# Quote for the remote POSIX shell, including paths containing single quotes.
shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

is_excluded() {
    local name=$1 ex
    for ex in "${EXCLUDES[@]}"; do
        [[ -n $ex && $name == *"$ex"* ]] && return 0
    done
    return 1
}

is_ignored_source() {
    case "$1" in
        /var/run/docker.sock|/run/docker.sock|/etc/localtime|/etc/timezone|\
        /var/lib/docker/overlay2|/var/lib/docker/overlay2/*) return 0 ;;
        *) return 1 ;;
    esac
}

WORK_DIR=''
PUBLISHED=false
METADATA_STARTED=false
RESTART_ATTEMPTED=false
RESTART_OK=true
STOPPED_CONTAINERS=()

restart_containers() {
    local i c state
    if $RESTART_ATTEMPTED; then
        "$RESTART_OK"
        return
    fi
    RESTART_ATTEMPTED=true
    if (( ${#STOPPED_CONTAINERS[@]} == 0 )); then
        return 0
    fi

    echo '=== Restarting containers ==='
    for ((i=${#STOPPED_CONTAINERS[@]}-1; i>=0; i--)); do
        c=${STOPPED_CONTAINERS[i]}
        echo "Starting $c"
        if ! remote_ssh "sudo -n docker start $(shell_quote "$c") >/dev/null"; then
            warn "Failed to start $c"
            RESTART_OK=false
            continue
        fi
        if ! state=$(remote_ssh \
            "sudo -n docker inspect --format '{{.State.Running}}' $(shell_quote "$c")") \
            || [[ $state != true ]]; then
            warn "Could not confirm running state for $c"
            RESTART_OK=false
        fi
    done

    if $RESTART_OK; then
        if ! rm -f -- "$STOPPED_FILE"; then
            warn "Could not remove recovery list: $STOPPED_FILE"
            return 1
        fi
        return 0
    fi

    warn "Restart incomplete. Recovery list retained: $STOPPED_FILE"
    return 1
}

cleanup_on_exit() {
    local rc=$?
    trap - EXIT
    if ! restart_containers; then
        rc=1
    fi

    if [[ -n $WORK_DIR ]] || { $METADATA_STARTED && ! $PUBLISHED; }; then
        local actual
        if mountpoint -q -- "$MOUNTPOINT" \
            && actual=$(findmnt -n -o TARGET --target "$HOST_DIR") \
            && [[ $actual == "$MOUNTPOINT" ]]; then
            if $METADATA_STARTED && ! $PUBLISHED; then
                rm -f -- "$MANIFEST_OUT" "$SOURCE_OUT" || rc=1
            fi
            if [[ -n $WORK_DIR ]]; then
                rm -rf --one-file-system -- "$WORK_DIR" || rc=1
            fi
        else
            warn 'Destination filesystem changed; skipping local cleanup.'
            rc=1
        fi
    fi

    if (( rc != 0 )); then
        warn "Backup job ended with exit code $rc. See $LOG"
    fi
    exit "$rc"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK_DIR=$(mktemp -d "$HOST_DIR/.backup-work-${TS}.XXXXXX")
STAGE="$WORK_DIR/data"
MANIFEST="$WORK_DIR/manifest.tsv"
SOURCE_LIST="$WORK_DIR/source_list.lst"
mkdir -- "$STAGE"
printf 'container\tstate\tkind\tpath\tnotes\n' > "$MANIFEST"

declare -A SOURCES=()
FINAL_SOURCES=()

add_source() {
    local source=$1 container=$2 state=$3 kind=$4 notes=$5

    if is_ignored_source "$source"; then
        return 0
    fi

    [[ $source == /* && $source != / && $source != *[[:cntrl:]]* ]] \
        || die "Unsupported source path: $source"
    case "$source/" in
        */../*|*/./*) die "Source path must not contain . or .. components: $source" ;;
    esac

    source=${source%/}
    SOURCES["$source"]=1
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$container" "$state" "$kind" "$source" "$notes" >> "$MANIFEST"
}

echo "=== Backup started at $(date '+%F %T') (dry run: $DRY_RUN) ==="
echo "Source: $TARGET_HOST; destination: $HOST_DIR"

remote_ssh 'true' || die 'SSH preflight failed.'
remote_ssh 'sudo -n rsync --version >/dev/null' \
    || die 'Remote rsync preflight failed.'

running_output=$(remote_ssh "sudo -n docker ps --format '{{.Names}}'") \
    || die 'Could not list running containers.'
RUNNING_CONTAINERS=()
if [[ -n $running_output ]]; then
    mapfile -t RUNNING_CONTAINERS <<< "$running_output"
fi
echo "Running containers: ${#RUNNING_CONTAINERS[@]}"

MOUNT_FORMAT='{{range .Mounts}}{{if and .Source (or (eq .Type "bind") (eq .Type "volume"))}}{{printf "%s\x1f%s\n" .Type .Source}}{{end}}{{end}}'

for c in "${RUNNING_CONTAINERS[@]}"; do
    state=stopped-for-backup
    if is_excluded "$c"; then
        state=live-excluded
    elif $DRY_RUN; then
        state=would-stop-for-backup
    fi

    mounts=$(remote_ssh \
        "sudo -n docker inspect --format $(shell_quote "$MOUNT_FORMAT") $(shell_quote "$c")") \
        || die "Mount discovery failed for $c."

    if [[ -n $mounts ]]; then
        while IFS=$'\x1f' read -r kind source; do
            [[ -n $source ]] || die "Invalid mount output for $c."
            add_source "$source" "$c" "$state" "$kind" '-'
        done <<< "$mounts"
    fi
done

if [[ -n $PORTAINER_COMPOSE ]]; then
    add_source "$PORTAINER_COMPOSE" portainer config compose-file 'Portainer own Compose file'

    PORTAINER_DATA=''
    DATA_FORMAT='{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}'
    for c in "${RUNNING_CONTAINERS[@]}"; do
        [[ $c == *portainer* ]] || continue
        PORTAINER_DATA=$(remote_ssh \
            "sudo -n docker inspect --format $(shell_quote "$DATA_FORMAT") $(shell_quote "$c")") \
            || die "Could not inspect Portainer candidate $c."
        [[ -n $PORTAINER_DATA ]] && break
    done
    [[ -n $PORTAINER_DATA ]] \
        || die 'Requested Portainer backup, but found no running Portainer container with a /data mount.'

    compose_files=$(remote_ssh \
        "sudo -n find $(shell_quote "$PORTAINER_DATA") -type f \
        \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
        -o -name 'compose.yml' -o -name 'compose.yaml' \)") \
        || die 'Portainer Compose discovery failed.'

    if [[ -n $compose_files ]]; then
        while IFS= read -r source; do
            add_source "$source" portainer config compose-file 'Discovered in Portainer data'
        done <<< "$compose_files"
    fi
fi

for source in "${EXTRA_PATHS[@]}"; do
    add_source "$source" '-' '-' extra 'Requested on command line'
done

(( ${#SOURCES[@]} > 0 )) || die 'No backup sources discovered.'

printf '%s\n' "${!SOURCES[@]}" | sort > "$SOURCE_LIST"
mapfile -t FINAL_SOURCES < "$SOURCE_LIST"

for source in "${FINAL_SOURCES[@]}"; do
    remote_ssh "sudo -n test -e $(shell_quote "$source")" \
        || die "Backup source missing or inaccessible: $source"
done

RS_OPTS=(
    -aHAX --numeric-ids --relative --protect-args
    --exclude=/var/run/docker.sock
    --exclude=/run/docker.sock
    --exclude=/etc/localtime
    --exclude=/etc/timezone
    '--exclude=/var/lib/docker/overlay2/***'
)
if [[ -n $BWLIMIT ]]; then
    RS_OPTS+=(--bwlimit="$BWLIMIT")
fi
if [[ -n $EXCL_FILE ]]; then
    RS_OPTS+=(--exclude-from="$EXCL_FILE")
fi

run_rsync() {
    local source=$1
    shift
    rsync "${RS_OPTS[@]}" "$@" \
        -e "$SSH_RSYNC" \
        --rsync-path='sudo -n rsync' \
        "$BACKUP_USER@$TARGET_HOST:/./${source#/}" \
        "$STAGE/"
}

free_bytes() {
    df -B1 --output=avail -- "$HOST_DIR" | awk 'NR == 2 {print $1}'
}

free_inodes() {
    df --output=iavail -- "$HOST_DIR" | awk 'NR == 2 {print $1}'
}

estimate_requirements() {
    local source stats bytes files
    local total_bytes=0 total_files=0

    echo '=== Estimating required space with rsync dry runs ==='
    for source in "${FINAL_SOURCES[@]}"; do
        echo "Estimating: $source"
        stats=$(run_rsync "$source" --dry-run --stats) \
            || die "Could not estimate source: $source"

        bytes=$(awk -F ': *' '/^Total file size:/ {
            split($2,a," "); gsub(/,/,"",a[1]); print a[1]; exit
        }' <<< "$stats")
        files=$(awk -F ': *' '/^Number of files:/ {
            split($2,a," "); gsub(/,/,"",a[1]); print a[1]; exit
        }' <<< "$stats")

        [[ $bytes =~ ^[0-9]+$ && $files =~ ^[0-9]+$ ]] \
            || die "Could not parse rsync statistics for $source."
        total_bytes=$((total_bytes + bytes))
        total_files=$((total_files + files))
    done

    # Estimate conservatively: overlapping sources may be counted twice.
    REQUIRED_BYTES=$((total_bytes + total_bytes * RESERVE_PERCENT / 100 + 1073741824))
    REQUIRED_INODES=$((total_files + total_files * RESERVE_PERCENT / 100 + 1024))
}

list_generations() {
    local dir name
    GENERATIONS=()
    # LC_ALL=C + the timestamp format puts the oldest generation first.
    for dir in "$HOST_DIR"/full-*; do
        [[ -d $dir && ! -L $dir ]] || continue
        name=${dir##*/}
        [[ $name =~ ^full-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] \
            || continue
        GENERATIONS+=("$dir")
    done
}

prune_generation() {
    local dir=$1 name stamp
    name=${dir##*/}
    stamp=${name#full-}

    [[ ${dir%/*} == "$HOST_DIR" && -d $dir && ! -L $dir \
        && $name =~ ^full-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] \
        || die "Refusing to prune unexpected path: $dir"
    check_destination_mount "$dir"
    echo "Pruning generation: $name"
    rm -rf --one-file-system -- "$dir" \
        || die "Failed to remove generation $name."
    [[ ! -e $dir ]] || die "Generation still exists after pruning: $name"

    rm -f -- "$HOST_DIR/manifest_$stamp.tsv" \
        "$HOST_DIR/source_list_$stamp.lst" "$LOG_DIR/bklog_$stamp.log" \
        || die "Failed to remove metadata for $name."
}

read_capacity() {
    AVAILABLE_BYTES=$(free_bytes) || die 'Could not read free bytes.'
    AVAILABLE_INODES=$(free_inodes) || die 'Could not read free inodes.'
    [[ $AVAILABLE_BYTES =~ ^[0-9]+$ && $AVAILABLE_INODES =~ ^[0-9]+$ ]] \
        || die 'Destination did not report numeric byte and inode availability.'
}

has_capacity() {
    (( AVAILABLE_BYTES >= REQUIRED_BYTES && AVAILABLE_INODES >= REQUIRED_INODES ))
}

ensure_capacity() {
    local candidates i dir bytes inodes
    local possible_bytes possible_inodes

    read_capacity
    printf 'Capacity: %s bytes and %s inodes free; %s bytes and %s inodes required.\n' \
        "$AVAILABLE_BYTES" "$AVAILABLE_INODES" "$REQUIRED_BYTES" "$REQUIRED_INODES"

    if has_capacity; then
        return 0
    fi
    if $DRY_RUN; then
        die 'Insufficient capacity. Dry run did not remove any backups.'
    fi
    [[ $AUTO_PRUNE == 1 ]] \
        || die 'Insufficient capacity; automatic pre-pruning is disabled.'

    list_generations
    candidates=$((${#GENERATIONS[@]} - PROTECT))
    (( candidates > 0 )) \
        || die "Insufficient capacity; preserving the newest $PROTECT generations."

    # Plan first. Do not remove any generation if the estimated recoverable
    # capacity is insufficient even after pruning all eligible generations.
    possible_bytes=$AVAILABLE_BYTES
    possible_inodes=$AVAILABLE_INODES
    for ((i=0; i<candidates; i++)); do
        dir=${GENERATIONS[i]}
        bytes=$(du -sx -B1 -- "$dir" | cut -f1) \
            || die "Could not measure reclaimable bytes for $dir."
        inodes=$(du -sx --inodes -- "$dir" | cut -f1) \
            || die "Could not measure reclaimable inodes for $dir."
        [[ $bytes =~ ^[0-9]+$ && $inodes =~ ^[0-9]+$ ]] \
            || die "Unexpected disk usage output for $dir."
        possible_bytes=$((possible_bytes + bytes))
        possible_inodes=$((possible_inodes + inodes))
        if (( possible_bytes >= REQUIRED_BYTES && possible_inodes >= REQUIRED_INODES )); then
            break
        fi
    done

    (( possible_bytes >= REQUIRED_BYTES && possible_inodes >= REQUIRED_INODES )) \
        || die 'Pruning eligible generations would not provide enough capacity. Nothing was pruned.'

    # Shared blocks can make du optimistic. Recheck actual free space
    # after each removal and stop as soon as there is sufficient capacity.
    for ((i=0; i<candidates; i++)); do
        prune_generation "${GENERATIONS[i]}"
        read_capacity
        if has_capacity; then
            echo 'Capacity check passed after pruning.'
            return 0
        fi
    done

    die 'Insufficient free space after pruning eligible generations.'
}

estimate_requirements
ensure_capacity

if $DRY_RUN; then
    echo '=== Dry run complete: sources and capacity checked; no backup was published. ==='
    exit 0
fi

check_destination_mount "$STAGE"
read_capacity
has_capacity || die 'Destination capacity changed before container shutdown.'

echo '=== Stopping non-excluded containers ==='
for c in "${RUNNING_CONTAINERS[@]}"; do
    if is_excluded "$c"; then
        warn "$c stays running; its data is backed up live and may be inconsistent."
        continue
    fi

    # Record the restart intent before sending docker stop, so a lost SSH
    # response after a successful stop does not leave the container forgotten.
    printf '%s\n' "$c" >> "$STOPPED_FILE"
    STOPPED_CONTAINERS+=("$c")
    echo "Stopping $c"
    remote_ssh "sudo -n docker stop $(shell_quote "$c") >/dev/null" \
        || die "Could not confirm that $c stopped; aborting the backup."
done

echo '=== Copying backup data ==='
for source in "${FINAL_SOURCES[@]}"; do
    echo "Backing up: $source"
    if run_rsync "$source" --info=progress2; then
        :
    else
        rc=$?
        die "rsync failed with exit code $rc for $source."
    fi
done

restart_containers || die 'Not all containers could be restarted.'

# Keep the Restore and Runner naming conventions unchanged.
# Publish with a same-filesystem rename only after transfer and restart checks.
check_destination_mount "$STAGE"
METADATA_STARTED=true
mv -T -- "$MANIFEST" "$MANIFEST_OUT"
mv -T -- "$SOURCE_LIST" "$SOURCE_OUT"
[[ ! -e $DEST && ! -L $DEST ]] || die "Backup destination already exists: $DEST"
mv -T -- "$STAGE" "$DEST"
PUBLISHED=true

list_generations
excess=$((${#GENERATIONS[@]} - KEEP))
for ((i=0; i<excess; i++)); do
    prune_generation "${GENERATIONS[i]}"
done

echo "=== Backup published at $(date '+%F %T'): $DEST ==="