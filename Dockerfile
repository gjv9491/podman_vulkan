# ──────────────────────────────────────────────────────────────────────────────
# Multi-stage build: Ollama + Vulkan backend for M-series Mac GPU via krunkit
#
# WHY:
#   The official ollama/ollama arm64 image ships CPU-only — the Vulkan backend
#   is compiled for amd64 only. On Apple Silicon, podman uses krunkit (libkrun)
#   to virtualise Linux; GPU remoting works via Vulkan, but requires the
#   patched slp/mesa-krunkit mesa drivers to expose the host GPU inside the VM.
#   Those drivers are only available for EPEL 9 (AlmaLinux 9 / Rocky 9), so
#   we use AlmaLinux 9 as the base instead of Fedora 40.
#
# STAGE 1 — builder:  AlmaLinux 9 + build deps + compile Ollama with Vulkan
# STAGE 2 — runtime:  AlmaLinux 9 + patched mesa runtime only + ollama binary
# ──────────────────────────────────────────────────────────────────────────────

ARG OLLAMA_VERSION=v0.40.3
ARG GO_VERSION=1.23.4
ARG CMAKE_VERSION=3.31.2

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM almalinux:9 AS builder
ARG OLLAMA_VERSION
ARG GO_VERSION
ARG CMAKE_VERSION
USER 0

# 1a. Enable EPEL + CRB (CodeReady Builder) + install plugin prereqs
#     CRB is required for mesa-vulkan-drivers on AlmaLinux 9
RUN dnf -y install epel-release \
    && dnf -y install dnf-plugins-core dnf-plugin-versionlock \
    && dnf config-manager --enable crb \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 1c. Patched mesa-krunkit drivers (enables M-series GPU remoting via Vulkan)
#     Enable COPR first, then install without --repo so dnf can resolve all deps
#     (mesa 24.x needs LLVM 19, libdrm, libX11-xcb, libxshmfence from EPEL/CRB)
RUN dnf -y copr enable slp/mesa-krunkit epel-9-aarch64 \
    && dnf -y install \
        mesa-vulkan-drivers \
        vulkan-loader-devel \
        vulkan-headers \
        vulkan-tools \
    && dnf versionlock mesa-vulkan-drivers mesa-filesystem \
    && dnf update -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 1d. Build toolchain
#     - cmake and Go downloaded from upstream for version control
#     - glslang provides glslangValidator (needed by cmake to detect Vulkan)
#     - python3 needed by shaderc's git-sync-deps
#       (shaderc/glslc not available for aarch64 on EPEL 9 — built from source below)
RUN dnf -y install \
        gcc gcc-c++ make ninja-build git \
        glslang \
        python3 \
        vulkan-loader-devel libstdc++-devel \
        spirv-headers-devel spirv-tools-devel \
        unzip \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Go (system go in AlmaLinux 9 may be too old for Ollama — download upstream)
RUN curl -fsSL \
    "https://golang.org/dl/go${GO_VERSION}.linux-arm64.tar.gz" \
    | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH

# cmake
RUN curl -fsSL \
    "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-aarch64.tar.gz" \
    | tar xz -C /usr/local --strip-components=1

# 1d-extra. Build glslc from shaderc source (must come after cmake download)
#           LunarG does not ship an aarch64 SDK, so we compile from source.
#           git-sync-deps fetches the pinned glslang + spirv-tools versions.
RUN git clone --depth 1 https://github.com/google/shaderc /tmp/shaderc \
    && python3 /tmp/shaderc/utils/git-sync-deps \
    && cmake -S /tmp/shaderc -B /tmp/shaderc-build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSHADERC_SKIP_TESTS=ON \
        -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_ENABLE_TESTS=OFF \
    && cmake --build /tmp/shaderc-build --target glslc_exe -j$(nproc) \
    && cp /tmp/shaderc-build/glslc/glslc /usr/local/bin/ \
    && rm -rf /tmp/shaderc /tmp/shaderc-build

# 1e. Clone Ollama at the pinned version and fetch Go deps
WORKDIR /build
RUN git clone --depth 1 --branch ${OLLAMA_VERSION} \
        --recurse-submodules --shallow-submodules \
        https://github.com/ollama/ollama . \
    && go mod download

# 1f. Build the Vulkan-enabled llama-server backend
#     v0.40.x uses llama/server as the cmake source (confirmed from Ollama's Dockerfile)
#     glslangValidator from glslang is used for GLSL->SPIR-V shader compilation
ENV CMAKE_GENERATOR=Ninja
RUN cmake -S llama/server \
        -B build/llama-server-vulkan \
        -DGGML_VULKAN=1 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/build/dist \
    && cmake --build build/llama-server-vulkan -- -l$(nproc) \
    && cmake --install build/llama-server-vulkan --strip \
    && cp /build/dist/lib64/libggml-vulkan.so* /build/dist/lib/ollama/

# 1g. Build the Ollama Go binary
#     Note: -ldflags must be passed directly, not via GOFLAGS
RUN CGO_ENABLED=1 go build -trimpath -ldflags="-w -s" -o /usr/local/bin/ollama .

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM almalinux:9 AS runtime
ARG OLLAMA_VERSION
USER 0

# 2a. Enable EPEL + CRB + versionlock plugin
RUN dnf -y install epel-release \
    && dnf -y install dnf-plugins-core dnf-plugin-versionlock \
    && dnf config-manager --enable crb \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 2c. Patched mesa runtime — enable COPR then install with full dep resolution
RUN dnf -y copr enable slp/mesa-krunkit epel-9-aarch64 \
    && dnf -y install \
        mesa-vulkan-drivers \
        vulkan-loader \
        libstdc++ \
        ca-certificates \
    && dnf versionlock mesa-vulkan-drivers mesa-filesystem \
    && dnf update -y \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# 2d. Copy ollama binary and Vulkan backend libs from builder
#     Ollama v0.40.x searches /usr/local/lib/ollama/ by default
COPY --from=builder /usr/local/bin/ollama     /usr/local/bin/ollama
COPY --from=builder /build/dist/lib/ollama    /usr/local/lib/ollama/

# Label used by setup.sh to detect version drift
LABEL ollama.version="${OLLAMA_VERSION}"

ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_VULKAN=1
ENV OLLAMA_RUNNERS_DIR=/usr/local/lib/ollama
ENV LD_LIBRARY_PATH=/usr/local/lib/ollama

EXPOSE 11434

ENTRYPOINT ["/usr/local/bin/ollama"]
CMD ["serve"]
