#!/usr/bin/env bash

set -euo pipefail

#############################################
# Cosmos Simple Auto Upgrade
#############################################

if [ "$#" -ne 4 ]; then
    echo "Usage:"
    echo "  $0 <upgrade_height> <service> <new_binary> <chain_home>"
    exit 1
fi

UPGRADE_HEIGHT="$1"
SERVICE="$2"
NEW_BINARY="$3"
CHAIN_HOME="$4"

CURRENT_BINARY="$(command -v "$SERVICE")"
CONFIG_FILE="$CHAIN_HOME/config/config.toml"

#############################################
# Validation
#############################################

[ -f "$CONFIG_FILE" ] || {
    echo "ERROR: $CONFIG_FILE not found."
    exit 1
}

[ -f "$NEW_BINARY" ] || {
    echo "ERROR: New binary not found: $NEW_BINARY"
    exit 1
}

[ -n "$CURRENT_BINARY" ] || {
    echo "ERROR: Installed binary '$SERVICE' not found in PATH."
    exit 1
}

#############################################
# Get sudo permission once
#############################################

echo "Checking sudo permission..."
sudo -v || {
    echo "Unable to obtain sudo permission."
    exit 1
}

# Keep sudo alive while the script is running
(
while true; do
    sudo -n true
    sleep 60
done
) &
SUDO_PID=$!

cleanup() {
    kill "$SUDO_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

#############################################
# Detect RPC Port
#############################################

RPC_PORT=$(grep -m1 '^laddr = ' "$CONFIG_FILE" \
    | sed -E 's/.*:([0-9]+)".*/\1/')

TARGET_HEIGHT=$((UPGRADE_HEIGHT - 1))

chmod +x "$NEW_BINARY"

#############################################
# Information
#############################################

echo
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
echo "======================================"
echo

#############################################
# Monitor
#############################################

while true
do
    HEIGHT=$(curl -sf "http://127.0.0.1:${RPC_PORT}/status" \
        | jq -r '.result.sync_info.latest_block_height')

    if ! [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
        printf "\rWaiting for RPC..."
        sleep 2
        continue
    fi

    REMAINING=$((TARGET_HEIGHT - HEIGHT))

    printf "\rHeight: %-12s Remaining: %-10s" \
        "$HEIGHT" \
        "$REMAINING"

    if [ "$HEIGHT" -ge "$TARGET_HEIGHT" ]; then

        echo
        echo
        echo "Upgrade height reached!"
        echo "Stopping ${SERVICE}..."

        sudo systemctl stop "$SERVICE"

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
