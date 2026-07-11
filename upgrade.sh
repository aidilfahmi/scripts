#!/usr/bin/env bash

set -euo pipefail

#############################################
# Cosmos Simple Auto Upgrade
#############################################

UPGRADE_HEIGHT="$1"
SERVICE="$2"
NEW_BINARY="$3"
CHAIN_HOME="$4"

CURRENT_BINARY="$(command -v "$SERVICE")"
CONFIG_FILE="$CHAIN_HOME/config/config.toml"

#############################################

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.toml not found"
    exit 1
fi

if [ ! -f "$NEW_BINARY" ]; then
    echo "ERROR: New binary not found"
    exit 1
fi

if [ -z "$CURRENT_BINARY" ]; then
    echo "ERROR: Installed binary not found"
    exit 1
fi

RPC_PORT=$(grep -m1 '^laddr = ' "$CONFIG_FILE" \
    | sed -E 's/.*:([0-9]+)".*/\1/')

TARGET_HEIGHT=$((UPGRADE_HEIGHT-1))

chmod +x "$NEW_BINARY"

echo "======================================"
echo " Cosmos Simple Auto Upgrade"
echo "======================================"
echo "Service        : $SERVICE"
echo "Current Binary : $CURRENT_BINARY"
echo "New Binary     : $NEW_BINARY"
echo "Chain Home     : $CHAIN_HOME"
echo "RPC Port       : $RPC_PORT"
echo "Upgrade Height : $UPGRADE_HEIGHT"
echo "Upgrade At     : $TARGET_HEIGHT"
echo

while true
do

    HEIGHT=$(curl -sf "http://127.0.0.1:${RPC_PORT}/status" \
        | jq -r '.result.sync_info.latest_block_height')

    if ! [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
        printf "\rWaiting for RPC..."
        sleep 2
        continue
    fi

    REMAINING=$((TARGET_HEIGHT-HEIGHT))

    printf "\rHeight: %-12s Remaining: %-10s" \
        "$HEIGHT" \
        "$REMAINING"

    if [ "$HEIGHT" -ge "$TARGET_HEIGHT" ]; then

        echo
        echo
        echo "Upgrade height reached."
        echo "Stopping ${SERVICE}..."

        sudo systemctl stop "$SERVICE"

        sleep 2

        echo "Backing up current binary..."

        cp "$CURRENT_BINARY" "${CURRENT_BINARY}.bak"

        echo "Installing new binary..."

        mv "$NEW_BINARY" "$CURRENT_BINARY"

        chmod +x "$CURRENT_BINARY"

        echo "Starting ${SERVICE}..."

        sudo systemctl start "$SERVICE"

        echo
        echo "======================================"
        echo " Upgrade Completed Successfully"
        echo "======================================"

        "$CURRENT_BINARY" version || true

        exit 0

    fi

    sleep 2

done
