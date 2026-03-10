#!/usr/bin/env bash
# Fetch recent logs for an Umbrel app container.
# Usage: app_logs.sh <app_id> [lines]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
source "$CONFIG"

APP="${1:-}"
LINES="${2:-50}"

if [ -z "$APP" ]; then
    echo "⚠️ Usage: app_logs.sh <app_id> [lines]"
    exit 1
fi

# Security: prevent directory traversal — only allow safe app-id characters
if [[ ! "$APP" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
    echo "⚠️ Invalid app ID: only letters, numbers, hyphens, underscores allowed."
    exit 1
fi

if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then
    echo "⚠️ Line count must be a positive integer."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "⚠️ docker not found — cannot retrieve logs for $APP"
    exit 1
fi

# Truncate individual log lines to prevent extremely long stack traces
# or binary data from flooding Telegram messages (4096 char limit per message).
truncate_lines() { cut -c1-500; }

UMBREL_DATA="${UMBREL_DIR:-/home/umbrel/umbrel}"

# Method 1: docker compose logs — preferred, shows all services for the app.
# Umbrel stores compose files at app-data/<app_id>/docker-compose.yml
COMPOSE_FILE="${UMBREL_DATA}/app-data/${APP}/docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" logs --tail "$LINES" 2>&1 | truncate_lines
    exit ${PIPESTATUS[0]}
fi

# Method 2: find container by app-id prefix.
# Umbrel container names follow: <app_id>_<service>_<num> or <app_id>-<service>-<num>
CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E "^${APP}[_-]" | head -1)

# Method 3: exact name match (in case container IS just the app ID)
if [ -z "$CONTAINER" ]; then
    if docker inspect "$APP" &>/dev/null; then
        CONTAINER="$APP"
    fi
fi

if [ -z "$CONTAINER" ]; then
    echo "⚠️ No containers found for '$APP'"
    echo "Use /apps to see valid app IDs."
    exit 1
fi

docker logs --tail "$LINES" "$CONTAINER" 2>&1 | truncate_lines
