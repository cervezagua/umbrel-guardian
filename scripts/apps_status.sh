#!/usr/bin/env bash
# List all installed Umbrel apps with their current state.
#
# Uses umbreld for the authoritative app list + state (ready / stopped /
# unknown / transient), then cross-checks docker for actual container
# health. This way "stopped" apps display as intentionally off (not as
# crashes), and "ready" apps that have crashed containers are flagged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
source "$CONFIG"

UMBREL_DATA="${UMBREL_DIR:-/home/umbrel/umbrel}"
APP_DATA="$UMBREL_DATA/app-data"

if ! command -v docker &>/dev/null; then
    echo "⚠️ docker not found — is this an Umbrel system?"
    exit 1
fi

if [ ! -d "$APP_DATA" ]; then
    echo "⚠️ App data directory not found: $APP_DATA"
    exit 1
fi

# Snapshot all container names + states once
ALL=$(docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)

# Pull authoritative app list + state from umbreld (1.7.x: state is "ready",
# "stopped", "starting", etc.). Falls back to filesystem-only enumeration
# if umbreld is unreachable.
APP_STATES=""
if command -v umbreld &>/dev/null; then
    APP_STATES=$(umbreld client apps.list.query 2>&1 | python3 -c "
import sys, json
raw = sys.stdin.read()
decoder = json.JSONDecoder()
apps = None
try:
    apps, _ = decoder.raw_decode(raw.lstrip())
except (json.JSONDecodeError, ValueError):
    idx = raw.find('[')
    if idx != -1:
        try:
            apps, _ = decoder.raw_decode(raw, idx)
        except (json.JSONDecodeError, ValueError):
            pass
if apps is None:
    sys.exit(0)
for a in apps:
    print(f\"{a.get('id','')}\\t{a.get('state','unknown')}\")
" 2>/dev/null) || true
fi

# Build an associative lookup: app_id → umbreld state
declare -A UMBREL_STATE
while IFS=$'\t' read -r app_id state; do
    [ -n "$app_id" ] && UMBREL_STATE["$app_id"]="$state"
done <<< "$APP_STATES"

echo "📦 Installed Apps"
echo "━━━━━━━━━━━━━━━━━━"

# Use umbreld's app list as the authoritative source — uninstalled apps may
# leave data directories behind in app-data/, and we don't want to show those.
# Fall back to filesystem enumeration only if umbreld returned no apps.
APP_IDS=()
if [ "${#UMBREL_STATE[@]}" -gt 0 ]; then
    APP_IDS=("${!UMBREL_STATE[@]}")
else
    for app_dir in "$APP_DATA"/*/; do
        [ -d "$app_dir" ] || continue
        APP_IDS+=("$(basename "$app_dir")")
    done
fi

# Sort for deterministic output
mapfile -t APP_IDS < <(printf "%s\n" "${APP_IDS[@]}" | sort)

FOUND=0
for app_id in "${APP_IDS[@]}"; do
    [ -n "$app_id" ] || continue
    FOUND=$((FOUND + 1))

    state="${UMBREL_STATE[$app_id]:-}"

    # Intentional off (user stopped it) — show but don't flag
    if [ "$state" = "stopped" ]; then
        echo "⏸ $app_id  (stopped)"
        continue
    fi

    # Transient states — show as in-flight
    case "$state" in
        starting|installing|updating|restarting|stopping|uninstalling)
            echo "🔄 $app_id  ($state)"
            continue
            ;;
    esac

    # Cross-check container health. Compose v1 uses underscores, v2 uses dashes.
    app_lines=$(echo "$ALL" | grep -E "^${app_id}[_-]" 2>/dev/null || true)

    if [ -z "$app_lines" ]; then
        # No containers found — fall back to whatever umbreld says
        if [ -n "$state" ]; then
            echo "❌ $app_id  ($state, no containers)"
        else
            echo "❌ $app_id  (no containers)"
        fi
        continue
    fi

    total=$(echo "$app_lines" | wc -l)
    running=$(echo "$app_lines" | grep -c " running$" || true)

    if [ "$running" -eq "$total" ]; then
        echo "✅ $app_id  (running)"
    elif [ "$running" -gt 0 ]; then
        echo "⚠️ $app_id  (partial: $running/$total)"
    else
        container_state=$(echo "$app_lines" | head -1 | awk '{print $NF}')
        echo "❌ $app_id  ($container_state)"
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "No apps installed."
fi
