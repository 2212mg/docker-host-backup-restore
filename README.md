# Backup and Restore Scripts

This repository provides two Bash scripts for automated backup and recovery of remote Docker hosts:

- `backup-script.sh`: Performs **live backups** from a remote Docker host into a local backup root. It auto-discovers Docker bind mounts and volumes from running containers, can optionally include Portainer-managed compose files, supports extra absolute paths, logs the run, and applies retention.
- `restore-script.sh`: Restores a selected full backup (latest or specified) back to the target host via SSH, with Docker container stop/restart handling, path-based restore support, and matching Portainer compose-file restore support.

## Use Case

These scripts are intended for:

- Backing up data from a remote Docker host
- Automatically discovering Docker-related persistent storage, including:
  - Docker named volumes
  - Docker anonymous volumes
  - bind mounts
- Backing up Portainer stack compose files when requested
- Stopping and restarting containers automatically during real backup and restore runs
- Supporting additional absolute paths on the target host
- Running safe **true dry-runs** without service disruption

---

## Requirements

- **Bash** (v4+ recommended)
- **SSH** access from the backup server to the target host using key-based authentication
- **rsync** installed on both systems
- **Docker CLI** on the target host
- **Passwordless sudo** on the target host for the backup user for at least:
  - `docker`
  - `rsync`
  - `test`
  - `find` (required for Portainer compose file discovery)
- Optional: access to target-side paths you explicitly add as additional backup paths

### Important Notes

- The current workflow is **live-only**.
- There is **no LVM/ZFS snapshot support** anymore.
- The `-s` option is still accepted by `backup-script.sh` **for backward compatibility only**, but it is now a **no-op**.
- The `-p` option is still accepted by both scripts, but the scripts currently **force sequential processing** for safety.
- `backup-script.sh` intentionally **ignores**:
  - `/var/run/docker.sock`
  - `/etc/localtime`
  - `/etc/timezone`
- `backup-script.sh` intentionally **skips**:
  - `/var/lib/docker/overlay2/...`

---

## Installation

1. Place both scripts in a directory on your backup server, for example:

   ```bash
   /usr/local/bin/
   ```

2. Mark them executable:

   ```bash
   chmod +x backup-script.sh restore-script.sh
   ```

3. Ensure SSH key-based authentication is set up for the backup user from the backup server to the target host.

4. Ensure the backup user on the target host can run the required commands via `sudo -n` without a password prompt.

---

## Common Options

Both scripts accept the following flags:

| Option            | Description |
|------------------|-------------|
| `-h`             | Show help message and exit |
| `-n`             | True dry-run mode (`rsync --dry-run`) without container stop/start |
| `-b MBPS`        | Bandwidth limit in MB/s (sets `--bwlimit=$((MBPS*1024))`) |
| `-p streams`     | Number of parallel rsync streams (accepted, but currently forced to `1`) |
| `-x cont1,cont2` | Comma-separated Docker container names to exclude from stop/restart |
| `-e exclude_file`| File containing rsync exclude patterns |

---

# `backup-script.sh`

## Usage

```bash
backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]
```

## Description

`backup-script.sh` performs a **live backup** from a remote Docker host.

The script automatically discovers persistent Docker storage, optionally includes Portainer-managed compose files, validates available backup capacity before stopping containers, and publishes a backup only after the transfer and container restart checks complete successfully.

### Workflow

1. Validates that the configured backup filesystem is mounted and the backup destination is writable.
2. Acquires a lock to prevent concurrent backup runs.
3. Connects to the target host via SSH.
4. Detects all **currently running Docker containers**.
5. Inspects each running container and discovers host-side persistent storage:
   - bind mounts
   - named Docker volumes
   - anonymous Docker volumes
6. Optionally discovers Portainer-managed compose files when `-P` is used.
7. Adds any additional absolute paths supplied on the command line.
8. Validates that all selected source paths exist on the target.
9. Uses `rsync --dry-run --stats` to estimate the size and inode requirements of the upcoming backup.
10. Adds a safety margin to the estimated storage requirements.
11. Verifies that sufficient local backup capacity is available.
12. If enabled and required, removes eligible old backup generations **before** stopping containers.
13. In a **real run**, stops all running containers except those excluded with `-x`.
14. Copies all selected storage paths into a temporary staging directory while preserving their **full absolute paths**.
15. Restarts all containers that were stopped for the backup.
16. Publishes the completed staging directory as `full-YYYY-MM-DD-HH-MM/` only after the copy and restart checks succeed.
17. Applies normal retention, keeping the **4 most recent published backup generations**.
18. Removes temporary data and incomplete metadata when a backup fails.

## Important Behavior

- Excluded containers are **still inspected**, and their discovered storage is **still backed up**.
- Excluded containers are **not stopped**, so their storage is backed up **live** and may therefore be inconsistent.
- `tmpfs` mounts are ignored because they are not persistent storage.
- Docker `overlay2` writable layer paths are intentionally skipped.
- `/var/run/docker.sock`, `/run/docker.sock`, `/etc/localtime`, and `/etc/timezone` are intentionally ignored.
- Additional CLI paths must be **absolute paths on the target host**.
- Concurrent backup runs for the same target are prevented using a local `flock`.
- The backup destination must reside below the configured backup mount point.
- The script verifies that the expected backup filesystem is mounted before writing or deleting backup data.
- A failed backup is **not published as a valid `full-*` backup generation**.
- Container restart failures cause the backup run to fail.
- The container recovery list is retained when not all containers can be restarted successfully.
- Backup transfers are intentionally sequential. The `-p` option remains accepted for compatibility but does not enable parallel transfers.

## Storage Preflight

Before stopping any containers, the script estimates how much disk space and how many inodes are required for the next backup.

The estimate is calculated using:

```bash
rsync --dry-run --stats
```

for every selected backup source.

The script then adds:

- **20% safety margin**
- an additional **1 GiB disk-space margin**
- an additional inode margin

Example:

```text
Capacity: 403342786560 bytes and 60299406 inodes free;
301031362188 bytes and 407896 inodes required.
```

The backup only proceeds when sufficient capacity is available.

The estimate is intentionally conservative and is not an absolute guarantee. Source data can change between the dry-run estimation and the actual transfer.

### Automatic pre-pruning

By default:

```bash
BACKUP_AUTO_PRUNE=1
```

If insufficient space is available, the script may remove eligible old backup generations **before** containers are stopped.

The two newest published backup generations are protected from this pre-pruning process.

The script first calculates whether deleting the eligible generations is expected to free enough capacity. If even deleting all eligible generations would not provide sufficient space, the backup aborts without performing the pre-pruning.

After each deletion, the actual available filesystem capacity is checked again.

Automatic pre-pruning can be disabled:

```bash
BACKUP_AUTO_PRUNE=0 backup-script.sh ...
```

With automatic pre-pruning disabled, insufficient capacity causes the backup to abort.

## Backup Mount Validation

The default backup mount point is:

```text
/mnt/sdb
```

It can be overridden using:

```bash
BACKUP_MOUNTPOINT=/path/to/mount backup-script.sh ...
```

The script verifies that:

1. the configured mount point is actually mounted,
2. the backup root already exists,
3. the backup root is writable,
4. the backup root resides below the expected mount point,
5. the filesystem does not unexpectedly change during the backup process.

This prevents the script from accidentally writing large backups to the root filesystem if the intended backup disk is not mounted.

## Backup Staging and Publication

A new backup is initially written into a temporary staging directory:

```text
<backup_root>/<target_host>/.backup-work-<timestamp>.<random>/
```

The final backup directory:

```text
full-YYYY-MM-DD-HH-MM/
```

is created only after:

1. all selected sources were transferred successfully,
2. previously stopped containers were restarted successfully,
3. the backup metadata was prepared successfully.

The staging directory is then renamed to the final backup directory on the same filesystem.

This means that the presence of:

```text
full-YYYY-MM-DD-HH-MM/
```

indicates a backup that successfully passed the script's transfer and container-restart checks.

If the backup fails before publication, the staging directory and incomplete metadata are removed automatically where safely possible.

## Dry-Run Behavior

Dry-run mode is enabled using:

```bash
-n
```

A dry-run performs a **no-disruption validation**.

It:

- connects to the target host,
- discovers running Docker containers,
- discovers persistent Docker storage,
- optionally discovers Portainer-managed compose files,
- validates the selected source paths,
- executes the rsync-based capacity estimation,
- verifies available disk space,
- verifies available inodes.

A dry-run does **not**:

- stop containers,
- start containers,
- copy the actual backup data,
- publish a `full-*` backup generation,
- remove old backup generations.

Example:

```bash
BACKUP_AUTO_PRUNE=0 \
backup-script.sh \
  -n \
  -x pihole \
  -P /home/myuser/portainer/docker-compose.yml \
  backupuser \
  remote.example.com \
  /backups
```

A successful dry-run ends with:

```text
Dry run complete: sources and capacity checked; no backup was published.
```

## Retention

The normal retention policy keeps the **4 most recent published backup generations**.

After a successful backup, older generations are removed as required.

Associated metadata is removed together with the corresponding generation:

```text
full-YYYY-MM-DD-HH-MM/
logs/bklog_YYYY-MM-DD-HH-MM.log
manifest_YYYY-MM-DD-HH-MM.tsv
source_list_YYYY-MM-DD-HH-MM.lst
```

Storage-driven pre-pruning and normal retention serve different purposes:

- **Pre-pruning** creates enough space to safely start the next backup.
- **Normal retention** limits the number of published generations after a successful backup.

## Script-Specific Options

| Option | Description |
|---|---|
| `-s` | Deprecated/no-op. Kept only for backward compatibility. |
| `-P file` | Absolute path to Portainer's own `docker-compose.yml` on the target host. Also discovers compose files stored inside Portainer's data area. |
| `-n` | Safe dry-run. Performs discovery and capacity validation without stopping containers, copying data, pruning backups, or publishing a backup. |

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BACKUP_MOUNTPOINT` | `/mnt/sdb` | Expected local filesystem mount containing the backup root. |
| `BACKUP_AUTO_PRUNE` | `1` | Set to `0` to prevent automatic pre-pruning when available capacity is insufficient. |

## Portainer Environments Backup

When `-P` is supplied:

1. The specified Portainer `docker-compose.yml` is added to the backup set.
2. The script detects a running Portainer container on the target.
3. It resolves the host path mounted to `/data` inside that Portainer container.
4. It searches that Portainer data path for additional compose files such as:
   - `docker-compose.yml`
   - `docker-compose.yaml`
   - `compose.yml`
   - `compose.yaml`
5. All discovered compose files are added to the backup set with their **full absolute paths**.

This is intended for setups where Portainer stores stack definitions inside its own data area.

If `-P` is explicitly requested but the script cannot identify a running Portainer container with a `/data` mount, the backup fails instead of silently omitting the requested Portainer configuration.

## Output Structure

Successfully published backups are stored under:

```text
<backup_root>/<target_host>/
```

A successful real backup creates:

```text
<backup_root>/<target_host>/
├── full-YYYY-MM-DD-HH-MM/
├── logs/
│   └── bklog_YYYY-MM-DD-HH-MM.log
├── manifest_YYYY-MM-DD-HH-MM.tsv
└── source_list_YYYY-MM-DD-HH-MM.lst
```

Temporary staging directories use:

```text
.backup-work-<timestamp>.<random>/
```

and are not considered valid restore points.

### Manifest file

The manifest records what the script discovered during inspection, including:

- container name
- container state
- storage kind
- host-side path
- optional notes

Example container states include:

```text
stopped-for-backup
would-stop-for-backup
live-excluded
config
```

Storage kinds may include:

```text
bind
volume
compose-file
extra
```

### Source list file

The source list contains the final set of validated absolute host paths selected for the backup.

The source list can later be used by `restore-script.sh` to determine which paths belong to a backup generation.

## Container Recovery

For real backup runs, the script records containers that need to be restarted.

Container stop intent is recorded before the remote stop command is issued. This reduces the risk of losing track of a container if the SSH connection fails immediately after Docker successfully stops it.

After the backup transfer, stopped containers are restarted.

The script also verifies the resulting Docker running state.

If one or more containers cannot be restarted:

- the backup run fails,
- the backup is not published as a successful `full-*` generation,
- the recovery list is retained for troubleshooting.

## Examples

### Back up automatically discovered Docker storage

```bash
backup-script.sh backupuser remote.example.com /backups
```

### Back up Docker storage but keep `pihole` running

```bash
backup-script.sh \
  -x pihole \
  backupuser \
  remote.example.com \
  /backups
```

### Back up Docker storage plus additional absolute paths

```bash
backup-script.sh \
  -x pihole \
  backupuser \
  remote.example.com \
  /backups \
  /etc \
  /home/myuser/portainer
```

### Dry-run without disrupting running containers

```bash
backup-script.sh \
  -n \
  -x pihole \
  backupuser \
  remote.example.com \
  /backups \
  /etc
```

### Back up Portainer compose files too

```bash
backup-script.sh \
  -P /home/myuser/portainer/docker-compose.yml \
  backupuser \
  remote.example.com \
  /backups
```

### Dry-run with Portainer compose discovery and no automatic pruning

```bash
BACKUP_AUTO_PRUNE=0 \
backup-script.sh \
  -n \
  -x pihole \
  -P /home/myuser/portainer/docker-compose.yml \
  backupuser \
  remote.example.com \
  /backups
```

## Exit Behavior

The script exits with a non-zero status when a material backup condition fails, including:

- SSH preflight failure
- remote Docker or rsync failure
- missing or inaccessible source paths
- missing expected backup filesystem
- insufficient backup capacity
- rsync transfer failure
- container restart failure
- unsafe or unexpected filesystem state

A successful real run exits with:

```text
0
```

only after the backup has been successfully published.

# `restore-script.sh`

## Usage

```bash
restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> [<path2> ...]]
```

## Description

`restore-script.sh` restores data from a backup created by the current live-only `backup-script.sh`.

### Workflow

1. Selects a backup under:

   ```bash
   <backup_root>/<target_host>/full-*/
   ```

   - the **latest** backup by default
   - or the specified backup via `-t TIMESTAMP`

2. If **no restore paths** are provided:
   - it restores the exact paths listed in:

     ```bash
     source_list_<timestamp>.lst
     ```

     if available
   - otherwise it restores the entire selected backup tree

3. Optionally includes Portainer compose files when `-P` is used.
4. In a **real run**, stops all running Docker containers on the target host except those excluded with `-x`.
5. In a **dry-run**, skips all container stop/start operations completely.
6. Restores the selected data back to the target host using `rsync`.
7. Restarts the previously stopped containers automatically (real runs only).

## Important Behavior

- Restore paths, if specified, must be **absolute target paths**.
- Excluded containers remain running during restore.
- If restored data belongs to an excluded running container, the restore may be inconsistent.
- The restore script intentionally does **not** use `--delete` during restore.
- In dry-run mode, the script performs **no-disruption validation** only.

## Script-Specific Options

| Option | Description |
|--------|-------------|
| `-t TIMESTAMP` | Restore the exact backup with timestamp `YYYY-MM-DD-HH-MM` instead of the latest backup |
| `-P file` | Absolute path to Portainer's own `docker-compose.yml` on the target host. When set, the script also restores additional compose files discovered inside Portainer's data area from the selected backup set. |

## Restore Path Behavior

### If no paths are specified

The script restores:

1. the paths from `source_list_<timestamp>.lst`, if present  
2. otherwise the whole selected `full-<timestamp>/` tree

### If paths are specified

Only those absolute paths are restored, for example:

```bash
/etc
/var/lib/docker/volumes
/home/myuser/portainer
```

Each requested path is checked against the selected backup set. Paths that do not exist in that backup are skipped.

## Portainer Environments Restore

When `-P` is supplied:

1. The specified Portainer `docker-compose.yml` is added to the restore set.
2. The script detects the Portainer container on the target.
3. It resolves the host path mounted to `/data` inside that Portainer container.
4. It searches the **selected backup set** inside that Portainer data path for compose files such as:
   - `docker-compose.yml`
   - `docker-compose.yaml`
   - `compose.yml`
   - `compose.yaml`
5. All matching compose files found in the selected backup set are added to the restore set with full absolute paths.

## Examples

### Restore the latest full backup

```bash
restore-script.sh backupuser remote.example.com /backups
```

### Restore a specific backup

```bash
restore-script.sh -t 2026-03-13-13-28 backupuser remote.example.com /backups
```

### Restore only selected paths

```bash
restore-script.sh -t 2026-03-13-13-28 backupuser remote.example.com /backups /etc /var/lib/docker/volumes
```

### Dry-run restore while keeping `pihole` running

```bash
restore-script.sh -n -x pihole -t 2026-03-13-13-28 backupuser remote.example.com /backups /home/myuser/portainer
```

### Restore Portainer compose files too

```bash
restore-script.sh -P /home/myuser/portainer/docker-compose.yml -t 2026-03-13-13-28 backupuser remote.example.com /backups
```

---

## Logging, Metadata, and Retention

### Backup script output

`backup-script.sh` creates:

- Log files:

  ```bash
  <backup_root>/<target_host>/logs/bklog_YYYY-MM-DD-HH-MM.log
  ```

- Backup directories:

  ```bash
  <backup_root>/<target_host>/full-YYYY-MM-DD-HH-MM/
  ```

- Manifest files:

  ```bash
  <backup_root>/<target_host>/manifest_YYYY-MM-DD-HH-MM.tsv
  ```

- Source list files:

  ```bash
  <backup_root>/<target_host>/source_list_YYYY-MM-DD-HH-MM.lst
  ```

### Restore script output

`restore-script.sh` creates:

- Restore logs:

  ```bash
  <backup_root>/<target_host>/logs/restore_YYYY-MM-DD-HH-MM.log
  ```

### Retention

`backup-script.sh` keeps only the **4 most recent** of each of the following:

- `full-*` backup directories
- `logs/bklog_*.log`
- `manifest_*.tsv`
- `source_list_*.lst`

Older entries are removed automatically.

---

## Operational Notes

- Both scripts rely on `sudo -n`, so passwordless sudo must be configured correctly on the target host.
- If a container is excluded with `-x`, it remains running:
  - during **backup**, its data is still discovered and backed up live
  - during **restore**, its data may still be overwritten while the container is live
- Additional backup and restore paths should always be given as **absolute paths** to avoid ambiguity.
- Portainer compose file discovery depends on the Portainer container having a `/data` mount that maps to a host path.
- If you need fully consistent point-in-time backups, the target storage layout would need a real snapshot backend such as LVM, ZFS, Btrfs, or an external hypervisor/storage snapshot mechanism.
