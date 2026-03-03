#!/bin/bash
# DevBox OpenSandbox Server — start script
# Runs inside the Debian VM (via devbox-shell).
# install.sh must be run first.

SANDBOX_DIR="$HOME/opensandbox"
LOG="$SANDBOX_DIR/server.log"
VENV="$SANDBOX_DIR/.venv"
CONFIG="$HOME/.sandbox.toml"

if [[ ! -d "$VENV" ]]; then
  echo "ERROR: OpenSandbox not installed. Run: bash /usr/share/devbox/opensandbox/install.sh"
  exit 1
fi

source "$VENV/bin/activate"

export SANDBOX_CONFIG_PATH="$CONFIG"
export PYTHONPATH="$SANDBOX_DIR/server"

echo "[DevBox] Starting OpenSandbox server on 127.0.0.1:8080" >> "$LOG"
echo "[DevBox] Config: $CONFIG" >> "$LOG"
echo "[DevBox] $(date)" >> "$LOG"

cd "$SANDBOX_DIR/server"

uvicorn src.main:app \
  --host 127.0.0.1 \
  --port 8080 \
  --workers 1 \
  --no-access-log \
  >> "$LOG" 2>&1 &

SERVER_PID=$!
echo $SERVER_PID > /tmp/devbox_opensandbox.pid
echo "[DevBox] Server PID: $SERVER_PID" >> "$LOG"

# Wait for server ready (up to 30s)
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1; then
    echo "[DevBox] Server ready after ${i}s" >> "$LOG"
    echo "READY:http://127.0.0.1:8080"
    exit 0
  fi
  sleep 1
done

echo "[DevBox] Server failed to start — check $LOG"
echo "ERROR:timeout"
exit 1
