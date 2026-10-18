#!/usr/bin/env bash

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
MACHINE_NAME="podman-machine-default"
MACHINE_CPUS=8
MACHINE_MEMORY=40960
MACHINE_DISK=100

CONTAINER_NAME="ollama-sandbox"
HOST_PORT="11435"
CONTAINER_PORT="11434"

WEBUI_CONTAINER_NAME="open-webui"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
WEBUI_HOST_PORT="3000"
WEBUI_CONTAINER_PORT="8080"
WEBUI_DATA_DIR="$HOME/.open-webui"

OLLAMA_VERSION="v0.40.3"
GO_VERSION="1.23.4"
CMAKE_VERSION="3.31.2"
CUSTOM_IMAGE_NAME="ollama-vulkan-krunkit"
CUSTOM_IMAGE="${CUSTOM_IMAGE_NAME}:${OLLAMA_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE_PATH="${SCRIPT_DIR}/Dockerfile"

OLLAMA_DIR="$HOME/.ollama"
SSH_DIR="$HOME/.ssh"
GIT_DIR="$HOME/Documents/git_code"

# ── Usage ────────────────────────────────────────────────────────────────────
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
  echo "Usage: ./setup.sh"
  echo "Builds and starts GPU-accelerated Ollama + Open WebUI in podman containers."
  exit 0
}

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

machine_exists()   { podman machine inspect "$MACHINE_NAME" &>/dev/null; }
machine_running()  { podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null | grep -qi "running"; }
container_exists() { podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
container_running(){ podman ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
image_exists()     { podman image inspect "$CUSTOM_IMAGE" &>/dev/null; }

webui_exists()     { podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_CONTAINER_NAME"; }
webui_running()    { podman ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_CONTAINER_NAME"; }

image_matches_version() {
  local label
  label=$(podman image inspect "$CUSTOM_IMAGE" --format '{{index .Labels "ollama.version"}}' 2>/dev/null)
  [[ "$label" == "$OLLAMA_VERSION" ]]
}

build_image() {
  log "Building '$CUSTOM_IMAGE' — first build takes ~15-20 min..."
  podman build \
    --build-arg OLLAMA_VERSION="$OLLAMA_VERSION" \
    --build-arg GO_VERSION="$GO_VERSION" \
    --build-arg CMAKE_VERSION="$CMAKE_VERSION" \
    -t "$CUSTOM_IMAGE" \
    -f "$DOCKERFILE_PATH" \
    "$SCRIPT_DIR"
  log "Image '$CUSTOM_IMAGE' built successfully."
}

machine_matches_config() {
  python3 - <<EOF 2>/dev/null
import subprocess, json, sys
r = subprocess.run(['podman','machine','inspect','$MACHINE_NAME'], capture_output=True, text=True)
if r.returncode != 0: sys.exit(1)
info = json.loads(r.stdout)[0]
d = info.get('Resources', {})
provider = info.get('VMType', '').lower()
match = (d.get('CPUs') == $MACHINE_CPUS and
         d.get('Memory') == $MACHINE_MEMORY and
         d.get('DiskSize') == $MACHINE_DISK and
         provider == 'libkrun')
sys.exit(0 if match else 1)
EOF
}

container_matches_config() {
  python3 - <<EOF 2>/dev/null
import subprocess, json, sys
r = subprocess.run(['podman','inspect','$CONTAINER_NAME'], capture_output=True, text=True)
if r.returncode != 0: sys.exit(1)
d = json.loads(r.stdout)[0]
bindings = d.get('HostConfig',{}).get('PortBindings',{}).get('${CONTAINER_PORT}/tcp',[])
port_ok = any(b.get('HostPort') == '$HOST_PORT' for b in bindings)
img_ok  = d.get('Config',{}).get('Image','') == '$CUSTOM_IMAGE'
env     = d.get('Config',{}).get('Env',[])
env_ok  = any('OLLAMA_MAX_LOADED_MODELS=1' in e for e in env)
devs    = d.get('HostConfig',{}).get('Devices') or []
gpu_ok  = any('/dev/dri' in str(dev) for dev in devs)
sys.exit(0 if (port_ok and img_ok and env_ok and gpu_ok) else 1)
EOF
}

run_container() {
  podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
  log "Creating container '$CONTAINER_NAME'..."
  podman run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --device /dev/dri \
    --mount type=bind,src="$OLLAMA_DIR",target=/root/.ollama,rw=true \
    --mount type=bind,src="$SSH_DIR",target=/root/.ssh,ro=true \
    --mount type=bind,src="$GIT_DIR",target=/root/git_code,rw=true \
    -e OLLAMA_HOST=0.0.0.0:${CONTAINER_PORT} \
    -e OLLAMA_VULKAN=1 \
    -e OLLAMA_MAX_LOADED_MODELS=1 \
    -e OLLAMA_CONTEXT_LENGTH=8192 \
    -e OLLAMA_FLASH_ATTENTION=1 \
    -e OLLAMA_KV_CACHE_TYPE=q8_0 \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    "$CUSTOM_IMAGE"
}

webui_matches_config() {
  python3 - <<EOF 2>/dev/null
import subprocess, json, sys
r = subprocess.run(['podman','inspect','$WEBUI_CONTAINER_NAME'], capture_output=True, text=True)
if r.returncode != 0: sys.exit(1)
d = json.loads(r.stdout)[0]
bindings = d.get('HostConfig',{}).get('PortBindings',{}).get('${WEBUI_CONTAINER_PORT}/tcp',[])
port_ok = any(b.get('HostPort') == '$WEBUI_HOST_PORT' for b in bindings)
img_ok  = d.get('Config',{}).get('Image','') == '$WEBUI_IMAGE'
env     = d.get('Config',{}).get('Env',[])
env_ok  = any(e.split('=',1)[-1].endswith(':${HOST_PORT}') for e in env if e.startswith('OLLAMA_BASE_URL='))
sys.exit(0 if (port_ok and img_ok and env_ok) else 1)
EOF
}

run_webui() {
  mkdir -p "$WEBUI_DATA_DIR"
  podman rm -f "$WEBUI_CONTAINER_NAME" 2>/dev/null || true
  log "Creating container '$WEBUI_CONTAINER_NAME'..."
  podman run -d \
    --name "$WEBUI_CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${WEBUI_HOST_PORT}:${WEBUI_CONTAINER_PORT}" \
    -v "${WEBUI_DATA_DIR}:/app/backend/data" \
    -e OLLAMA_BASE_URL="http://host.containers.internal:${HOST_PORT}" \
    "$WEBUI_IMAGE"
}

# ── 0. Host prerequisites (krunkit) ───────────────────────────────────────────
if ! command -v krunkit &>/dev/null; then
  log "krunkit not found — installing via Homebrew..."
  brew tap slp/krunkit 2>/dev/null || true
  brew install krunkit
else
  log "krunkit is installed."
fi

[[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile not found at '$DOCKERFILE_PATH'."

# ── 1. Machine lifecycle (must be running before image build) ─────────────────
if machine_exists; then
  if machine_matches_config; then
    log "Machine '$MACHINE_NAME' matches desired config (cpus=$MACHINE_CPUS, mem=${MACHINE_MEMORY}MB, disk=${MACHINE_DISK}GB) — keeping it."
  else
    warn "Machine '$MACHINE_NAME' config differs — removing and recreating..."
    if machine_running; then
      log "Stopping machine '$MACHINE_NAME'..."
      podman machine stop "$MACHINE_NAME"
    fi
    podman machine rm -f "$MACHINE_NAME"
  fi
else
  log "Machine '$MACHINE_NAME' does not exist — will create."
fi

if ! machine_exists; then
  log "Initialising machine '$MACHINE_NAME'..."
  podman machine init \
    --cpus "$MACHINE_CPUS" \
    --memory "$MACHINE_MEMORY" \
    --disk-size "$MACHINE_DISK" \
    --provider libkrun \
    "$MACHINE_NAME"
fi

if machine_running; then
  log "Machine '$MACHINE_NAME' is already running — skipping start."
else
  log "Starting machine '$MACHINE_NAME'..."
  podman machine start "$MACHINE_NAME"
fi

log "Verifying GPU passthrough (/dev/dri)..."
if ! podman machine ssh "$MACHINE_NAME" ls /dev/dri/renderD128 &>/dev/null; then
  die "GPU device (/dev/dri) not found in VM — machine is likely using applehv instead of krunkit.
   Fix: podman machine stop $MACHINE_NAME && podman machine rm -f $MACHINE_NAME && re-run this script."
fi
log "GPU passthrough verified."

mkdir -p "$OLLAMA_DIR"

# ── 2. Custom image (requires running machine) ───────────────────────────────
if image_exists; then
  if image_matches_version; then
    log "Image '$CUSTOM_IMAGE' is up to date — skipping build."
  else
    warn "Image '$CUSTOM_IMAGE' version differs from '$OLLAMA_VERSION' — rebuilding..."
    if container_exists; then
      log "Removing container '$CONTAINER_NAME' before image rebuild..."
      podman rm -f "$CONTAINER_NAME"
    fi
    podman image rm -f "$CUSTOM_IMAGE"
    build_image
  fi
else
  log "Image '$CUSTOM_IMAGE' not found — building..."
  build_image
fi

# ── 3. Container lifecycle ────────────────────────────────────────────────────

if container_exists; then
  if container_matches_config; then
    log "Container '$CONTAINER_NAME' matches desired config (image=$CUSTOM_IMAGE, port=${HOST_PORT}:${CONTAINER_PORT}) — keeping it."
    if ! container_running; then
      log "Container is stopped — starting it..."
      podman start "$CONTAINER_NAME"
    fi
  else
    warn "Container '$CONTAINER_NAME' config differs — removing and recreating..."
    podman rm -f "$CONTAINER_NAME"
    run_container
  fi
else
  run_container
fi

# ── 4. Open WebUI lifecycle ───────────────────────────────────────────────────
if webui_exists; then
  if webui_matches_config; then
    log "Container '$WEBUI_CONTAINER_NAME' matches desired config (image=$WEBUI_IMAGE, port=${WEBUI_HOST_PORT}:${WEBUI_CONTAINER_PORT}) — keeping it."
    if ! webui_running; then
      log "Container is stopped — starting it..."
      podman start "$WEBUI_CONTAINER_NAME"
    fi
  else
    warn "Container '$WEBUI_CONTAINER_NAME' config differs — removing and recreating..."
    podman rm -f "$WEBUI_CONTAINER_NAME"
    run_webui
  fi
else
  run_webui
fi

log "────────────────────────────────────────────"
log "Done."
log "  Ollama API  : http://localhost:${HOST_PORT}"
log "  Open WebUI  : http://localhost:${WEBUI_HOST_PORT}"
log "  GPU         : Venus/Vulkan → Metal (--device /dev/dri)"
log "  Attach      : podman exec -it $CONTAINER_NAME sh"
log "  Verify GPU  : podman logs $CONTAINER_NAME 2>&1 | grep 'inference compute'"
log "────────────────────────────────────────────"
