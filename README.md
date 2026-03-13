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

`backup-script.sh` performs a **live backup** from the target host.

### Workflow

1. Connects to the target host via SSH.
2. Detects all **currently running Docker containers**.
3. Inspects each running container and discovers host-side persistent storage:
   - bind mounts
   - named and anonymous Docker volumes
4. Optionally discovers Portainer-managed compose files when `-P` is used.
5. In a **real run**, stops all running containers **except** those excluded with `-x`.
6. In a **dry-run**, skips all container stop/start operations completely.
7. Backs up all discovered storage paths to the backup directory while preserving their **full absolute paths**.
8. Also backs up any **additional absolute paths** specified on the command line.
9. Restarts the previously stopped containers automatically (real runs only).
10. Prunes old backups and metadata files, keeping the **4 most recent** runs.

## Important Behavior

- Excluded containers are **still inspected**, and their discovered storage is **still backed up**.
- Excluded containers are **not stopped**, so their storage is backed up **live** and may therefore be inconsistent.
- `tmpfs` mounts are ignored because they are not persistent storage.
- `overlay2` writable layer paths are intentionally skipped.
- Additional CLI paths must be **absolute target paths**.
- In dry-run mode, the script performs **no-disruption validation** only.

## Script-Specific Options

| Option | Description |
|--------|-------------|
| `-s`   | Deprecated/no-op. Kept only for backward compatibility. |
| `-P file` | Absolute path to Portainer's own `docker-compose.yml` on the target host. When set, the script also discovers additional compose files stored inside Portainer's data area and backs them up with full absolute paths. |

## Portainer Environments Backup

When `-P` is supplied:

1. The specified Portainer `docker-compose.yml` is added to the backup set.
2. The script detects the Portainer container on the target.
3. It resolves the host path mounted to `/data` inside that Portainer container.
4. It searches that Portainer data path for additional compose files such as:
   - `docker-compose.yml`
   - `docker-compose.yaml`
   - `compose.yml`
   - `compose.yaml`
5. All discovered compose files are added to the backup set with their **full absolute paths**.

This is intended for setups where Portainer stores stack definitions inside its own data area.

## Output Structure

Backups are stored under:

```bash
<backup_root>/<target_host>/
```

Each run creates:

- a backup directory:

  ```bash
  full-YYYY-MM-DD-HH-MM/
  ```

- a log file:

  ```bash
  logs/bklog_YYYY-MM-DD-HH-MM.log
  ```

- a manifest file:

  ```bash
  manifest_YYYY-MM-DD-HH-MM.tsv
  ```

- a source list file:

  ```bash
  source_list_YYYY-MM-DD-HH-MM.lst
  ```

### Manifest file

The manifest records what the script discovered during inspection, including:

- container name
- container state (for example `would-stop-for-backup` or `live-excluded` in dry-run mode)
- storage kind (`bind`, `volume`, `compose-file`, etc.)
- host-side path
- optional notes

### Source list file

The source list contains the final set of validated host paths that were actually selected for backup.

## Examples

### Back up only automatically discovered Docker storage

```bash
backup-script.sh backupuser remote.example.com /backups
```

### Back up Docker storage but keep `pihole` running

```bash
backup-script.sh -x pihole backupuser remote.example.com /backups
```

### Back up Docker storage plus additional absolute paths

```bash
backup-script.sh -x pihole backupuser remote.example.com /backups /etc /home/marco/portainer
```

### Dry-run without disrupting running containers

```bash
backup-script.sh -n -x pihole backupuser remote.example.com /backups /etc
```

### Back up Portainer compose files too

```bash
backup-script.sh -P /home/marco/portainer/docker-compose.yml backupuser remote.example.com /backups
```

### Dry-run with Portainer compose file discovery

```bash
backup-script.sh -n -x pihole -P /home/marco/portainer/docker-compose.yml backupuser remote.example.com /backups
```

---

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
/home/marco/portainer
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
restore-script.sh -n -x pihole -t 2026-03-13-13-28 backupuser remote.example.com /backups /home/marco/portainer
```

### Restore Portainer compose files too

```bash
restore-script.sh -P /home/marco/portainer/docker-compose.yml -t 2026-03-13-13-28 backupuser remote.example.com /backups
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

---

## Maintainer

Maintained by **Marco Gehm**
