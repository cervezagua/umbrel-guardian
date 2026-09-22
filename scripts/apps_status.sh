#!/usr/bin/env bash
# List all installed Umbrel apps with their current state.
#
# Uses umbreld for the authoritative app list + state (ready / stopped /
# unknown / transient), then cross-checks docker for actual container
# health. This way "stopped" apps display as intentionally off (not as
# crashes), and "ready" apps that have crashed containers are flagged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ ! -r "$SCRIPT_DIR/lib-umbreld.sh" ]; then
    echo "⚠️ scripts/lib-umbreld.sh is missing — this is a partial install." >&2
    echo "   Re-run: sudo bash $(dirname "$SCRIPT_DIR")/reinstall-services.sh" >&2
    exit 1
fi
source "$SCRIPT_DIR/lib-umbreld.sh"
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
APP_QUERY_OK=0
APP_QUERY_ERR=""
if command -v umbreld &>/dev/null; then
    # Capture the exit status before the pipe swallows it. Piping straight into
    # python discarded it, so a timed-out query was indistinguishable from an
    # empty one — which is how a node with apps on it was told "No apps
    # installed." while umbreld was simply taking too long to answer.
    APP_RAW=$(guardian_umbreld "$GUARDIAN_UMBRELD_TIMEOUT" apps.list.query 2>&1)
    APP_QUERY_RC=$?
    if [ "$APP_QUERY_RC" -eq 0 ]; then
        APP_QUERY_OK=1
    elif [ "$APP_QUERY_RC" -eq 124 ]; then
        APP_QUERY_ERR="umbreld did not answer within ${GUARDIAN_UMBRELD_TIMEOUT}s"
    else
        APP_QUERY_ERR="umbreld returned an error (exit $APP_QUERY_RC)"
    fi
    APP_STATES=$(printf '%s' "${APP_RAW:-}" | python3 -c "
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
if [ "$APP_QUERY_OK" -eq 0 ]; then
    echo "⚠️ Could not read the app list from umbreld — $APP_QUERY_ERR."
    echo "   Listing what is on disk instead; states below are from Docker only."
    echo ""
fi

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

    # Telegram bot commands only accept [a-zA-Z0-9_]: dashes break the auto-link.
    # Convert dashes to underscores for the tappable shortcut; restart_app.sh
    # reverses this when looking up the app id.
    shortcut="/restart_${app_id//-/_}"

    # Intentional off (user stopped it) — show but don't flag
    if [ "$state" = "stopped" ]; then
        echo "⏸ $app_id  (stopped) — $shortcut"
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
            echo "❌ $app_id  ($state, no containers) — $shortcut"
        else
            echo "❌ $app_id  (no containers) — $shortcut"
        fi
        continue
    fi

    total=$(echo "$app_lines" | wc -l)
    running=$(echo "$app_lines" | grep -c " running$" || true)

    if [ "$running" -eq "$total" ]; then
        echo "✅ $app_id  (running) — $shortcut"
    elif [ "$running" -gt 0 ]; then
        echo "⚠️ $app_id  (partial: $running/$total) — $shortcut"
    else
        container_state=$(echo "$app_lines" | head -1 | awk '{print $NF}')
        echo "❌ $app_id  ($container_state) — $shortcut"
    fi
done

if [ "$FOUND" -eq 0 ]; then
    # Only a successful query can justify this sentence. Saying it after a
    # failure states as fact the one thing that was never established.
    if [ "$APP_QUERY_OK" -eq 1 ]; then
        echo "No apps installed."
    else
        echo "❌ No app list available: umbreld could not be reached and $APP_DATA is empty."
        echo "   This is not the same as having no apps — nothing here could confirm either way."
    fi
fi
