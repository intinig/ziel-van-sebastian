#!/bin/bash
# One-command gateway probe: ensures the SSH tunnel is up, finds the token,
# and runs the Swift connect probe.
#
#   ./scripts/probe-gateway.sh          # probe with mode "ui" (default)
#   ./scripts/probe-gateway.sh backend  # probe another mode (not recommended)
#
# Token lookup order: $GATEWAY_TOKEN env → ./config.json → interactive prompt.
# Tunnel host override: GATEWAY_SSH_HOST=somehost ./scripts/probe-gateway.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18789
HOST="${GATEWAY_SSH_HOST:-admin@vm-claw}"
MODE="${1:-ui}"
LISTEN="${2:-0}"   # seconds to stay connected and dump broadcast frames
SUB="${3:-all}"    # sessions.subscribe shape: both | all (empty params) | keys

# --- 1. tunnel -------------------------------------------------------------
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "tunnel down — opening: ssh -f -N -L $PORT:127.0.0.1:$PORT $HOST"
    echo "(IdentitiesOnly=yes avoids the 'too many authentication failures' agent spam;"
    echo " it will prompt for a password if no key is configured for $HOST)"
    ssh -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -f -N \
        -L "$PORT:127.0.0.1:$PORT" "$HOST"
    for _ in $(seq 1 20); do
        nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
        sleep 0.5
    done
fi
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "ERROR: gateway port $PORT still unreachable after opening tunnel." >&2
    exit 1
fi
echo "tunnel up (127.0.0.1:$PORT)"

# --- 2. token ---------------------------------------------------------------
if [[ -n "${GATEWAY_TOKEN:-}" ]]; then
    echo "token: from \$GATEWAY_TOKEN"
elif [[ -f config.json ]]; then
    GATEWAY_TOKEN="$(/usr/bin/python3 -c 'import json; print(json.load(open("config.json"))["gateway"]["token"])')"
    echo "token: from ./config.json"
else
    read -rsp "gateway token (input hidden): " GATEWAY_TOKEN; echo
fi
export GATEWAY_TOKEN

# --- 3. probe ---------------------------------------------------------------
exec swift scripts/probe-gateway.swift "ws://127.0.0.1:$PORT" "$MODE" "$LISTEN" "$SUB"
