#!/bin/bash
# eRemote Server Entrypoint
# Starts both hbbr (relay) and hbbs (rendezvous) services
#
# SECURITY: Identity keys are generated at runtime, not baked into image.
# Keys persist in /root which should be a host-mounted volume.

set -e

# Configuration via environment variables
RELAY_HOST="${RELAY_HOST:-}"
RELAY_PORT="${RELAY_PORT:-21117}"

echo "=== eRemote Server Starting ==="
echo "Working directory: $(pwd)"
echo "Data files will be stored in: /root"

# Check for existing identity keys
if [ -f "/root/id_ed25519" ]; then
    echo "Found existing identity key"
else
    echo "No identity key found - will be generated on first hbbs start"
fi

# Start hbbr (relay server) in background
echo "Starting hbbr (relay server) on ports 21117, 21119..."
hbbr &
HBBR_PID=$!
echo "hbbr started with PID: $HBBR_PID"

# Wait for hbbr to initialize
sleep 2

# Build hbbs command with relay option if specified
HBBS_CMD="hbbs"
if [ -n "$RELAY_HOST" ]; then
    HBBS_CMD="hbbs -r ${RELAY_HOST}:${RELAY_PORT}"
    echo "Configuring relay: ${RELAY_HOST}:${RELAY_PORT}"
fi

# Start hbbs (rendezvous server) in foreground
echo "Starting hbbs (rendezvous server) on ports 21115, 21116, 21118..."
echo "Executing: $HBBS_CMD"

# Trap signals to clean up hbbr when container stops
cleanup() {
    echo "Shutting down..."
    kill $HBBR_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Run hbbs in foreground
exec $HBBS_CMD
