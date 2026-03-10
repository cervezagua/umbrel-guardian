# 🛡 Umbrel Guardian

A lightweight monitoring, backup, and Telegram bot toolkit for **Umbrel OS**.
Runs directly on the host — no Umbrel app store required, no modifications to Umbrel core.

---

## ✨ Features

| Feature | Description |
|---|---|
| 🤖 **Telegram Bot** | Always-running bot — control your node from your phone |
| 🚨 **Health Alerts** | Proactive notifications for high disk usage & unhealthy apps |
| 💾 **Automated Backups** | Daily rsync to an external drive with rotation and Telegram notifications |
| 📊 **Daily Summary** | Morning status report delivered to Telegram at 09:00 |
| 🔄 **OTA-Resilient** | Survives Umbrel OS updates via bootstrap service |
| 🔌 **Backup Drive Auto-Mount** | udev hot-plug + boot service — mount backup drive automatically |
| 🔐 **Access Control** | Authorized users list + safe mode with PIN lock |
| 🛡 **Security Hardened** | Rate limiting, input validation, sandboxed systemd services |

---

## 📋 Requirements

- Umbrel OS (tested on **Umbrel 1.5**, Raspberry Pi 5 8 GB)
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram Chat ID (from [@userinfobot](https://t.me/userinfobot))
- *(Optional)* An external USB/SATA drive for backups

---

## 🚀 Install

```bash
git clone https://github.com/yourname/umbrel-guardian
cd umbrel-guardian
sudo bash install.sh
```

The interactive installer walks you through **8 steps**:

1. 🔍 Auto-detect Umbrel directory
2. ⚙️ System prerequisites (Docker group, etc.)
3. 🐍 Python dependency check
4. 📱 Telegram bot token + chat ID + optional safe mode PIN
5. 💾 Backup drive selection (numbered menu with auto-detection)
6. 🩺 Health monitoring interval
7. 📦 Copy files to persistent install directory
8. 🔧 Install & enable systemd services

---

## 🤖 Bot Commands

| Command | Description |
|---|---|
| `/status` | 🖥 System overview — disk, RAM, CPU, uptime, app count |
| `/uptime` | ⏱ System uptime |
| `/apps` | 📦 List all installed apps with running/stopped state |
| `/health` | 🩺 Run a health check now and report results |
| `/restart <app_id>` | 🔄 Restart a specific app by its ID |
| `/restart unhealthy` | 🔄 Restart all apps not in "ready" state |
| `/logs <app_id> [n]` | 📋 Last N lines of an app's container logs (default: 50) |
| `/backup` | ⏳ Trigger a manual backup immediately |
| `/lock` | 🔒 Enable safe mode — disables dangerous commands |
| `/unlock <PIN>` | 🔓 Disable safe mode |
| `/help` | ❓ Show available commands |

---

## 📁 File Layout

```
umbrel-guardian/
├── install.sh                  ← Interactive installer
├── reinstall-services.sh       ← Re-install systemd services (post-OTA)
├── uninstall.sh                ← Clean removal
│
├── bot/
│   └── guardian_bot.py         ← Telegram bot (runs via systemd)
│
├── scripts/
│   ├── telegram_send.sh        ← Send a Telegram message
│   ├── system_status.sh        ← System overview
│   ├── apps_status.sh          ← App list via umbreld client / docker
│   ├── restart_app.sh          ← Restart a single app
│   ├── restart_unhealthy.sh    ← Restart all non-ready apps
│   ├── app_logs.sh             ← App container logs (docker compose)
│   ├── health_check.sh         ← Proactive health alerts (timer)
│   ├── backup.sh               ← rsync backup with flock + rotation
│   └── mount-backup.sh         ← Mount backup drive (udev + boot + safety net)
│
└── services/
    ├── umbrel-guardian-bot.service              ← Always-running bot
    ├── umbrel-guardian-health.service           ← Health check (oneshot)
    ├── umbrel-guardian-health.timer             ← Health check schedule
    ├── umbrel-guardian-daily.service            ← Daily summary (oneshot)
    ├── umbrel-guardian-daily.timer              ← Daily summary at 09:00
    ├── umbrel-guardian-backup.service           ← Backup (oneshot, runs as root)
    ├── umbrel-guardian-backup.timer             ← Backup schedule
    ├── umbrel-guardian-backup-trigger.path      ← Watches for manual /backup trigger
    ├── umbrel-guardian-mount-backup.service     ← Boot-time mount fallback
    └── 99-umbrel-backup.rules                  ← udev rule for hot-plug auto-mount
```

---

## ⚙️ Configuration

After install, edit `/home/umbrel/umbrel/umbrel-guardian/config.env`:

```env
BOT_TOKEN=your_token_here

# Single admin
CHAT_ID=your_chat_id

# Multiple admins (comma-separated) — overrides CHAT_ID for notifications
# CHAT_IDS=123456789,987654321

# Who can issue commands (defaults to CHAT_ID/CHAT_IDS if not set)
# ALLOWED_USERS=123456789

UMBREL_DIR=/home/umbrel/umbrel
BACKUP_PATH=/mnt/root/mnt/umbrel-backup  # rugpi: /mnt/root/mnt/... — non-rugpi: /mnt/...
BACKUP_SCOPE=essential    # essential (app-data + db + secrets) | full (entire Umbrel dir)
BACKUP_KEEP=3             # number of essential snapshots to retain
BACKUP_TIME=02:00         # daily backup time (24h, UTC)
AUTO_MOUNT=y              # auto-mount backup drive by label (udev hot-plug + boot)
DISK_THRESHOLD=90         # alert when disk exceeds this %
LOCK_PIN=                 # PIN for /lock / /unlock safe mode (leave blank to disable)
```

**Reload config** without restarting the bot (no downtime):

```bash
kill -HUP $(systemctl show -p MainPID umbrel-guardian-bot | cut -d= -f2)
```

---

## 💾 Backup

### Scopes

| Scope | What's backed up | Size |
|---|---|---|
| `essential` | `app-data/`, `db/`, `secrets/` | A few GB — fast |
| `full` | Entire `UMBREL_DIR` via `rsync --delete` | 500 GB+ if Bitcoin installed — slow |

### Rotation

- **Essential** backups are date-stamped (`umbrel-backup-2026-03-07_0200/`). Old ones are pruned to keep the last `BACKUP_KEEP` copies.
- **Full** clone is a rolling mirror — always one copy, always current.

### Manual Trigger

The `/backup` bot command touches a trigger file. A systemd `.path` unit watches for it and starts `umbrel-guardian-backup.service` as root. No `sudo` or elevated bot permissions required.

### Safety Features

- 🔒 **flock** prevents concurrent backup runs
- ⚡ **ionice/nice** keeps the Pi responsive during rsync
- 🧪 **Atomic staging** — rsync writes to `.tmp`, renamed on success only
- 📡 **Telegram notifications** on success and failure (with rsync error output)
- 🔌 **mountpoint check** — refuses to run if backup drive isn't mounted
- 🔧 **mount safety net** — `backup.sh` calls the mount script before starting, ensuring the drive is mounted even if udev missed it

---

## 🔁 Restore

If your main Umbrel data drive fails, follow these steps to restore from backup.

### Step 1 — Boot fresh Umbrel on new hardware

Flash Umbrel OS to a new SD card, connect a new data drive, let it fully boot and initialize. **Don't configure or install any apps yet** — you just need the base filesystem created.

### Step 2 — Stop Umbrel and mount the backup drive

```bash
sudo systemctl stop umbreld

sudo mkdir -p /mnt/restore
sudo mount /dev/sdb1 /mnt/restore      # adjust device — use lsblk to find it
ls /mnt/restore/                        # confirm backup contents are visible
```

### Step 3 — Restore data

**Full clone:**
```bash
sudo rsync -a --delete /mnt/restore/umbrel-full-clone/ /home/umbrel/umbrel/
sudo chown -R umbrel:umbrel /home/umbrel/umbrel/
```

**Essential (use the most recent snapshot):**
```bash
# List available snapshots — pick the most recent dated folder:
ls -lt /mnt/restore/ | head

SNAP="/mnt/restore/umbrel-backup-2026-03-09_0200"   # replace with your latest dated folder
sudo rsync -a "$SNAP/app-data/" /home/umbrel/umbrel/app-data/
sudo rsync -a "$SNAP/db/"       /home/umbrel/umbrel/db/
sudo rsync -a "$SNAP/secrets/"  /home/umbrel/umbrel/secrets/
sudo chown -R umbrel:umbrel /home/umbrel/umbrel/
```

### Step 4 — Shut down, unplug backup drive, power on

```bash
sudo shutdown -h now
```

After shutdown, **unplug the backup drive**, then power on. Umbrel (Rugpi) cannot boot with two external drives attached. Umbrel will come back up with all apps, data, and your original password restored.

---

### What each directory contains

| Directory | Contents |
|---|---|
| `secrets/` | Cryptographic keys — **required** to log in after restore |
| `db/` | App registry and Umbrel settings |
| `app-data/` | All app data (Nextcloud files, Bitcoin wallet, app configs, etc.) |

> ⚠️ **`secrets/` is critical.** Without it you cannot log into the restored Umbrel even if you remember your password. Both backup scopes include it.

### Notes

- **Bitcoin blockchain** — included in both `essential` (`app-data/bitcoin/`) and `full` scope. No re-sync needed.
- **Lightning channels** — included in `app-data/lightning/`. Channel state is restored as of the last backup.
- **Same Pi, new data drive** — works identically to the steps above.
- **Different Pi hardware** — also works. Umbrel is not tied to hardware IDs. Reconfigure Wi-Fi if needed.

---

## 🔐 Security

### Bot Hardening

The bot service (`umbrel-guardian-bot.service`) runs with a minimal privilege set:

```ini
PrivateTmp=yes
ProtectSystem=strict
NoNewPrivileges=yes
ReadWritePaths=/home/umbrel/umbrel/umbrel-guardian
MemoryMax=128M
CPUQuota=20%
```

### Input Validation

- App IDs are validated against `^[a-zA-Z0-9_-]{1,64}$` before being passed to any script
- Log lines are truncated to 500 characters to prevent Telegram flooding
- Only private chats are accepted — group/channel messages are ignored

### Rate Limiting

Commands have a 5-second cooldown per user. Informational commands (`/help`, `/start`) are exempt.

### Safe Mode

```
/lock        — Disables all commands except /status, /apps, /health, /uptime, /help
/unlock PIN  — Restores full access
```

Set `LOCK_PIN` in `config.env` during install (or manually) to enable. If no PIN is configured, `/lock` is blocked.

### Authorized Users

Only chat IDs listed in `ALLOWED_USERS` (or `CHAT_ID`/`CHAT_IDS`) can issue commands. All others are silently ignored and logged.

---

## 🔌 Dual-Drive Boot Workaround

Umbrel OS only supports **one external drive at boot**. If a second drive is plugged in, `umbrel-external-storage` exits with an error and Umbrel fails to mount the data drive.

**Umbrel Guardian's solution:** A **udev rule** detects the backup drive by filesystem label and auto-mounts it — both at boot (via systemd service) and when **hot-plugged** (via udev). Both drives stay plugged in safely during normal operation.

> ⚠️ **Before shutting down:** Unplug the backup drive first. Umbrel (Rugpi) cannot determine which drive is the data drive when two drives are connected at boot. The correct workflow is: **shut down** (not reboot) -> unplug backup drive -> boot -> plug backup drive back in (auto-mounted by udev).

```bash
# Label your backup drive (one-time, no formatting needed):
sudo e2label /dev/sdXN umbrel-backup
```

### Manual Mount Fallback

If auto-mount fails (udev rule missing after OTA, or other edge case), mount the backup drive manually:

```bash
sudo mkdir -p /mnt/umbrel-backup           # or your configured BACKUP_PATH
sudo mount /dev/sdb1 /mnt/umbrel-backup    # adjust device — use lsblk to find it
sudo chown umbrel:umbrel /mnt/umbrel-backup
```

Or run the mount script directly:

```bash
sudo /usr/local/bin/mount-umbrel-backup.sh
```

To re-deploy the udev rule after an OTA update:

```bash
sudo bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh
```

---

## 🔄 OTA Update Resilience

Umbrel OS uses A/B root partitions. OTA updates may wipe `/etc/systemd/system/`.

Guardian survives this because:

1. 📂 Install directory lives under `/home` (bind-mounted from persistent data partition)
2. 🔧 `umbrel-guardian-bootstrap.service` is written to `/etc/systemd/system/` by `reinstall-services.sh`. It detects when Guardian services are missing after an OTA wipe and re-installs them automatically.

No manual intervention needed after an Umbrel OS update.

---

## 🛠 Useful Commands

```bash
# 📊 Check bot status
systemctl status umbrel-guardian-bot

# 📜 View bot and backup logs together
journalctl -u umbrel-guardian-bot -u umbrel-guardian-backup -f

# 🩺 Manual health check
/home/umbrel/umbrel/umbrel-guardian/scripts/health_check.sh --force

# 💾 Manual backup (runs as root via systemd)
sudo bash /home/umbrel/umbrel/umbrel-guardian/scripts/backup.sh

# 🔌 Mount backup drive manually (if auto-mount missed it)
sudo /usr/local/bin/mount-umbrel-backup.sh

# ⏱ Check timer schedules
systemctl list-timers 'umbrel-guardian-*'

# 🔁 Re-install services after OTA update
sudo bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh

# 🗑 Uninstall
sudo bash /home/umbrel/umbrel/umbrel-guardian/uninstall.sh
```

---

## 🗑 Uninstall

```bash
sudo bash /home/umbrel/umbrel/umbrel-guardian/uninstall.sh
```

Stops all services, removes systemd units and the install directory. Backup data on the external drive is **not** deleted.
