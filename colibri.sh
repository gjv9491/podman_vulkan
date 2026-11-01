#!/usr/bin/env bash
# Convenience wrapper: runs colibri commands inside the ollama-sandbox container.
# Usage:
#   ./colibri.sh setup                  # download a model interactively
#   ./colibri.sh chat --model <dir>     # interactive chat
#   ./colibri.sh serve --model <dir>    # OpenAI-compatible API on port 8080
#   ./colibri.sh run "prompt" --model <dir>
#
# Models are stored in ~/.colibri (mounted at /root/.colibri in the container).
set -euo pipefail

CONTAINER_NAME="ollama-sandbox"

if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
  echo "Container '$CONTAINER_NAME' is not running. Run ./setup.sh first." >&2
  exit 1
fi

exec podman exec -it "$CONTAINER_NAME" coli "$@"
