#!/usr/bin/env bash
# Umbrel Guardian — Interactive Installer
# Supports Umbrel OS. Run as the umbrel user (or with sudo).
set -euo pipefail

INSTALL_DIR="/home/umbrel/umbrel/umbrel-guardian"
SYSTEMD_DIR="/etc/systemd/system"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

print_header() {
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║        🛡  Umbrel Guardian            ║"
    echo "║           Installer v1.0             ║"
    echo "╚══════════════════════════════════════╝"
    echo
}

step() {
    echo
    echo "── STEP $1: $2 ──────────────────────────"
}

ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
err()  { echo "  ❌ $*" >&2; exit 1; }

# ── Main ─────────────────────────────────────────────────────────────────────

print_header

# ─ Detect Umbrel ─────────────────────────────────────────────────────────────
step 1 "Detect Umbrel"

if [ -d "/home/umbrel/umbrel" ]; then
    UMBREL_DIR="/home/umbrel/umbrel"
    ok "Umbrel detected at $UMBREL_DIR"
else
    warn "Could not auto-detect Umbrel installation."
    read -rp "  Enter your Umbrel directory [/home/umbrel/umbrel]: " INPUT
    UMBREL_DIR="${INPUT:-/home/umbrel/umbrel}"
    [ -d "$UMBREL_DIR" ] || err "Directory not found: $UMBREL_DIR"
    ok "Using $UMBREL_DIR"
fi

# ─ System prerequisites ──────────────────────────────────────────────────────
step 2 "System Prerequisites"

# Ensure umbrel user can access Docker (needed for /logs command)
if getent group docker &>/dev/null; then
    if ! id -nG umbrel 2>/dev/null | grep -qw docker; then
        usermod -aG docker umbrel
        ok "Added umbrel to docker group (active after service restart)"
    else
        ok "umbrel is in docker group"
    fi
else
    warn "docker group not found — /logs command may not work"
fi

# ─ Python / requests check ───────────────────────────────────────────────────
step 3 "Python Dependencies"

if ! command -v python3 &>/dev/null; then
    err "python3 is not installed. Please install it first: sudo apt install python3"
fi
ok "python3 found: $(python3 --version)"

if python3 -c "import requests" &>/dev/null; then
    ok "requests library already installed"
else
    warn "requests library not found — installing now..."

    # Method 1: apt — preferred on Raspberry Pi OS / Debian (no pip needed, no PEP 668 conflict)
    if apt-get install -y python3-requests &>/dev/null 2>&1; then
        ok "requests installed via apt"

    # Method 2: pip with --break-system-packages — required on Bookworm (PEP 668)
    elif python3 -m pip install --quiet --break-system-packages requests 2>/dev/null; then
        ok "requests installed via pip (--break-system-packages)"

    # Method 3: plain pip — works on older distros without PEP 668
    elif python3 -m pip install --quiet requests 2>/dev/null; then
        ok "requests installed via pip"

    # Method 4: pip3 binary — some distros install it separately
    elif pip3 install --quiet requests 2>/dev/null; then
        ok "requests installed via pip3"

    else
        warn "Could not install requests automatically."
        echo "  Try one of these manually, then re-run install.sh:"
        echo
        echo "    sudo apt install python3-requests"
        echo "    python3 -m pip install --break-system-packages requests"
        echo "    python3 -m pip install requests"
        echo
        exit 1
    fi
fi

# ─ Telegram setup ─────────────────────────────────────────────────────────────
step 4 "Telegram Bot Setup"

echo "  1. Talk to @BotFather on Telegram → /newbot → copy the token"
echo "  2. Talk to @userinfobot → it replies with your Chat ID"
echo
read -rp "  Bot Token: " BOT_TOKEN
[ -z "$BOT_TOKEN" ] && err "Bot token cannot be empty."

read -rp "  Chat ID: " CHAT_ID
[ -z "$CHAT_ID" ] && err "Chat ID cannot be empty."

echo
echo "  Safe mode lets you /lock the bot to disable dangerous commands."
echo "  Set a PIN to unlock. Leave blank to skip."
read -rp "  Safe mode PIN (optional): " LOCK_PIN

# ─ Backup drive ────────────────────────────────────────────────────────────────
step 5 "Backup Drive"

BACKUP_SCOPE="essential"
BACKUP_TIME="02:00"
BACKUP_PATH=""
AUTO_MOUNT="n"

# Build a list of non-system partitions that could be backup targets.
# Excludes: SD card (mmcblk*), zram, loop, and the Umbrel data partition.
# Uses $NF=="part" because lsblk collapses empty columns (e.g. no MOUNTPOINT
# shifts TYPE from field 5 to field 4).
mapfile -t BACKUP_CANDIDATES < <(
    lsblk -lnpo NAME,SIZE,LABEL,MOUNTPOINT,TYPE 2>/dev/null \
        | awk '$NF=="part"' \
        | grep -v 'mmcblk\|loop\|zram' \
        | grep -v '/mnt/root/mnt/data\|/mnt/data' \
        | grep -v '/run/rugpi\|/boot'
)

if [ "${#BACKUP_CANDIDATES[@]}" -eq 0 ]; then
    warn "No backup drive detected."
    echo "     Plug in a USB/external drive and re-run install.sh to enable backups."
    echo
else
    echo "  Detected backup-capable drives:"
    echo
    idx=1
    declare -a CANDIDATE_PATHS=()
    declare -a CANDIDATE_NAMES=()
    for line in "${BACKUP_CANDIDATES[@]}"; do
        cand_dev=$(echo "$line"  | awk '{print $1}')
        cand_size=$(echo "$line" | awk '{print $2}')
        cand_label=$(echo "$line" | awk '{print $3}')
        cand_mount=$(echo "$line" | awk 'NF==5{print $4}')
        [ "$cand_label" = "-" ] || [ -z "$cand_label" ] && cand_label="(no label)"
        display="${cand_dev}  ${cand_size}  ${cand_label}"
        [ -n "$cand_mount" ] && display="$display  mounted at $cand_mount"
        echo "    ${idx}) ${display}"
        CANDIDATE_PATHS+=("$cand_mount")
        CANDIDATE_NAMES+=("$cand_dev")
        idx=$((idx + 1))
    done
    echo "    ${idx}) Skip backups"
    echo
    read -rp "  Select drive [${idx}]: " DRIVE_CHOICE
    DRIVE_CHOICE="${DRIVE_CHOICE:-$idx}"

    if [ "$DRIVE_CHOICE" -lt "$idx" ] 2>/dev/null && [ "$DRIVE_CHOICE" -ge 1 ]; then
        sel_idx=$((DRIVE_CHOICE - 1))
        sel_mount="${CANDIDATE_PATHS[$sel_idx]}"
        sel_dev="${CANDIDATE_NAMES[$sel_idx]}"

        # If not currently mounted, check for label and set up auto-mount path
        if [ -z "$sel_mount" ]; then
            # rugpi A/B systems mount persistent data under /mnt/root
            if [ -d "/mnt/root" ]; then
                MNT_PREFIX="/mnt/root/mnt"
            else
                MNT_PREFIX="/mnt"
            fi
            sel_label=$(blkid -o value -s LABEL "$sel_dev" 2>/dev/null || true)
            if [ -n "$sel_label" ]; then
                BACKUP_PATH="${MNT_PREFIX}/${sel_label}"
            else
                BACKUP_PATH="${MNT_PREFIX}/umbrel-backup"
            fi
            warn "Drive is not currently mounted. It will be auto-mounted at $BACKUP_PATH"
        else
            BACKUP_PATH="$sel_mount"
        fi

        ok "Backup drive: $sel_dev → $BACKUP_PATH"

        echo
        echo "  Backup scope:"
        echo
        echo "    1) Essential  (default, fast)"
        echo "       app-data/, db/, secrets/"
        echo "       Restores all apps and their configs. Typically a few GBs."
        echo
        echo "    2) Full clone"
        echo "       Mirrors the entire Umbrel directory with rsync --delete."
        echo "       ⚠️  Includes Bitcoin blockchain data if installed (500 GB+)."
        echo "       Slow and storage-heavy, but a complete 1:1 copy."
        echo
        read -rp "  Choice [1]: " SCOPE_CHOICE
        case "${SCOPE_CHOICE:-1}" in
            2) BACKUP_SCOPE="full" ;;
            *) BACKUP_SCOPE="essential" ;;
        esac

        echo
        LOCAL_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)
        LOCAL_TIME=$(date +%H:%M)
        UTC_TIME=$(date -u +%H:%M)
        echo "  ⏰ Server time: $LOCAL_TIME ($LOCAL_TZ) | UTC: $UTC_TIME"
        echo "  Enter the time in UTC. Umbrel OS always runs in UTC."
        read -rp "  Daily backup time in UTC, 24h format [02:00]: " INPUT
        BACKUP_TIME="${INPUT:-02:00}"
        ok "Backup scheduled at $BACKUP_TIME UTC daily ($BACKUP_SCOPE scope)"

        # Auto-mount by label — avoids the Umbrel dual-drive boot problem
        echo
        echo "  ⚠️  Umbrel OS only supports ONE external drive at boot."
        echo "     If the backup drive is plugged in during boot, Umbrel"
        echo "     may fail to detect the data drive."
        echo
        echo "  Auto-mount uses a udev rule to detect the backup drive by label"
        echo "  and mount it automatically — both at boot and when hot-plugged."
        echo "  This keeps both drives plugged in safely during normal operation."
        echo
        DRIVE_LABEL=$(blkid -o value -s LABEL "$sel_dev" 2>/dev/null || true)
        if [ -n "$DRIVE_LABEL" ]; then
            ok "Drive label: '$DRIVE_LABEL'"
        else
            warn "Drive has no filesystem label."
            echo "     To label it: sudo e2label $sel_dev umbrel-backup"
        fi
        read -rp "  Enable auto-mount (udev + boot)? [Y/n]: " AUTO_MOUNT
        AUTO_MOUNT="${AUTO_MOUNT:-y}"
    fi
fi

# ─ Health monitoring ─────────────────────────────────────────────────────────
step 6 "Health Monitoring Interval"

echo "  1) Every 15 minutes"
echo "  2) Every 30 minutes (default)"
echo "  3) Every 1 hour"
echo "  4) Every 3 hours"
echo "  5) Every 12 hours"
read -rp "  Choice [2]: " HEALTH_CHOICE

case "${HEALTH_CHOICE:-2}" in
    1) HEALTH_INTERVAL="*:0/15"  ;;
    3) HEALTH_INTERVAL="hourly"  ;;
    4) HEALTH_INTERVAL="0/3:00"  ;;
    5) HEALTH_INTERVAL="0/12:00" ;;
    *) HEALTH_INTERVAL="*:0/30"  ;;
esac

ok "Health checks every: $HEALTH_INTERVAL"

# ─ Install files ──────────────────────────────────────────────────────────────
step 7 "Installing Files"

# Pre-flight: verify all required source directories exist before touching anything
for _dir in bot scripts services; do
    if [ ! -d "$SOURCE_DIR/$_dir" ]; then
        err "Repository is incomplete — missing directory: $SOURCE_DIR/$_dir
  Make sure you cloned the full repository and all directories are present."
    fi
done

mkdir -p "$INSTALL_DIR"/{bot,scripts,services}

if [ "$SOURCE_DIR" != "$INSTALL_DIR" ]; then
    # Use /. (not /*) so the copy works regardless of directory contents
    # and avoids glob-expansion failures under set -e when there are no matches.
    cp -r "$SOURCE_DIR/bot/."      "$INSTALL_DIR/bot/"
    cp -r "$SOURCE_DIR/scripts/."  "$INSTALL_DIR/scripts/"
    cp -r "$SOURCE_DIR/services/." "$INSTALL_DIR/services/"
    cp    "$SOURCE_DIR/reinstall-services.sh" "$INSTALL_DIR/"
    cp    "$SOURCE_DIR/uninstall.sh"          "$INSTALL_DIR/"
    ok "Files copied to $INSTALL_DIR"
else
    ok "Running from install directory — skipping copy"
fi

chmod +x "$INSTALL_DIR/scripts/"*.sh
chmod +x "$INSTALL_DIR/reinstall-services.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

# ─ Write config ──────────────────────────────────────────────────────────────
CONFIG="$INSTALL_DIR/config.env"

cat > "$CONFIG" <<EOF
# Umbrel Guardian config — generated $(date)
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}
# CHAT_IDS=id1,id2   ← uncomment and use this for multiple admin accounts
ALLOWED_USERS=${CHAT_ID}
UMBREL_DIR=${UMBREL_DIR}
BACKUP_PATH=${BACKUP_PATH}
BACKUP_SCOPE=${BACKUP_SCOPE}
BACKUP_TIME=${BACKUP_TIME}
BACKUP_KEEP=3
AUTO_MOUNT=${AUTO_MOUNT:-n}
DISK_THRESHOLD=90
HEALTH_INTERVAL=${HEALTH_INTERVAL}
INSTALL_DIR=${INSTALL_DIR}
LOCK_PIN=${LOCK_PIN}
EOF

chmod 600 "$CONFIG"               # protect token from other users
chmod -R 750 "$INSTALL_DIR"       # owner rwx, group rx, others none
chown -R umbrel:umbrel "$INSTALL_DIR"  # service runs as umbrel — must own all files
ok "Config written to $CONFIG"

# ─ Install systemd services ──────────────────────────────────────────────────
step 8 "Installing systemd Services"

# Make the reinstall script executable
chmod +x "$INSTALL_DIR/reinstall-services.sh"

# Use the shared reinstall script — it copies service files to /etc/systemd/system,
# patches OnCalendar values, adds ConditionPathIsMountPoint for backup,
# installs the bootstrap service for OTA-update resilience, and enables everything.
bash "$INSTALL_DIR/reinstall-services.sh"

ok "Services enabled and started"

# ─ Done ──────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════╗"
echo "║  ✅ Umbrel Guardian installed!           ║"
echo "╚══════════════════════════════════════════╝"
echo
echo "  Telegram bot:    systemctl status umbrel-guardian-bot"
echo "  Health timer:    systemctl status umbrel-guardian-health.timer"
echo "  Daily summary:   systemctl status umbrel-guardian-daily.timer"
[ -n "$BACKUP_PATH" ] && \
echo "  Backup timer:    systemctl status umbrel-guardian-backup.timer"
echo
echo "  Logs:            journalctl -u umbrel-guardian-bot -f"
echo "  Uninstall:       ./uninstall.sh"
echo
