# podman_vulkan

GPU-accelerated Ollama + colibri in a sandboxed Linux container on Apple Silicon (M1–M5).

## How it works

```
Ollama / colibri (container) → Vulkan API → Mesa Venus driver → virtio-gpu → MoltenVK → Apple Metal → GPU
```

The container runs a Linux VM via `krunkit` (libkrun). The VM gets a virtual GPU
device (`/dev/dri/renderD128`) that forwards Vulkan calls to the host's Metal GPU
through the Venus protocol. This gives sandboxed GPU inference without native
Metal access.

**Two inference engines, one sandbox:**

- **Ollama** — standard LLM serving. Model must fit in RAM+VRAM.
- **colibri** — expert-offloading MoE inference. Runs 100B–700B+ parameter MoE models (GLM-5.2, DeepSeek V4, Qwen3.6, etc.) on modest hardware by streaming only the active experts from disk. A 744B model runs with ~10 GB RAM.

## Quick start

```bash
./setup.sh                  # builds image, starts ollama
./setup.sh --colibri        # also sets up colibri
./colibri.sh setup          # download a colibri model interactively
./colibri.sh chat --model /root/.colibri/<model>
```

## What setup.sh does

1. Installs `krunkit` (Homebrew) if missing
2. Creates/starts a podman machine with `--provider libkrun` (GPU-capable VM)
3. Builds an AlmaLinux 9 image with Ollama + colibri compiled against Vulkan + patched mesa-krunkit drivers
4. Starts the `ollama-sandbox` container with `--device /dev/dri` (GPU passthrough)
5. Optionally starts Open WebUI connected to the Ollama container

## Endpoints

| Service | URL |
|---------|-----|
| Ollama API | http://localhost:11435 |
| Open WebUI | http://localhost:3000 |
| colibri API | http://localhost:8080 (start with `./colibri.sh serve --model <dir> --host 0.0.0.0 --port 8080`) |

## Using colibri (large MoE models)

colibri is always built into the container image. Use `./colibri.sh` or `podman exec`:

```bash
# Download a model (interactive — picks one that fits your machine)
./colibri.sh setup

# Chat with a model
./colibri.sh chat --model /root/.colibri/<model>

# One-shot generation
./colibri.sh run "Hello" --model /root/.colibri/<model>

# OpenAI-compatible API server
./colibri.sh serve --model /root/.colibri/<model> --host 0.0.0.0 --port 8080

# Import an existing Ollama GGUF for use with colibri
./colibri.sh import /root/.ollama/models/blobs/<blob>
```

Models are stored in `~/.colibri` on the host (mounted at `/root/.colibri` in the container).

## GPU verification

```bash
podman logs ollama-sandbox 2>&1 | grep 'inference compute'
# Expected: description="Virtio-GPU Venus (Apple M<N> ...)" total="<X> GiB"
```

## Performance

Paravirtualized GPU (Venus→Metal) is ~40× faster than CPU-only containers but
slower than native Metal due to Vulkan translation overhead. Expect roughly
~50% of native Metal throughput — the tradeoff for full Linux sandbox isolation.

colibri's expert offloading adds disk I/O latency per token but enables models
that would never fit in memory. Fast NVMe storage helps.

## Key config

| Env var | Value | Why |
|---------|-------|-----|
| `OLLAMA_VULKAN=1` | Enable Vulkan backend | Required for Venus GPU path |
| `OLLAMA_CONTEXT_LENGTH=8192` | Cap context | Prevents OOM on virtio-gpu buffer allocation |
| `OLLAMA_FLASH_ATTENTION=1` | Flash attention | Reduces VRAM for KV cache |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | Quantized KV | Further VRAM savings |
| `COLI_VULKAN=1` | Enable colibri Vulkan | Pre-set in the container |
| `COLI_VK_DENSE=1` | Dense layers on GPU | Pre-set in the container |
| `--device /dev/dri` | GPU device | **Critical** — without this, container is CPU-only |

## Requirements

- macOS on Apple Silicon (M1+)
- Podman with libkrun provider (not applehv)
- ~20 min for first image build (compiles Ollama + colibri + shaderc from source)
