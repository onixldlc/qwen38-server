# Qwen3.8 27B server — stock upstream llama.cpp.
# The GGUFs are ordinary K-quants (Unsloth Dynamic UD-*), so no fork is needed:
# the official release tarball already carries llama-server and its shared objects.
# Base and release asset switch together: CUDA for the GPU build, plain ubuntu for the
# CPU-only build (see cpu/compose-dev.yaml). Defaults are the GPU build.
ARG BASE_IMAGE=docker.io/nvidia/cuda:12.8.1-runtime-ubuntu24.04
FROM ${BASE_IMAGE}

# Release of https://github.com/ggml-org/llama.cpp and which asset of it to install.
# b11461 is new enough for the qwen35 architecture Qwen3.8 ships as, and for --tools.
ARG LLAMA_TAG=b11461
ARG LLAMA_FLAVOR=ubuntu-cuda-12.8-x64

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update

RUN apt-get install -y --no-install-recommends ca-certificates curl tar libgomp1 libcurl4 jq

RUN rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN curl -fsSL -o /tmp/llama.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-${LLAMA_FLAVOR}.tar.gz"

RUN mkdir -p /app/bin

RUN tar -xzf /tmp/llama.tar.gz -C /app/bin --strip-components=1

RUN rm -f /tmp/llama.tar.gz

RUN /app/bin/llama-server --version || true

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/verify.sh /usr/local/bin/verify.sh
COPY docker/autoscale.sh /usr/local/bin/autoscale.sh

# MCP stdio server for web_search / web_fetch. llama-server spawns it as a
# child process, so it ships in the image rather than as a separate service.
COPY docker/mcp-web.sh /usr/local/bin/mcp-web
COPY docker/mcp.json.template /etc/qwen38/mcp.json.template

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/verify.sh /usr/local/bin/autoscale.sh /usr/local/bin/mcp-web

# The release tarball carries its own shared objects next to the binaries.
ENV LD_LIBRARY_PATH=/app/bin:/usr/local/cuda/lib64
ENV PATH=/app/bin:$PATH
# Runtime knobs, all overridable from compose / --env.
# Weights are pulled with plain resumable curl from the HF CDN.
ENV MODEL_BASE_URL=https://huggingface.co
ENV MODEL_REPO=unsloth/Qwen3.8-27B-GGUF
ENV MODEL_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf
ENV MMPROJ_FILE=mmproj-BF16.gguf
ENV ENABLE_VISION=1
ENV MODEL_DIR=/models
# 1 = read the card's VRAM at start and pick MODEL_FILE / CTX_SIZE / KV type to
# match (see entrypoint.sh). 0 = use MODEL_FILE and CTX_SIZE as given.
ENV AUTO_SCALE=1
# VRAM to assume instead of asking nvidia-smi, in MiB. Empty = detect.
ENV VRAM_MIB=
# Headroom left free on each device, in MiB. Matches llama.cpp's --fit-target.
ENV FIT_MARGIN_MIB=1024
# A number, or 'auto' to drop --ctx-size and let llama.cpp's own fitter size the
# KV pool against free VRAM. Ignored when AUTO_SCALE=1 picks a value.
ENV CTX_SIZE=32768
ENV N_GPU_LAYERS=99
# 0 on the CPU build; empty means "let llama.cpp pick" (cores - 1 is usually right).
ENV THREADS=
ENV THREADS_BATCH=
ENV FLASH_ATTN=on
ENV HOST=0.0.0.0
ENV PORT=8080
ENV DOWNLOAD_ATTEMPTS=20
ENV EXTRA_ARGS=
# Web tools, off by default. 1 renders the MCP config and hands llama-server
# --mcp-servers-config, exposing web_search / web_fetch to the model.
ENV MCP_ENABLE=0
# Empty = DuckDuckGo's lite endpoint, no key. Point at your own SearXNG to
# keep queries on your network (its settings.yml needs `json` in search.formats).
ENV SEARXNG_URL=
ENV SEARCH_RESULTS=8
ENV FETCH_MAX_CHARS=20000
ENV HTTP_TIMEOUT=20

EXPOSE 8080

VOLUME ["/models"]

# The built-in file tools (--tools) resolve a relative path against the server's
# working directory, so the server runs from a directory meant to be mounted over
# rather than from /app next to the binaries.
RUN mkdir -p /workspace
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
