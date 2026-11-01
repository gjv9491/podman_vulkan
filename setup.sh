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
NETWORK_NAME="ollama-net"

QDRANT_CONTAINER_NAME="qdrant"
QDRANT_IMAGE="docker.io/qdrant/qdrant:latest"
QDRANT_HOST_PORT="6333"
QDRANT_GRPC_PORT="6334"
QDRANT_DATA_DIR="$HOME/.qdrant"

OLLAMA_CONTEXT_LENGTH=8192
OLLAMA_VERSION="v0.40.3"
GO_VERSION="1.23.4"
CMAKE_VERSION="3.31.2"
CUSTOM_IMAGE_NAME="ollama-vulkan-krunkit"
CUSTOM_IMAGE="${CUSTOM_IMAGE_NAME}:${OLLAMA_VERSION}"

HERMES_AGENT_VERSION="0.19.0"
HERMES_IMAGE_NAME="hermes-agent"
HERMES_IMAGE="${HERMES_IMAGE_NAME}:latest"

COLIBRI_MODEL_DIR="$HOME/.colibri"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE_PATH="${SCRIPT_DIR}/Dockerfile"
HERMES_DOCKERFILE_PATH="${SCRIPT_DIR}/Dockerfile.hermes"

OLLAMA_DIR="$HOME/.ollama"
SSH_DIR="$HOME/.ssh"
GIT_DIR="$HOME/Documents/git_code"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── Parse flags ──────────────────────────────────────────────────────────────
ENABLE_WEBUI=false
ENABLE_HERMES=false
ENABLE_HERMES_AGENT=false
ENABLE_COLIBRI=false
ENABLE_QDRANT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --webui)        ENABLE_WEBUI=true; shift ;;
    --hermes)       ENABLE_HERMES=true; shift ;;
    --hermes-agent) ENABLE_HERMES_AGENT=true; ENABLE_HERMES=true; ENABLE_QDRANT=true; shift ;;
    --colibri)      ENABLE_COLIBRI=true; shift ;;
    --qdrant)       ENABLE_QDRANT=true; shift ;;
    --all)          ENABLE_WEBUI=true; ENABLE_HERMES=true; ENABLE_HERMES_AGENT=true; ENABLE_COLIBRI=true; ENABLE_QDRANT=true; shift ;;
    -h|--help)
      echo "Usage: ./setup.sh [--webui] [--hermes] [--hermes-agent] [--colibri] [--qdrant] [--all]"
      echo "Builds and starts GPU-accelerated Ollama in a podman container."
      echo ""
      echo "Options:"
      echo "  --webui        Also start Open WebUI"
      echo "  --hermes       Pull Hermes 3 model into Ollama"
      echo "  --hermes-agent Build hermes-agent container image (implies --hermes, --qdrant)"
      echo "  --colibri      Also start colibri (large MoE models via expert offloading)"
      echo "  --qdrant       Also start Qdrant vector database"
      echo "  --all          Enable all optional services"
      exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# Hermes Agent needs ≥64K context
if $ENABLE_HERMES_AGENT && (( OLLAMA_CONTEXT_LENGTH < 65536 )); then
  OLLAMA_CONTEXT_LENGTH=65536
  log "Bumped OLLAMA_CONTEXT_LENGTH to $OLLAMA_CONTEXT_LENGTH for Hermes Agent."
fi

machine_exists()   { podman machine inspect "$MACHINE_NAME" &>/dev/null; }
machine_running()  { podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null | grep -qi "running"; }
container_exists() { podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
container_running(){ podman ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
image_exists()     { podman image inspect "$CUSTOM_IMAGE" &>/dev/null; }
hermes_image_exists() { podman image inspect "$HERMES_IMAGE" &>/dev/null; }

webui_exists()     { podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_CONTAINER_NAME"; }
webui_running()    { podman ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$WEBUI_CONTAINER_NAME"; }

qdrant_exists()    { podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$QDRANT_CONTAINER_NAME"; }
qdrant_running()   { podman ps    --format '{{.Names}}' 2>/dev/null | grep -qx "$QDRANT_CONTAINER_NAME"; }

image_matches_version() {
  local label colibri_label
  label=$(podman image inspect "$CUSTOM_IMAGE" --format '{{index .Labels "ollama.version"}}' 2>/dev/null)
  colibri_label=$(podman image inspect "$CUSTOM_IMAGE" --format '{{index .Labels "colibri.included"}}' 2>/dev/null)
  [[ "$label" == "$OLLAMA_VERSION" && "$colibri_label" == "true" ]]
}

hermes_image_matches_version() {
  local label
  label=$(podman image inspect "$HERMES_IMAGE" --format '{{index .Labels "hermes.agent.version"}}' 2>/dev/null)
  [[ "$label" == "$HERMES_AGENT_VERSION" ]]
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

build_hermes_image() {
  log "Building '$HERMES_IMAGE'..."
  podman build \
    --build-arg HERMES_AGENT_VERSION="$HERMES_AGENT_VERSION" \
    -t "$HERMES_IMAGE" \
    -f "$HERMES_DOCKERFILE_PATH" \
    "$SCRIPT_DIR"
  log "Image '$HERMES_IMAGE' built successfully."
}

machine_matches_config() {
  python3 - <<EOF 2>/dev/null
import subprocess, json, sys
r = subprocess.run(['podman','machine','inspect','$MACHINE_NAME'], capture_output=True, text=True)
if r.returncode != 0: sys.exit(1)
info = json.loads(r.stdout)[0]
d = info.get('Resources', {})
res_ok = (d.get('CPUs') == $MACHINE_CPUS and
          d.get('Memory') == $MACHINE_MEMORY and
          d.get('DiskSize') == $MACHINE_DISK)
r2 = subprocess.run(['podman','machine','info','--format','json'], capture_output=True, text=True)
provider = json.loads(r2.stdout).get('Host',{}).get('VMType','').lower() if r2.returncode == 0 else ''
sys.exit(0 if (res_ok and provider == 'libkrun') else 1)
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
coli_bindings = d.get('HostConfig',{}).get('PortBindings',{}).get('8080/tcp',[])
coli_port_ok = any(b.get('HostPort') == '8080' for b in coli_bindings)
img_ok  = d.get('Config',{}).get('Image','') == '$CUSTOM_IMAGE'
env     = d.get('Config',{}).get('Env',[])
env_ok  = any('OLLAMA_MAX_LOADED_MODELS=1' in e for e in env)
ctx_ok  = any('OLLAMA_CONTEXT_LENGTH=$OLLAMA_CONTEXT_LENGTH' == e for e in env)
devs    = d.get('HostConfig',{}).get('Devices') or []
gpu_ok  = any('/dev/dri' in str(dev) for dev in devs)
mounts  = d.get('Mounts') or []
srcs    = {m.get('Source','') for m in mounts}
coli_ok = '$COLIBRI_MODEL_DIR' in srcs
sys.exit(0 if (port_ok and coli_port_ok and img_ok and env_ok and ctx_ok and gpu_ok and coli_ok) else 1)
EOF
}

run_container() {
  podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
  log "Creating container '$CONTAINER_NAME'..."
  mkdir -p "$COLIBRI_MODEL_DIR"
  podman run -d \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --restart unless-stopped \
    --device /dev/dri \
    --mount type=bind,src="$OLLAMA_DIR",target=/root/.ollama,rw=true \
    --mount type=bind,src="$COLIBRI_MODEL_DIR",target=/root/.colibri,rw=true \
    --mount type=bind,src="$SSH_DIR",target=/root/.ssh,ro=true \
    -e OLLAMA_HOST=0.0.0.0:${CONTAINER_PORT} \
    -e OLLAMA_VULKAN=1 \
    -e OLLAMA_MAX_LOADED_MODELS=1 \
    -e OLLAMA_KEEP_ALIVE=5m \
    -e OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH} \
    -e OLLAMA_FLASH_ATTENTION=1 \
    -e OLLAMA_KV_CACHE_TYPE=q8_0 \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    -p "8080:8080" \
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
env_ok  = any(e == 'OLLAMA_BASE_URL=http://${CONTAINER_NAME}:${CONTAINER_PORT}' for e in env)
mounts  = d.get('Mounts') or []
srcs    = {m.get('Source','') for m in mounts}
mnt_ok  = '$GIT_DIR' in srcs
sys.exit(0 if (port_ok and img_ok and env_ok and mnt_ok) else 1)
EOF
}

run_webui() {
  mkdir -p "$WEBUI_DATA_DIR"
  podman rm -f "$WEBUI_CONTAINER_NAME" 2>/dev/null || true
  log "Creating container '$WEBUI_CONTAINER_NAME'..."
  podman run -d \
    --name "$WEBUI_CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --restart unless-stopped \
    -p "${WEBUI_HOST_PORT}:${WEBUI_CONTAINER_PORT}" \
    -v "${WEBUI_DATA_DIR}:/app/backend/data" \
    --mount type=bind,src="$GIT_DIR",target=/root/git_code,rw=true \
    -e OLLAMA_BASE_URL="http://${CONTAINER_NAME}:${CONTAINER_PORT}" \
    "$WEBUI_IMAGE"
}

run_qdrant() {
  mkdir -p "$QDRANT_DATA_DIR/storage" "$QDRANT_DATA_DIR/snapshots"
  podman rm -f "$QDRANT_CONTAINER_NAME" 2>/dev/null || true
  log "Creating container '$QDRANT_CONTAINER_NAME'..."
  podman run -d \
    --name "$QDRANT_CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --restart unless-stopped \
    -p "${QDRANT_HOST_PORT}:6333" \
    -p "${QDRANT_GRPC_PORT}:6334" \
    -v "${QDRANT_DATA_DIR}/storage:/qdrant/storage" \
    -v "${QDRANT_DATA_DIR}/snapshots:/qdrant/snapshots" \
    "$QDRANT_IMAGE"
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

# libkrun's DNS proxy can't resolve some Docker CDN domains — use a public
# resolver but pin the podman-internal gateway hostname in /etc/hosts.
podman machine ssh "$MACHINE_NAME" "
  grep -q gateway.containers.internal /etc/hosts 2>/dev/null \
    || echo '192.168.127.1 gateway.containers.internal host.containers.internal' | sudo tee -a /etc/hosts
  echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf
" &>/dev/null
log "Waiting for VM network..."
for i in $(seq 1 15); do
  podman machine ssh "$MACHINE_NAME" "nslookup docker.io" &>/dev/null && break
  sleep 1
done
podman machine ssh "$MACHINE_NAME" "nslookup docker.io" &>/dev/null \
  || warn "VM DNS may be slow — image pulls might retry."

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

# ── 3. Shared network (container-name DNS) ───────────────────────────────────
podman network exists "$NETWORK_NAME" 2>/dev/null \
  || podman network create "$NETWORK_NAME" >/dev/null
log "Network '$NETWORK_NAME' ready."

# ── 4. Container lifecycle ────────────────────────────────────────────────────

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

# ── 5. Open WebUI lifecycle (optional: --webui) ──────────────────────────────
if $ENABLE_WEBUI; then
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
else
  log "Open WebUI skipped (pass --webui to enable)."
fi

# ── 6. Pull Hermes 3 model (optional: --hermes) ─────────────────────────────
if $ENABLE_HERMES; then
  log "Pulling Hermes 3 model (this may take a while on first run)..."
  podman exec "$CONTAINER_NAME" ollama pull hermes3
  log "Hermes 3 model ready."
else
  log "Hermes 3 pull skipped (pass --hermes to enable)."
fi

# ── 7. Hermes Agent image (optional: --hermes-agent) ────────────────────────
if $ENABLE_HERMES_AGENT; then
  if hermes_image_exists; then
    if hermes_image_matches_version; then
      log "Image '$HERMES_IMAGE' is up to date (v${HERMES_AGENT_VERSION}) — skipping build."
    else
      warn "Image '$HERMES_IMAGE' version differs from v${HERMES_AGENT_VERSION} — rebuilding..."
      podman image rm -f "$HERMES_IMAGE"
      build_hermes_image
    fi
  else
    log "Image '$HERMES_IMAGE' not found — building..."
    build_hermes_image
  fi
  log "Hermes Agent ready. Run: ./hermes.sh"
else
  log "Hermes Agent skipped (pass --hermes-agent to enable)."
fi

# ── 8. Qdrant vector database (optional: --qdrant, implied by --hermes-agent)
if $ENABLE_QDRANT; then
  if qdrant_exists; then
    if qdrant_running; then
      log "Container '$QDRANT_CONTAINER_NAME' is already running."
    else
      log "Container '$QDRANT_CONTAINER_NAME' is stopped — starting it..."
      podman start "$QDRANT_CONTAINER_NAME"
    fi
  else
    run_qdrant
  fi
else
  log "Qdrant skipped (pass --qdrant to enable)."
fi

# ── 9. colibri setup (optional: --colibri) ──────────────────────────────────
if $ENABLE_COLIBRI; then
  log "colibri is available inside the container."
  log "Verifying colibri Vulkan GPU detection..."
  podman exec "$CONTAINER_NAME" coli plan --model /root/.colibri 2>&1 | head -5 || true
  log "colibri ready."
  log ""
  log "  Download a model:  podman exec -it $CONTAINER_NAME coli setup --model /root/.colibri"
  log "  Chat:              podman exec -it $CONTAINER_NAME coli chat --model /root/.colibri/<model>"
  log "  Serve (API):       podman exec -it $CONTAINER_NAME coli serve --model /root/.colibri/<model> --host 0.0.0.0 --port 8080"
  log "  Import GGUF:       podman exec -it $CONTAINER_NAME coli import /root/.ollama/models/blobs/<blob>"
else
  log "colibri skipped (pass --colibri to enable setup; binaries are always in the container)."
fi


log "────────────────────────────────────────────"
log "Done."
log "  Ollama API  : http://localhost:${HOST_PORT}"
$ENABLE_WEBUI      && log "  Open WebUI  : http://localhost:${WEBUI_HOST_PORT}"
$ENABLE_HERMES     && log "  Hermes 3    : ollama run hermes3 (via localhost:${HOST_PORT})"
$ENABLE_HERMES_AGENT && log "  Hermes TUI  : ./hermes.sh"
$ENABLE_COLIBRI    && log "  colibri     : podman exec -it $CONTAINER_NAME coli chat --model /root/.colibri/<model>"
$ENABLE_QDRANT     && log "  Qdrant API  : http://localhost:${QDRANT_HOST_PORT} (gRPC :${QDRANT_GRPC_PORT})"
$ENABLE_QDRANT     && log "  Qdrant (net): http://${QDRANT_CONTAINER_NAME}:6333 (from containers)"
log "  GPU         : Venus/Vulkan → Metal (--device /dev/dri)"
log "  Attach      : podman exec -it $CONTAINER_NAME sh"
log "  Verify GPU  : podman logs $CONTAINER_NAME 2>&1 | grep 'inference compute'"
log "────────────────────────────────────────────"
