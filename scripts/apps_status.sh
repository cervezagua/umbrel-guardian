#!/usr/bin/env bash
# List all installed Umbrel apps with their current state.
# Uses docker ps (the proven UmbrelGuard approach) instead of umbreld client.

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

if [ -z "$ALL" ]; then
    echo "No containers found."
    exit 0
fi

echo "📦 Installed Apps"
echo "━━━━━━━━━━━━━━━━━━"

FOUND=0
for app_dir in "$APP_DATA"/*/; do
    [ -d "$app_dir" ] || continue
    app_id=$(basename "$app_dir")

    # Umbrel containers: <app_id>_<service>_<num>  (Docker Compose v1 naming)
    app_lines=$(echo "$ALL" | grep -E "^${app_id}_" 2>/dev/null || true)
    [ -z "$app_lines" ] && continue

    FOUND=$((FOUND + 1))
    total=$(echo "$app_lines" | wc -l)
    running=$(echo "$app_lines" | grep -c " running$" || true)

    if [ "$running" -eq "$total" ]; then
        echo "✅ $app_id  (running)"
    elif [ "$running" -gt 0 ]; then
        echo "⚠️ $app_id  (partial: $running/$total)"
    else
        state=$(echo "$app_lines" | head -1 | awk '{print $NF}')
        echo "❌ $app_id  ($state)"
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "No apps installed."
fi
