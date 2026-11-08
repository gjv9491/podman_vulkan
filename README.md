# podman_vulkan

GPU-accelerated LLM inference + agent tooling in sandboxed Linux containers on Apple Silicon (M1–M5).

## Architecture

```
┌─── macOS Host (Apple Silicon) ──────────────────────────────────────────────┐
│                                                                             │
│  Persistent storage (bind-mounted into containers):                         │
│  ~/.ollama/    ~/.colibri/    ~/.hermes/    ~/.qdrant/    ~/git_code/       │
│      │              │             │             │              │             │
│  ┌───┼──────────────┼─────────────┼─────────────┼──────────────┼────────┐   │
│  │   │    podman machine (libkrun VM, /dev/dri GPU passthrough)│        │   │
│  │   │              │             │             │              │        │   │
│  │   ▼              ▼             ▼             ▼              ▼        │   │
│  │  ┌─── ollama-net (container DNS resolution) ────────────────────┐   │   │
│  │  │                                                               │   │   │
│  │  │  ┌──────────────────────┐    ┌─────────────────────────────┐ │   │   │
│  │  │  │  ollama-sandbox      │    │  qdrant                     │ │   │   │
│  │  │  │  (always-on)         │    │  (always-on)                │ │   │   │
│  │  │  │                      │    │                             │ │   │   │
│  │  │  │  Ollama    :11434  ◄─┼────┼── hermes-agent ──────────►  │ │   │   │
│  │  │  │  colibri   :8080     │    │   (ephemeral TUI)           │ │   │   │
│  │  │  │  Vulkan GPU ✓        │    │                             │ │   │   │
│  │  │  │  --device /dev/dri   │    │  REST  :6333                │ │   │   │
│  │  │  └──────────────────────┘    │  gRPC  :6334                │ │   │   │
│  │  │                              │  storage persisted to disk  │ │   │   │
│  │  │  ┌──────────────────────┐    └─────────────────────────────┘ │   │   │
│  │  │  │  open-webui          │                                    │   │   │
│  │  │  │  (optional)  :3000   │                                    │   │   │
│  │  │  └──────────────────────┘                                    │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  GPU path: Vulkan → Mesa Venus → virtio-gpu → MoltenVK → Apple Metal       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### How the GPU path works

The official `ollama/ollama` arm64 image ships CPU-only — its Vulkan backend is compiled for amd64 only. On Apple Silicon, podman uses `krunkit` (libkrun) to virtualise Linux. The VM gets a virtual GPU device (`/dev/dri/renderD128`) that forwards Vulkan calls to the host's Metal GPU through the Venus protocol. This requires patched `slp/mesa-krunkit` mesa drivers, which are only available for EPEL 9 (AlmaLinux 9 / Rocky 9), so we build from AlmaLinux 9 instead of Fedora.

```
Container process → Vulkan API → Mesa Venus driver → virtio-gpu → MoltenVK → Apple Metal → GPU
```

### Containers

| Container | Image | Role | Lifecycle | Host ports |
|-----------|-------|------|-----------|------------|
| `ollama-sandbox` | `ollama-vulkan-krunkit:v0.40.3` | LLM inference (Ollama + colibri) with Vulkan GPU | Always-on, `--restart unless-stopped` | 11435→11434, 8080→8080 |
| `qdrant` | `qdrant/qdrant:latest` | Vector similarity search database for agent memory | Always-on, `--restart unless-stopped` | 6333→6333, 6334→6334 |
| `hermes-agent` | `hermes-agent:latest` | Hermes 3 agent TUI (connects to ollama + qdrant) | Ephemeral, `--rm` per session | none |
| `open-webui` | `ghcr.io/open-webui/open-webui:main` | Browser-based chat UI for Ollama | Optional, always-on | 3000→8080 |

### Persistent storage

All data lives on the macOS host filesystem via bind mounts. Containers can be destroyed and recreated without data loss.

| Host path | Container mount | Contents | Used by |
|-----------|----------------|----------|---------|
| `~/.ollama` | `/root/.ollama` | Ollama model weights, manifests, blobs | ollama-sandbox |
| `~/.colibri` | `/root/.colibri` | colibri MoE model shards | ollama-sandbox |
| `~/.hermes` | `/root/.hermes` | Hermes agent config (`config.yaml`) | hermes-agent |
| `~/.qdrant/storage` | `/qdrant/storage` | Qdrant vector collections, WAL, indexes | qdrant |
| `~/.qdrant/snapshots` | `/qdrant/snapshots` | Qdrant snapshots | qdrant |
| `~/.open-webui` | `/app/backend/data` | Open WebUI user data, chat history | open-webui |
| `~/Documents/git_code` | `/root/git_code` | Shared code workspace | hermes-agent, open-webui |
| `~/.ssh` (read-only) | `/root/.ssh` | SSH keys for git operations | ollama-sandbox |

### Network

All containers join the `ollama-net` podman network, which provides container-name DNS resolution. Containers reach each other by name (e.g., `http://ollama-sandbox:11434`, `http://qdrant:6333`). Host access uses the mapped ports (e.g., `http://localhost:11435`).

### Inference engines

- **Ollama** — standard LLM serving via an OpenAI-compatible API. Model must fit in RAM + VRAM. Runs with Vulkan GPU acceleration via the Venus paravirtualization path.
- **colibri** — expert-offloading MoE inference. Runs 100B–700B+ parameter Mixture-of-Experts models (GLM-5.2, DeepSeek V4, Qwen3.6, etc.) on modest hardware by streaming only the active experts from disk. A 744B model runs with ~10 GB RAM. Also uses Vulkan GPU.

### Vector memory (Qdrant)

Qdrant provides persistent vector storage for hermes-agent. Embeddings and metadata survive across hermes sessions, container restarts, and podman machine reboots — all data is bind-mounted to `~/.qdrant/` on the host. The hermes-agent container receives the connection URL via `QDRANT_URL=http://qdrant:6333` and has `qdrant-client` (Python SDK) pre-installed.

## Quick start

```bash
# Minimal: just Ollama with GPU
./setup.sh

# Agent stack: Ollama + Hermes 3 model + hermes-agent TUI + Qdrant
./setup.sh --hermes-agent

# Large MoE models via colibri
./setup.sh --colibri

# Browser chat UI
./setup.sh --webui

# Everything
./setup.sh --all
```

### setup.sh flags

| Flag | What it does |
|------|-------------|
| *(none)* | Builds ollama-vulkan image, starts ollama-sandbox with GPU |
| `--webui` | Also starts Open WebUI (browser chat at :3000) |
| `--hermes` | Pulls the Hermes 3 model into Ollama |
| `--hermes-agent` | Builds hermes-agent image, implies `--hermes` and `--qdrant` |
| `--colibri` | Verifies colibri GPU detection, prints usage instructions |
| `--qdrant` | Starts Qdrant vector database container |
| `--all` | Enables all of the above |

### What setup.sh does (step by step)

1. **Host prerequisites** — installs `krunkit` via Homebrew if missing
2. **Podman machine** — creates/starts a podman machine with `--provider libkrun` (8 CPUs, 40 GB RAM, 100 GB disk), verifies GPU passthrough (`/dev/dri/renderD128`), fixes VM DNS resolution
3. **Image build** — builds `ollama-vulkan-krunkit:v0.40.3` from `Dockerfile` (multi-stage: AlmaLinux 9 + Go + CMake + shaderc from source + Ollama with Vulkan + colibri with Vulkan). First build takes ~15–20 min
4. **Network** — creates `ollama-net` podman network if it doesn't exist
5. **ollama-sandbox** — starts the container with `--device /dev/dri`, bind mounts, and environment config. Checks existing container config and only recreates if it differs
6. **Open WebUI** (`--webui`) — pulls and starts `open-webui` connected to ollama-sandbox
7. **Hermes 3 model** (`--hermes`) — runs `ollama pull hermes3` inside the container
8. **hermes-agent image** (`--hermes-agent`) — builds from `Dockerfile.hermes` (Python 3.11-slim + hermes-agent + qdrant-client + ddgs)
9. **Qdrant** (`--qdrant`) — pulls and starts `qdrant/qdrant:latest` with persistent storage
10. **colibri** (`--colibri`) — verifies Vulkan GPU detection, prints model download/usage instructions

## Endpoints

| Service | Host URL | Container URL (on ollama-net) |
|---------|----------|-------------------------------|
| Ollama API | http://localhost:11435 | http://ollama-sandbox:11434 |
| Qdrant REST API | http://localhost:6333 | http://qdrant:6333 |
| Qdrant gRPC | localhost:6334 | qdrant:6334 |
| Qdrant Dashboard | http://localhost:6333/dashboard | — |
| Open WebUI | http://localhost:3000 | — |
| colibri API | http://localhost:8080 | http://ollama-sandbox:8080 |

## Using hermes-agent

```bash
./hermes.sh            # interactive TUI
./hermes.sh --help     # hermes help
```

`hermes.sh` does the following:
1. Checks that `ollama-sandbox` is running (required)
2. Warns if `qdrant` is not running (vector memory unavailable)
3. Generates `~/.hermes/config.yaml` on first run (points at `http://ollama-sandbox:11434/v1`, model `hermes3`)
4. Launches the hermes-agent container on `ollama-net` with bind mounts for git_code and hermes config
5. Passes `QDRANT_URL=http://qdrant:6333` as an environment variable

The hermes-agent container is ephemeral (`--rm`) — it is destroyed when you exit. Config persists in `~/.hermes/`, vector memory persists in `~/.qdrant/`.

### Web search

The hermes-agent image includes `ddgs` (DuckDuckGo search), which provides the `web_search` built-in tool. No API keys needed — DuckDuckGo has server-side rate limits but no auth. The container has full internet access through the podman VM's NAT.

## Using colibri (large MoE models)

colibri is always compiled into the ollama-sandbox image with Vulkan GPU support. Use `./colibri.sh` (a wrapper around `podman exec -it ollama-sandbox coli`):

```bash
./colibri.sh setup                                                       # download a model interactively
./colibri.sh chat --model /root/.colibri/<model>                         # interactive chat
./colibri.sh run "Hello" --model /root/.colibri/<model>                  # one-shot generation
./colibri.sh serve --model /root/.colibri/<model> --host 0.0.0.0 --port 8080  # OpenAI-compatible API
./colibri.sh import /root/.ollama/models/blobs/<blob>                    # import an Ollama GGUF
```

Models are stored in `~/.colibri` on the host (mounted at `/root/.colibri` in the container).

## Using Claude Code with Ollama models

`claude_qwen.sh` launches Claude Code pointed at the local Ollama API with the Qwen 3.6 model:

```bash
./claude_qwen.sh
```

This sets `ANTHROPIC_BASE_URL=http://localhost:11435` so Claude Code uses the local Ollama instance instead of the Anthropic API.

## Custom model configuration

`Modelfile_simple` contains a custom Ollama Modelfile for Qwen 3.6 with a tuned system prompt (direct, no-fluff, sequential decomposition). To create it:

```bash
podman exec -it ollama-sandbox ollama create qwen-custom -f /root/git_code/podman_vulkan/Modelfile_simple
```

## GPU verification

```bash
podman logs ollama-sandbox 2>&1 | grep 'inference compute'
# Expected: description="Virtio-GPU Venus (Apple M<N> ...)" total="<X> GiB"
```

To verify Vulkan inside the VM:

```bash
podman machine ssh podman-machine-default ls /dev/dri/renderD128
```

To verify colibri GPU detection:

```bash
podman exec ollama-sandbox coli plan --model /root/.colibri
```

## Performance

Paravirtualized GPU (Venus → Metal) is ~40× faster than CPU-only containers but slower than native Metal due to Vulkan translation overhead. Expect roughly ~50% of native Metal throughput — the tradeoff for full Linux sandbox isolation.

colibri's expert offloading adds disk I/O latency per token but enables models that would never fit in memory. Fast NVMe storage helps significantly.

## Key configuration

### Ollama environment variables (set in ollama-sandbox)

| Env var | Value | Purpose |
|---------|-------|---------|
| `OLLAMA_HOST` | `0.0.0.0:11434` | Listen on all interfaces inside container |
| `OLLAMA_VULKAN` | `1` | Enable Vulkan backend (required for Venus GPU path) |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Limit concurrent models to conserve VRAM |
| `OLLAMA_KEEP_ALIVE` | `5m` | Unload idle models after 5 minutes |
| `OLLAMA_CONTEXT_LENGTH` | `8192` (or `65536` with `--hermes-agent`) | Cap context window to prevent OOM on virtio-gpu buffer allocation |
| `OLLAMA_FLASH_ATTENTION` | `1` | Flash attention to reduce VRAM for KV cache |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Quantized KV cache for further VRAM savings |

### colibri environment variables (set in ollama-sandbox)

| Env var | Value | Purpose |
|---------|-------|---------|
| `COLI_VULKAN` | `1` | Enable colibri Vulkan GPU backend |
| `COLI_VK_DENSE` | `1` | Run dense layers on GPU |
| `COLI_VK_ATTN` | `1` | Run attention on GPU |
| `COLI_NO_OMP_TUNE` | `1` | Disable OpenMP auto-tuning |
| `COLI_VK_SHADERS` | `/usr/local/libexec/colibri/shaders` | Path to pre-compiled Vulkan shaders |

### Podman machine configuration

| Setting | Value | Notes |
|---------|-------|-------|
| Provider | `libkrun` | Required for GPU passthrough (not `applehv`) |
| CPUs | 8 | Shared with all containers |
| Memory | 40960 MB (~40 GB) | Needed for large models |
| Disk | 100 GB | Model storage + container images |
| GPU device | `--device /dev/dri` | **Critical** — without this, inference is CPU-only |

## File reference

| File | Purpose |
|------|---------|
| `setup.sh` | Main orchestrator — builds images, creates/manages all containers |
| `Dockerfile` | Multi-stage build for ollama-vulkan-krunkit image (Ollama + colibri + Vulkan) |
| `Dockerfile.hermes` | Lightweight image for hermes-agent (Python + hermes-agent + qdrant-client + ddgs) |
| `hermes.sh` | Convenience wrapper to launch hermes-agent container |
| `colibri.sh` | Convenience wrapper to run colibri commands in ollama-sandbox |
| `claude_qwen.sh` | Launches Claude Code using local Ollama API with Qwen model |
| `Modelfile_simple` | Custom Ollama Modelfile for Qwen 3.6 with tuned system prompt |

## Slimming down the Hermes system prompt

Hermes ships with 53 builtin skills enabled by default. Each injects tool schemas into the system prompt, totalling ~56 KB (~15K tokens). On local models (especially MoE models via colibri), this massive prompt causes multi-minute cold starts because every token must be prefilled through the expert routing layers.

Check current prompt size:

```bash
podman exec hermes-agent hermes prompt-size
```

### Nuclear option: remove all bundled skills

```bash
podman exec hermes-agent hermes skills opt-out --remove --yes
```

Then restart hermes (`Ctrl+C` your `./hermes.sh` and rerun it). This drops the prompt from ~15K to ~4–5K tokens, cutting cold-start prefill time by roughly 2/3.

### Reinstall only what you need

```bash
# Re-enable bundled skill seeding (if you want to cherry-pick)
podman exec hermes-agent hermes skills opt-in

# Install specific skills
podman exec hermes-agent hermes skills install github
podman exec hermes-agent hermes skills install codebase-inspection
```

### List / verify

```bash
podman exec hermes-agent hermes skills list       # see what's installed
podman exec hermes-agent hermes prompt-size        # confirm token savings
```

## Troubleshooting

**GPU not detected:**
```bash
# Check VM has GPU device
podman machine ssh podman-machine-default ls /dev/dri/renderD128

# If missing, the machine is likely using applehv instead of libkrun
podman machine stop podman-machine-default
podman machine rm -f podman-machine-default
./setup.sh  # will recreate with --provider libkrun
```

**DNS issues in VM:**
```bash
# setup.sh patches this automatically, but if pulls fail:
podman machine ssh podman-machine-default "echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf"
```

**Container config drift:**
`setup.sh` detects when a running container's configuration (image version, ports, env vars, mounts) differs from the desired config and automatically recreates it.

**Qdrant data location:**
All vector data is at `~/.qdrant/storage/` on the host. Deleting this directory destroys all collections. The container itself is stateless.

## Requirements

- macOS on Apple Silicon (M1+)
- Podman with libkrun provider (not applehv)
- Homebrew (for krunkit installation)
- ~20 min for first image build (compiles Ollama + colibri + shaderc from source)
- ~40 GB RAM recommended (configurable in setup.sh)
- ~100 GB disk for container images + models
