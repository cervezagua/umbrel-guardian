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
| 🔄 **OTA-Resilient** | Survives Umbrel OS updates via the official pre-start hook |
| 🔌 **Backup Drive Auto-Mount** | udev hot-plug + boot service — mount backup drive automatically |
| 🔐 **Access Control** | Authorized users list + safe mode with PIN lock |
| 🛡 **Security Hardened** | Rate limiting, input validation, sandboxed systemd services |

---

## 📋 Requirements

- Umbrel OS (tested on **Umbrel 1.7.2**, Raspberry Pi 5 8 GB; compatible with 1.5+)
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram Chat ID (from [@userinfobot](https://t.me/userinfobot))
- *(Optional)* An external USB/SATA drive for backups

---

## 🚀 Install

```bash
cd ~/umbrel
sudo git clone https://github.com/yourname/umbrel-guardian
cd umbrel-guardian
sudo bash install.sh
```

The interactive installer walks you through **8 steps**:

1. 🔍 Auto-detect Umbrel directory
2. ⚙️ System prerequisites (Docker group, `python3-venv`)
3. 🐍 Python prerequisites (a venv is created inside the install dir in step 8)
4. 📱 Telegram bot token + chat ID + optional safe mode PIN
5. 💾 Backup drive selection (numbered menu with auto-detection)
6. 🩺 Health monitoring interval
7. 📦 Copy files to persistent install directory
8. 🔧 Install & enable systemd services + deploy OTA-recovery hook + build venv with `pip install -r requirements.txt`

---

## 🤖 Bot Commands

| Command | Description |
|---|---|
| `/status` | 🖥 System overview — disk, RAM, CPU, uptime, app count |
| `/uptime` | ⏱ System uptime |
| `/apps` | 📦 List installed apps with state — each line has a tappable `/restart_<id>` shortcut |
| `/health` | 🩺 Run a health check now and report results |
| `/restart <app_id>` | 🔄 Restart a specific app. Accepts prefix matches (e.g. `/restart adguard` resolves to `adguard-home`) |
| `/restart unhealthy` | 🔄 Restart apps in unknown/failed state (skips intentionally stopped apps) |
| `/logs <app_id> [n]` | 📋 Last N lines of an app's container logs (default: 50) |
| `/backup` | ⏳ Trigger a manual backup immediately |
| `/system_reboot` | 🔄 Reboot the Pi (2-step confirm; +60s grace) |
| `/system_shutdown` | ⏻ Power off the Pi (2-step confirm; needs physical access to restart) |
| `/restart_docker` | 🔄 Restart Docker daemon (2-step confirm; briefly interrupts all containers) |
| `/restart_umbrel` | 🔄 Restart umbreld (2-step confirm; brief web UI outage) |
| `/system_cancel` | ⛔ Cancel a pending reboot or shutdown (within the +60s grace window) |
| `/lock` | 🔒 Enable safe mode — disables dangerous commands |
| `/unlock <PIN>` | 🔓 Disable safe mode |
| `/help` | ❓ Show available commands |

### System control commands

`/system_reboot`, `/system_shutdown`, `/restart_docker`, `/restart_umbrel` all use a two-step confirmation flow to prevent accidental taps:

1. Send the command — bot replies with a warning and asks for confirmation
2. Reply `<command>_confirm` (e.g. `/system_reboot_confirm`) within **30 seconds**
3. Bot executes via a small wrapper script that runs as root via NOPASSWD sudoers

If you miss the 30-second window, the confirmation expires and you have to start over. For reboot/shutdown there's an additional **60-second grace period** after confirmation during which `/system_cancel` aborts the operation.

All four commands are blocked by `/lock` (you must `/unlock <PIN>` first). The sudoers entry at `/etc/sudoers.d/umbrel-guardian-system` allows *exactly* these five subcommands of `scripts/system_control.sh` — nothing else — and is re-deployed on every boot by `reinstall-services.sh` (because `/etc/sudoers.d/` is wiped each boot).

### `/restart` resolution

The app id can be given in any of these forms:

| You send | Resolves to | How |
|---|---|---|
| `/restart adguard-home` | `adguard-home` | exact match |
| `/restart adguard` | `adguard-home` | prefix match (unique) |
| `/restart_adguard_home` | `adguard-home` | tappable shortcut from `/apps`; underscores swapped to dashes |
| `/restart n` | _ambiguous_ | matches both `nextcloud` and `nostr-relay` — bot lists both as tappable suggestions |

`/apps` emits a `/restart_<id>` link after each app line; tapping it sends the right command. Telegram only auto-links commands matching `[a-zA-Z0-9_]`, so dashes in app ids are rewritten to underscores in the link and reversed at lookup.

---

## 📁 File Layout

```
umbrel-guardian/
├── install.sh                  ← Interactive installer
├── reinstall-services.sh       ← Re-install systemd services (post-OTA)
├── uninstall.sh                ← Clean removal
├── requirements.txt            ← Python deps installed into .venv at install time
│
├── bot/
│   └── guardian_bot.py         ← Telegram bot (runs via systemd, from .venv)
│
├── scripts/
│   ├── telegram_send.sh        ← Send a Telegram message
│   ├── system_status.sh        ← System overview
│   ├── apps_status.sh          ← App list via umbreld client / docker
│   ├── restart_app.sh          ← Restart a single app
│   ├── restart_unhealthy.sh    ← Restart apps in unknown state (skips stopped)
│   ├── app_logs.sh             ← App container logs (docker compose)
│   ├── health_check.sh         ← Proactive health alerts (timer)
│   ├── backup.sh               ← rsync backup with flock + rotation
│   └── mount-backup.sh         ← Mount backup drive (udev + boot + safety net)
│
├── services/
│   ├── umbrel-guardian-bot.service              ← Always-running bot
│   ├── umbrel-guardian-health.service           ← Health check (oneshot)
│   ├── umbrel-guardian-health.timer             ← Health check schedule
│   ├── umbrel-guardian-daily.service            ← Daily summary (oneshot)
│   ├── umbrel-guardian-daily.timer              ← Daily summary at 09:00
│   ├── umbrel-guardian-backup.service           ← Backup (oneshot, runs as root)
│   ├── umbrel-guardian-backup.timer             ← Backup schedule
│   ├── umbrel-guardian-backup-trigger.path      ← Watches for manual /backup trigger
│   ├── umbrel-guardian-mount-backup.service     ← Boot-time mount fallback
│   └── 99-umbrel-backup.rules                   ← udev rule for hot-plug auto-mount
│
└── custom-hooks/
    └── pre-start                                ← Deployed to /home/umbrel/umbrel/custom-hooks/
                                                  ←   for OTA-resilient service recovery
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
ReadWritePaths=/home/umbrel/umbrel/umbrel-guardian
MemoryMax=128M
CPUQuota=20%
```

> `NoNewPrivileges=yes` is intentionally **not** set because the bot needs `sudo` to invoke `system_control.sh` for the four system commands. The privilege boundary is instead enforced by `/etc/sudoers.d/umbrel-guardian-system`, which grants NOPASSWD access to *exactly* five exact subcommands and nothing else.

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

> ⚠️ **Before shutting down:** Unplug the backup drive first. Umbrel (Rugpi) cannot determine which drive is the data drive when two drives are connected at boot. The correct workflow is: **shut down** (not reboot) → unplug backup drive → boot → plug backup drive back in (auto-mounted by udev).

**Implementation note:** Modern `systemd-udevd` runs `RUN` handlers in a sandboxed mount namespace, so calling `mount` directly from a udev rule fails silently. The udev rule uses `systemd-run --no-block` to spawn the mount script as a transient systemd unit **outside** the sandbox, where mount works normally.

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

Umbrel OS uses A/B root partitions. OTA updates wipe `/etc/systemd/system/`, `/usr/local/bin/`, and `/etc/udev/rules.d/` — Guardian's units, mount script, and udev rule all disappear.

Guardian survives this through Umbrel's **official pre-start hook**, introduced in 1.7.x:

1. 📂 Install directory lives under `/home/umbrel/umbrel/` (bind-mounted from the persistent data partition — survives OTA).
2. 🪝 A small recovery script at `/home/umbrel/umbrel/custom-hooks/pre-start` is invoked on every boot by Umbrel's `umbrel-custom-pre-start.service` (wrapper at `/opt/umbrel-custom-hooks/run-pre-start`).
3. 🔧 The hook detects when Guardian's units are missing and runs `reinstall-services.sh`, which restores everything that an OTA wipes:
   - all `umbrel-guardian-*` systemd units in `/etc/systemd/system/`
   - the udev rule at `/etc/udev/rules.d/99-umbrel-backup.rules`
   - the mount script at `/usr/local/bin/mount-umbrel-backup.sh`
   - `umbrel` user's membership in the `docker` group (OTA rebuilds `/etc/group` and drops supplementary memberships)
   - executable bits on Guardian's scripts (defense against mode-stripping copies)
   - inotify watch limits in `/etc/sysctl.d/40-inotify-umbrel.conf` (Umbrel 1.7.x consumes more watches than the stock kernel limits allow; without this, `.path` units fail with "inotify watch limit reached")

   The Python venv at `.venv/` lives inside the install dir (persistent partition), so the bot can start instantly on every boot — no apt/pip dance needed. Only if the venv is missing (fresh install) or broken by a Python ABI bump (e.g., 3.13 → 3.14 on a future OTA) does `reinstall-services.sh` re-create it via `python3 -m venv && pip install -r requirements.txt`.

The hook runs with a 5-minute timeout and is designed to never block umbreld from starting even if it fails. No manual intervention needed after an Umbrel OS update.

**Trigger recovery manually (for testing or forced re-install):**

```bash
sudo /opt/umbrel-custom-hooks/run-pre-start    # idempotent — no-op if units exist
# or
sudo bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh
```

> **Note:** Earlier versions of Guardian used an `umbrel-guardian-bootstrap.service` for this. That pattern failed on Umbrel 1.7.x because the bootstrap unit itself lived in `/etc/systemd/system/` and got wiped along with everything else. `reinstall-services.sh` now removes any stale bootstrap unit it finds.

---

## 🩹 Troubleshooting

### `⚠️ partial: 1/2` for adguard-home / plex / tailscale (Umbrel 1.7.x bug)

Symptom: in `/apps`, host-network apps such as `adguard-home`, `plex`, and `tailscale` show as `⚠️ partial: 1/2`. The app's main container is running; the Tor sidecar (`<app>-tor_server-1`) is stuck in a restart loop.

Cause (Umbrel-side, not Guardian): umbreld's torrc generator points each app's `HiddenServicePort` at `app_proxy_<appname>`, but host-mode apps never spawn an `app_proxy` companion container. Tor can't resolve the target hostname and fails with `Unparseable address in hidden service port configuration`. Verify with:

```bash
sudo docker logs <app>-tor_server-1 --tail 20
sudo docker ps -a --format '{{.Names}}' | grep app_proxy    # only bridged apps appear here
```

Workarounds:

- **Wait for an Umbrel fix** — file upstream at [github.com/getumbrel/umbrel/issues](https://github.com/getumbrel/umbrel/issues). Guardian is reporting the issue correctly; the apps themselves still work on your LAN.
- **Disable Tor per affected app** via the Umbrel UI if your version supports it, or set `torEnabled: false` globally in `umbrel.yaml` to silence all sidecars (loses *all* `.onion` access).

Once Umbrel ships a fix, the sidecars come up cleanly and the `partial` warning disappears with no Guardian change needed.

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

## 🔄 Update

```bash
cd ~/umbrel/umbrel-guardian
sudo git pull
sudo bash reinstall-services.sh
```

Pulls the latest code and re-deploys systemd services. Your `config.env` is not tracked by git and won't be overwritten.

---

## 🗑 Uninstall

```bash
sudo bash /home/umbrel/umbrel/umbrel-guardian/uninstall.sh
```

Stops all services, removes systemd units and the install directory. Backup data on the external drive is **not** deleted.
