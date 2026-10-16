# podman_vulkan

GPU-accelerated Ollama in a sandboxed Linux container on Apple Silicon (M1–M5).

## How it works

```
Ollama (container) → Vulkan API → Mesa Venus driver → virtio-gpu → MoltenVK → Apple Metal → M4 GPU
```

The container runs a Linux VM via `krunkit` (libkrun). The VM gets a virtual GPU
device (`/dev/dri/renderD128`) that forwards Vulkan calls to the host's Metal GPU
through the Venus protocol. This gives sandboxed GPU inference without native
Metal access.

## Quick start

```bash
./setup.sh        # builds image (~15 min first time), starts ollama + open-webui
```

## What setup.sh does

1. Installs `krunkit` (Homebrew) if missing
2. Creates/starts a podman machine with `--provider libkrun` (GPU-capable VM)
3. Builds an AlmaLinux 9 image with Ollama compiled against Vulkan + patched mesa-krunkit drivers
4. Starts the `ollama-sandbox` container with `--device /dev/dri` (GPU passthrough)
5. Starts Open WebUI connected to the Ollama container

## Endpoints

| Service | URL |
|---------|-----|
| Ollama API | http://localhost:11435 |
| Open WebUI | http://localhost:3000 |

## GPU verification

```bash
podman logs ollama-sandbox 2>&1 | grep 'inference compute'
# Expected: description="Virtio-GPU Venus (Apple M4 Max)" total="64.0 GiB"
```

## Performance

Paravirtualized GPU (Venus→Metal) is ~40× faster than CPU-only containers but
slower than native Metal due to Vulkan translation overhead. Measured on M4 Max
with qwen3.6 (22 GB):

| Metric | Container (Venus→Metal) | Native Metal |
|--------|------------------------|--------------|
| Generation | ~35 tok/s | ~60-80 tok/s |
| Prompt eval | ~15 tok/s | ~30-50 tok/s |

The tradeoff: ~50% speed for full Linux sandbox isolation.

## Key config

| Env var | Value | Why |
|---------|-------|-----|
| `OLLAMA_VULKAN=1` | Enable Vulkan backend | Required for Venus GPU path |
| `OLLAMA_CONTEXT_LENGTH=8192` | Cap context | Prevents OOM on virtio-gpu buffer allocation |
| `OLLAMA_FLASH_ATTENTION=1` | Flash attention | Reduces VRAM for KV cache |
| `OLLAMA_KV_CACHE_TYPE=q8_0` | Quantized KV | Further VRAM savings |
| `--device /dev/dri` | GPU device | **Critical** — without this, container is CPU-only |

## Requirements

- macOS on Apple Silicon (M1+)
- Podman with libkrun provider (not applehv)
- ~15 min for first image build (compiles Ollama + shaderc from source)
