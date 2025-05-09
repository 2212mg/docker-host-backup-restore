# Backup and Restore Scripts

This repository provides two Bash scripts for reliable, automated data protection and recovery of remote docker-hosts:

* `backup-script.sh`: Creates full backups of specified paths from a target host into a local backup root, with optional LVM/ZFS snapshotting, Docker container quiesce, parallelized rsync, logging, and retention.
* `restore-script.sh`: Restores a selected full backup (latest or specified) back to the target host via SSH, with Docker container management and the same rsync options.

## Usecase

* Backing up files including live docker volumes and bind mounts from a docker-host.
* Stopping and restarting containers is handeled by the scripts.

---

## Requirements

* **Bash** (v4+ recommended)
* **ssh** access from the backup server to the target host using key-based authentication
* **rsync** on both ends (supports `-aHAX --info=progress2 --delete`)
* **sudo** privileges on the target host for snapshot, rsync, and Docker commands (no password prompts)
* **LVM** or **ZFS** utilities (optional, for filesystem snapshots)
* **Docker CLI** on the target host

---

## Installation

1. Place both scripts in a directory on your backup server, e.g. `/usr/local/bin/`.
2. Mark them executable:

   ```bash
   chmod +x backup-script.sh restore-script.sh
   ```
3. Ensure the SSH identity (`~/.ssh/id_rsa`) and `authorized_keys` are set up for `$BACKUP_USER` on the target host.

---

## Common Options

Both scripts accept the following flags:

| Option            | Description                                                    |
| ----------------- | -------------------------------------------------------------- |
| `-h`              | Show help message and exit                                     |
| `-n`              | Dry-run mode (passes `--dry-run` to rsync)                     |
| `-b MBPS`         | Bandwidth limit in MB/s (sets `--bwlimit=$((MBPS*1024))`)      |
| `-p streams`      | Number of parallel rsync streams (default: 1)                  |
| `-x cont1,cont2`  | Comma-separated Docker containers to exclude from stop/restart |
| `-e exclude_file` | File of rsync exclude patterns                                 |

Additional, script-specific flags are described in their sections below.

---

## backup-script.sh

### Usage

```bash
backup-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> <path1> [<path2> ...]
```

### Description

1. **(Optional)** Creates an LVM snapshot or ZFS clone of the root filesystem (`-s` to skip).
2. Stops all running Docker containers on the target host (except excludes), recording stopped names.
3. Performs a **full** backup of specified paths via `rsync` with live progress, optional parallel streams, bandwidth limit, and excludes.
4. Restarts stopped containers and removes the temporary list file.
5. Cleans up the snapshot.
6. Prunes older backups and logs, retaining only the **4 most recent** full backups and logs.

### Script-Specific Options

| Option | Description                    |
| ------ | ------------------------------ |
| `-s`   | Skip LVM/ZFS snapshot creation |

### Examples

* Basic full backup of `/etc` and `/var/www`:

  ```bash
  backup-script.sh backupuser remote.example.com /backups /etc /var/www
  ```
* With snapshot skip, 4 parallel streams, and 20 MB/s limit:

  ```bash
  backup-script.sh -s -p 4 -b 20 backupuser remote.example.com /backups /home
  ```

---

## restore-script.sh

### Usage

```bash
restore-script.sh [OPTIONS] <backup_user> <target_host> <backup_root> [<path1> ...]
```

### Description

1. Selects a full backup directory under `<backup_root>/<target_host>/full-*/` (latest by default or `-t TIMESTAMP`).
2. Stops all running Docker containers on the target host (except excludes), recording stopped names.
3. Uses `rsync` to push the backup data (all paths or specified subpaths) back to the target host.
4. Restarts stopped containers and removes the temporary list file.

### Script-Specific Options

| Option         | Description                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------- |
| `-t TIMESTAMP` | Specify the exact full backup (format `YYYY-MM-DD-HH-MM`) to restore (default = latest full). |

### Examples

* Restore latest full backup entirely:

  ```bash
  restore-script.sh backupuser remote.example.com /backups
  ```
* Restore only `/etc/nginx` from a specific backup:

  ```bash
  restore-script.sh -t 2025-05-01-03-30 backupuser remote.example.com /backups /etc/nginx
  ```

---

## Logging & Retention

* **backup-script.sh** logs to: `<backup_root>/<target_host>/logs/bklog_YYYY-MM-DD-HH-MM.log`
* **restore-script.sh** logs to: `<backup_root>/<target_host>/logs/restore_YYYY-MM-DD-HH-MM.log`
* Both scripts keep the **4 most recent** log files and delete older ones automatically.
* Backups older than the 4th latest are also removed by `backup-script.sh`.

---

## Notes

* Adjust `SSH_OPTS` in each script if you require different SSH key paths or host key checking behavior.
* Ensure `sudo` on target host is password-less for the needed commands (`lvcreate`, `zfs`, `docker`, `rsync`).

---

*Maintained by Marco Gehm*
