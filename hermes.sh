#!/usr/bin/env bash
# Convenience wrapper: runs hermes-agent inside a container on the ollama-net network.
# Usage:
#   ./hermes.sh            # interactive TUI
#   ./hermes.sh --help     # hermes help
#
# Config is generated on first run and persisted in ~/.hermes/.
set -euo pipefail

OLLAMA_CONTAINER="ollama-sandbox"
HERMES_IMAGE="hermes-agent:latest"
NETWORK_NAME="ollama-net"
OLLAMA_PORT="11434"
GIT_DIR="$HOME/Documents/git_code"
HERMES_DATA_DIR="$HOME/.hermes"

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OLLAMA_CONTAINER"; then
  echo "Container '$OLLAMA_CONTAINER' is not running. Run ./setup.sh first." >&2
  exit 1
fi

mkdir -p "$HERMES_DATA_DIR"

CONTAINER_URL="http://${OLLAMA_CONTAINER}:${OLLAMA_PORT}/v1"

if [[ ! -f "$HERMES_DATA_DIR/config.yaml" ]]; then
  echo "[INFO]  Writing Hermes config → $HERMES_DATA_DIR/config.yaml"
  cat > "$HERMES_DATA_DIR/config.yaml" <<YAML
provider: custom
base_url: "${CONTAINER_URL}"
model: hermes3
api_key: "ollama"
YAML
elif ! grep -q "$CONTAINER_URL" "$HERMES_DATA_DIR/config.yaml"; then
  echo "[INFO]  Patching config URLs for container network..."
  sed -i.bak \
    -e "s|http://127\.0\.0\.1:[0-9]*/v1|${CONTAINER_URL}|g" \
    -e "s|http://localhost:[0-9]*/v1|${CONTAINER_URL}|g" \
    "$HERMES_DATA_DIR/config.yaml"
  rm -f "$HERMES_DATA_DIR/config.yaml.bak"
fi

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "qdrant"; then
  echo "[WARN]  Qdrant container is not running. Vector memory unavailable. Run ./setup.sh --qdrant" >&2
fi

podman rm -f hermes-agent 2>/dev/null || true

exec podman run --rm -it \
  --name hermes-agent \
  --network "$NETWORK_NAME" \
  --mount type=bind,src="$GIT_DIR",target=/root/git_code,rw=true \
  --mount type=bind,src="$HERMES_DATA_DIR",target=/root/.hermes,rw=true \
  -e QDRANT_URL="http://qdrant:6333" \
  "$HERMES_IMAGE" "$@"
